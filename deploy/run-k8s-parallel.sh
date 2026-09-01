#!/usr/bin/env bash
# jjlab e2e — PARALLEL k8s orchestrator.
#
# Runs EVERY suite (registry protocols + auth + system + ci + ops) as its own
# k8s Job per-CLI runner container, all launched at once against the REAL
# deployed jjlab (jj-lab.temp). `net-preflight` (writes the shared upstream
# flags) runs first and alone; the rest are created in one shot and the whole
# set is waited on concurrently. Per-Job WORK dirs are isolated, so the suites
# do not collide.
#
# Unlike run-k8s.sh (serial, throwaway jjlab), this targets the migrated
# production jjlab and verifies the real migration end-to-end.
#
# Usage:  ./deploy/run-k8s-parallel.sh [suite ...]
# Env:    BASE/target jjlab  (default http://jj-lab.temp.svc.cluster.local)
#         RUN_TAG   runner image tag (default dev)
#         WRITE_TOKEN (default devtoken)
#         KUBE_CONTEXT (default temp)
set -uo pipefail

CS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$CS/.." && pwd)"
cd "$ROOT"

KUBECTL="kubectl --context ${KUBE_CONTEXT:-temp} --namespace temp"
BASE="${BASE:-http://jj-lab.temp.svc.cluster.local}"
REGISTRY="${REGISTRY:-artifact.temp.svc.cluster.local}"
RUN_TAG="${RUN_TAG:-dev}"
WRITE_TOKEN="${WRITE_TOKEN:-devtoken}"
NS="temp"
ART="$ROOT/artifacts/k8s-parallel"
RUN_ID="$(date +%Y%m%d%H%M%S)-$$"
OUT="$ART/$RUN_ID"
mkdir -p "$OUT"

# Suite -> runner image. ci/ops use the generic runner (curl+python3 only;
# no kubectl needed since they drive jjlab's own /ops + API).
declare -A IMG=(
  [npm]=npm [pypi]=pypi [cargo]=cargo [go]=go [maven]=maven
  [composer]=composer [nuget]=nuget [rubygems]=rubygems [hex]=hex
  [pub]=pub [swift]=swift [conan]=conan [helm]=helm [generic]=generic
  [oci]=oci [auth]=auth [system]=system [net-preflight]=net-preflight
  [ci]=generic [ops]=generic
)

SUITES=("$@")
[ ${#SUITES[@]} -gt 0 ] || SUITES=(net-preflight npm pypi cargo go maven composer nuget rubygems hex pub swift conan helm generic oci auth system ci ops)

echo "run-id:  $RUN_ID"
echo "out-dir: $OUT"
echo "target:  $BASE"
echo "suites:  ${SUITES[*]}"
echo ""

# sanity: target reachable
curl -s --noproxy '*' --max-time 10 "$BASE/api/v1/health" -o /dev/null \
  || { echo "TARGET UNREACHABLE: $BASE"; exit 1; }

# net-preflight first (writes upstream.flags used by others)
echo "═══ net-preflight (first) ═══"
NP="e2e-net-preflight-$RUN_ID"
cat <<EOF | $KUBECTL apply -f - >/dev/null
apiVersion: batch/v1
kind: Job
metadata: { name: $NP, namespace: $NS }
spec:
  backoffLimit: 0
  ttlSecondsAfterFinished: 1800
  template:
    spec:
      restartPolicy: Never
      containers:
        - name: runner
          image: ${REGISTRY}/jjlab-e2e/runner-net-preflight:${RUN_TAG}
          imagePullPolicy: Always
          env:
            - { name: SUITE, value: "net-preflight" }
            - { name: BASE, value: "$BASE" }
            - { name: WRITE_TOKEN, value: "$WRITE_TOKEN" }
            - { name: WORK, value: "/work" }
            - { name: NO_PROXY, value: "*" }
            - { name: no_proxy, value: "*" }
          resources:
            requests: { cpu: 100m, memory: 256Mi }
            limits: { cpu: "1", memory: 1Gi }
EOF
$KUBECTL wait --for=condition=complete job/"$NP" --timeout=300s >/dev/null 2>&1 || echo "net-preflight did not complete"
$KUBECTL logs "job/$NP" > "$OUT/net-preflight.log" 2>&1 || true
$KUBECTL delete job/"$NP" --ignore-not-found >/dev/null 2>&1 || true
echo "  net-preflight done"

# launch ALL remaining suites in one shot (parallel).
echo "═══ launching ${#SUITES[@]} suites in parallel ═══"
for s in "${SUITES[@]}"; do
  [ "$s" = "net-preflight" ] && continue
  local_img="${IMG[$s]:?unknown suite $s}"
  local_job="e2e-${s}-${RUN_ID}"
  cat <<EOF | $KUBECTL apply -f - >/dev/null 2>&1
apiVersion: batch/v1
kind: Job
metadata: { name: $local_job, namespace: $NS }
spec:
  backoffLimit: 0
  ttlSecondsAfterFinished: 1800
  template:
    spec:
      restartPolicy: Never
      containers:
        - name: runner
          image: ${REGISTRY}/jjlab-e2e/runner-${local_img}:${RUN_TAG}
          imagePullPolicy: Always
          env:
            - { name: SUITE, value: "$s" }
            - { name: BASE, value: "$BASE" }
            - { name: WRITE_TOKEN, value: "$WRITE_TOKEN" }
            - { name: WORK, value: "/work/$s" }
            - { name: NO_PROXY, value: "*" }
            - { name: no_proxy, value: "*" }
          resources:
            requests: { cpu: 100m, memory: 256Mi }
            limits: { cpu: "1", memory: 1Gi }
EOF
done

# Wait for ALL jobs to reach a terminal state, polling concurrently, then collect.
RUN_JOBS=()
for s in "${SUITES[@]}"; do
  [ "$s" = "net-preflight" ] && continue
  RUN_JOBS+=("e2e-${s}-${RUN_ID}")
done

# Poll until every job is Complete or Failed (or timeout).
echo "═══ waiting for ${#RUN_JOBS[@]} jobs ═══"
WAIT_DEADLINE=$(( SECONDS + 1500 ))
while [ $SECONDS -lt $WAIT_DEADLINE ]; do
  all_done=1
  remaining=()
  for j in "${RUN_JOBS[@]}"; do
    cond=$($KUBECTL get job "$j" -n "$NS" -o jsonpath='{.status.conditions[?(@.type=="Complete")].status}' 2>/dev/null)
    failed=$($KUBECTL get job "$j" -n "$NS" -o jsonpath='{.status.conditions[?(@.type=="Failed")].status}' 2>/dev/null)
    if [ "$cond" != "True" ] && [ "$failed" != "True" ]; then
      all_done=0; remaining+=("$j")
    fi
  done
  [ "$all_done" = "1" ] && break
  sleep 5
done

# Collect logs for each (jobs complete; ttl is 1800 so they persist for collection).
overall=0
for s in "${SUITES[@]}"; do
  [ "$s" = "net-preflight" ] && continue
  local_job="e2e-${s}-${RUN_ID}"
  echo "════ $s ════  (job $local_job)"
  $KUBECTL logs "job/$local_job" > "$OUT/$s.log" 2>&1 || true
  p=$(grep -oE 'PASS:' "$OUT/$s.log" | wc -l | tr -d ' ')
  f=$(grep -oE 'FAIL:' "$OUT/$s.log" | wc -l | tr -d ' ')
  sk=$(grep -oE 'SKIP:' "$OUT/$s.log" | wc -l | tr -d ' ')
  line=$(grep -E "── $s:" "$OUT/$s.log" | tail -1 || true)
  printf '  %-14s %s\n' "$s" "${line:-"(no summary)"}"
  echo "$p $f $sk" > "$OUT/$s.result"
  [ "$f" = "0" ] || overall=1
  $KUBECTL delete job/"$local_job" --ignore-not-found >/dev/null 2>&1 || true
done

echo "──────────────────────────────────────────"
echo "k8s-parallel run $RUN_ID  ->  $OUT"
TOT_P=0; TOT_F=0; TOT_S=0
for s in "${SUITES[@]}"; do
  [ "$s" = "net-preflight" ] && continue
  read -r p f sk < "$OUT/$s.result" 2>/dev/null || continue
  printf '  %-14s %-3s passed  %-3s failed  %-3s skipped\n' "$s" "$p" "$f" "$sk"
  TOT_P=$((TOT_P+p)); TOT_F=$((TOT_F+f)); TOT_S=$((TOT_S+sk))
done
echo "TOTAL: $TOT_P passed, $TOT_F failed, $TOT_S skipped"
echo "artifacts: $OUT"
exit "$overall"

# ── finalize: if `system` ran it resets global upstreams/proxy. Restore the
#    migration upstreams (npm/cargo/go -> old artifact.zergx pull-through) so
#    sandbox/CI pull-through keeps working after the e2e run.
finalize_upstreams() {
  echo "═══ finalize: restore migration upstreams ═══"
  local H="Authorization: token $WRITE_TOKEN"
  local CT="Content-Type: application/json"
  for spec in \
    "npm|http://artifact.zergx.svc.cluster.local/pkgs/npm/" \
    "cargo|http://artifact.zergx.svc.cluster.local/pkgs/cargo/index/" \
    "cargo.index|http://artifact.zergx.svc.cluster.local/pkgs/cargo/index/" \
    "cargo.static|http://artifact.zergx.svc.cluster.local/pkgs/cargo/" \
    "go|http://artifact.zergx.svc.cluster.local/pkgs/go/"; do
    k="${spec%%|*}"; u="${spec##*|}"
    curl -s --noproxy '*' --max-time 15 -H "$H" -X PUT "$BASE/pkgs/system/upstreams/$k" -H "$CT" -d "{\"url\":\"$u\"}" >/dev/null 2>&1 || true
  done
  echo "  done"
}
finalize_upstreams
