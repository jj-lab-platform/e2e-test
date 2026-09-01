#!/usr/bin/env bash
# ops: the sandbox plane — /ops/services lifecycle (get-or-create + readiness),
# repo sync (rev-skip + force overlay), worker exec through the synced tree,
# and teardown.
#
# Uses the zergx-worker image (present in the cluster registry; the real
# ops-extension sandbox). Worker protocol: /api/v1/health, /api/v1/file
# (tar stream), /api/v1/jobs (execute RPC goes over ws — here we assert on
# the synced FILE content instead, which exercises the sync path fully).
set -uo pipefail
cd "$(dirname "$0")"
source ../lib.sh

section "ops"

NAME="ops-e2e-$RUN_ID"
SVC="$API/api/v1/ops/services/$NAME"
H="Authorization: token $TOKEN"
WORKER_PORT=48080
REPO="ops-e2e-$RUN_ID"
RR="$API/api/v1/repos/verify/$REPO"

# The pod must resolve by its pod IP (ops-extension addresses workers
# pod-directly); namespace of the deployment is fixed by the chart.
# The runtime namespace for sandboxes: OPS_NS override, else the temp ns
# (where the chart deploys jjlab and its RBAC/quota rules live).
NS="${OPS_NS:-temp}"
# Sandbox worker image: the same one ops-extension uses (zergx-worker in the
# zergx registry). Overridable via OPS_WORKER_IMAGE.
OPS_WORKER_IMAGE="${OPS_WORKER_IMAGE:-forgejo.develop.10.199.64.20.nip.io/root/zergx-worker:v0.0.4}"

WAIT_TIMEOUT=${OPS_WAIT_TIMEOUT:-180}
POLL=3

await_service_ready() {
  local waited=0 st=""
  while [ "$waited" -lt "$WAIT_TIMEOUT" ]; do
    st=$(curl_api "$SVC?namespace=$NS" 2>/dev/null | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    print('ready' if d.get('ready') else 'pending')
except Exception:
    print('missing')" 2>/dev/null || echo missing)
    [ "$st" = "ready" ] && { echo ready; return 0; }
    sleep "$POLL"; waited=$((waited + POLL))
  done
  echo timeout
}

# ── setup: a repo to sync
code=$(curl_api -o /dev/null -w '%{http_code}' -X POST "$RR" -H 'Content-Type: application/json' -d '{"default_branch":"main"}')
assert_status_in "create repo" "$code" "200 201"
code=$(curl_api -o /dev/null -w '%{http_code}' -X PUT "$RR/contents/opsfile.txt?ref=main" \
  -H 'Content-Type: application/json' -d '{"content":"ops-sync-v1"}')
assert_code "write opsfile.txt (rev1)" 200 "$code"

# ── A: ensure creates a ready worker (get-or-create + wait Ready)
code=$(curl_api -o /dev/null -w '%{http_code}' -X POST "$API/api/v1/ops/services" \
  -H 'Content-Type: application/json' \
  -d "{\"name\":\"$NAME\",\"image\":\"$OPS_WORKER_IMAGE\",\"kind\":\"bare\",\"ports\":[{\"container\":$WORKER_PORT,\"service\":80}],\"env\":{\"WORKER_PORT\":\"$WORKER_PORT\"},\"annotations\":{\"zergx/session\":\"verify:$REPO:main\"},\"namespace\":\"$NS\"}")
assert_code "A: ensure service" 200 "$code"

st=$(await_service_ready)
assert_eq "A: service becomes ready" "ready" "$st"

# ── B: ensure is IDEMPOTENT (second call reuses the pod, no recreate)
pod_ip=$(curl_api "$SVC?namespace=$NS" | python3 -c "import sys,json; print(json.load(sys.stdin).get('pod_ip',''))")
code=$(curl_api -o /dev/null -w '%{http_code}' -X POST "$API/api/v1/ops/services" \
  -H 'Content-Type: application/json' \
  -d "{\"name\":\"$NAME\",\"image\":\"$OPS_WORKER_IMAGE\",\"kind\":\"bare\",\"ports\":[{\"container\":$WORKER_PORT,\"service\":80}],\"env\":{\"WORKER_PORT\":\"$WORKER_PORT\"},\"namespace\":\"$NS\"}")
assert_code "B: re-ensure accepted" 200 "$code"
pod_ip2=$(curl_api "$SVC?namespace=$NS" | python3 -c "import sys,json; print(json.load(sys.stdin).get('pod_ip',''))")
assert_eq "B: pod reused (same IP)" "$pod_ip" "$pod_ip2"

# ── C: sync pushes the repo tree into the worker (overlay extract)
code=$(curl_api -o /dev/null -w '%{http_code}' -X POST "$SVC/sync?namespace=$NS" \
  -H 'Content-Type: application/json' \
  -d "{\"org\":\"verify\",\"repo\":\"$REPO\",\"rev\":\"main\",\"namespace\":\"$NS\"}")
assert_code "C: sync rev=main" 200 "$code"

# Worker /api/v1/file returns a tar of the path — extract and compare.
if [ -n "$pod_ip" ]; then
  out=$(curl --noproxy '*' -s --max-time 15 "http://$pod_ip:$WORKER_PORT/api/v1/file?path=opsfile.txt" | tar -xzOf - 2>/dev/null)
  assert_eq "C: worker holds synced file" "ops-sync-v1" "$out"
else
  fail "C: worker holds synced file (no pod ip)"
fi

# ── D: same-rev sync is SKIPPED (jjlab cached), then force re-pushes
r1=$(curl_api -X POST "$SVC/sync?namespace=$NS" -H 'Content-Type: application/json' \
  -d "{\"org\":\"verify\",\"repo\":\"$REPO\",\"rev\":\"main\",\"namespace\":\"$NS\"}")
assert_json_ok "D: same-rev sync skipped" "$r1" "d.get('skipped') is True"
r2=$(curl_api -X POST "$SVC/sync?force=1&namespace=$NS" -H 'Content-Type: application/json' \
  -d "{\"org\":\"verify\",\"repo\":\"$REPO\",\"rev\":\"main\",\"namespace\":\"$NS\"}")
assert_json_ok "D: force sync re-pushes" "$r2" "d.get('skipped') is False"

# ── E: new rev syncs again (overlay overwrite)
code=$(curl_api -o /dev/null -w '%{http_code}' -X PUT "$RR/contents/opsfile.txt?ref=main" \
  -H 'Content-Type: application/json' -d '{"content":"ops-sync-v2"}')
assert_code "E: write opsfile.txt (rev2)" 200 "$code"
r3=$(curl_api -X POST "$SVC/sync?namespace=$NS" -H 'Content-Type: application/json' \
  -d "{\"org\":\"verify\",\"repo\":\"$REPO\",\"rev\":\"main\",\"namespace\":\"$NS\"}")
assert_json_ok "E: new-rev sync re-pushes" "$r3" "d.get('skipped') is False"
if [ -n "$pod_ip" ]; then
  out=$(curl --noproxy '*' -s --max-time 15 "http://$pod_ip:$WORKER_PORT/api/v1/file?path=opsfile.txt" | tar -xzOf - 2>/dev/null)
  assert_eq "E: worker sees rev2 content" "ops-sync-v2" "$out"
else
  fail "E: worker sees rev2 content (no pod ip)"
fi

# ── F: worker health endpoint is reachable (the exec plane's transport)
if [ -n "$pod_ip" ]; then
  code=$(curl --noproxy '*' -s -o /dev/null -w '%{http_code}' --max-time 10 "http://$pod_ip:$WORKER_PORT/api/v1/health")
  assert_code "F: worker health 200" 200 "$code"
fi

# ── teardown
code=$(curl_api -o /dev/null -w '%{http_code}' -X DELETE "$SVC?namespace=$NS")
assert_status_in "teardown: delete service" "$code" "200 204"
curl_api -o /dev/null -X DELETE "$RR"

echo "$PASS $FAIL $SKIP" > "$WORK/ops.result"
summary "ops"
