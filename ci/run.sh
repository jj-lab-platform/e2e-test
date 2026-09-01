#!/usr/bin/env bash
# ci: the native CI runner plane — push/dispatch triggers, repo snapshot
# injection, secrets, parallel jobs, and live logs.
#
# Flow (all against the real deployed jjlab):
#   push a repo with .jjlab-ci.yml  -> run auto-enqueued (on: push)
#   wait for success                -> job log shows the repo SNAPSHOT was
#                                      fetched into /workspace by the
#                                      initContainer (file content asserted)
#   secrets (JJLAB_CI_SECRETS)      -> surfaced to the step env
#   workflow_dispatch               -> manual run enqueued
#   parallel jobs                   -> two jobs of one run both execute
#   pull_request (MR head update)   -> run enqueued at the MR head sha
#
# Requires the deployment to set:
#   JJLAB_CI_ENABLED=1, JJLAB_SELF_URL (in-cluster self address),
#   JJLAB_CI_SECRETS (contains CI_TEST_SECRET=...), JJLAB_CI_NAMESPACE,
#   and the jjlab-ci RBAC to cover pods in that namespace.
set -uo pipefail
cd "$(dirname "$0")"
source ../lib.sh

section "ci"

REPO="ci-e2e-$RUN_ID"
R="$API/api/v1/repos/verify/$REPO"
AW="$API/api/v1/repos/verify/$REPO/actions"
H="Authorization: token $TOKEN"

# generous ceiling: a CI run needs k8s scheduling + image pull + init fetch
WAIT_TIMEOUT=${CI_WAIT_TIMEOUT:-300}
POLL=${CI_POLL_INTERVAL:-3}

await_run_terminal() { # await_run_terminal <label> <run_id>
  local waited=0 runid="$2" st=""
  while [ "$waited" -lt "$WAIT_TIMEOUT" ]; do
    st=$(curl_api "$AW/runs" 2>/dev/null | python3 -c 'import sys,json; d=json.load(sys.stdin); print(next((r.get("status","") for r in d.get("runs",[]) if str(r.get("id"))=="'"$runid"'"),""))')
    case "$st" in success|failure|skipped) echo "$st"; return 0;; esac
    sleep "$POLL"; waited=$((waited + POLL))
  done
  echo "timeout"
}

first_job_id() { # first_job_id <run_id>
  curl_api "$AW/runs/$1/jobs" 2>/dev/null | python3 -c 'import sys,json; d=json.load(sys.stdin); js=d.get("jobs",[]); print(js[0]["id"] if js else "")' 2>/dev/null
}

job_log() { curl_api "$AW/jobs/$1/logs" 2>/dev/null; }

# ── setup: repo with two files + a two-job workflow (snapshot+secret+parallel)
code=$(curl_api -o /dev/null -w '%{http_code}' -X POST "$R" -H 'Content-Type: application/json' -d '{"default_branch":"main"}')
assert_status_in "create repo" "$code" "200 201"

code=$(curl_api -o /dev/null -w '%{http_code}' -X PUT "$R/contents/snapshot.txt?ref=main" \
  -H 'Content-Type: application/json' -d '{"content":"ci-snapshot-marker"}')
assert_code "write snapshot.txt" 200 "$code"

WF='name: CI
on: push
jobs:
  a:
    steps:
      - run: echo job-a && cat snapshot.txt && echo "secret=$CI_TEST_SECRET"
  b:
    steps:
      - run: echo job-b'
code=$(curl_api -o /dev/null -w '%{http_code}' -X PUT "$R/contents/.jjlab-ci.yml?ref=main" \
  -H 'Content-Type: application/json' \
  --data-binary "$(python3 -c "import json,sys; print(json.dumps({'content':sys.stdin.read()}))" <<< "$WF")")
assert_code "write .jjlab-ci.yml (push trigger)" 200 "$code"

# ── A: push auto-enqueues a run
sleep 5
run_a=$(curl_api "$AW/runs" | python3 -c 'import sys,json; rs=json.load(sys.stdin).get("runs",[]); print(rs[-1]["id"] if rs else "")')
[ -n "$run_a" ] && pass "A: push enqueued run $run_a" || fail "A: push enqueued run"
[ -z "$run_a" ] && { echo "$PASS $FAIL $SKIP" > "$WORK/ci.result"; summary "ci"; exit 0; }

# ── B: run succeeds and the step saw the repo SNAPSHOT + the injected secret
st=$(await_run_terminal "B: run $run_a terminal" "$run_a")
assert_eq "B: run status" "success" "$st"

jid=$(first_job_id "$run_a")
[ -n "$jid" ] && pass "B: job registered ($jid)" || fail "B: job registered"
if [ -n "$jid" ]; then
  log=$(job_log "$jid")
  assert_contains "B: job-a executed" "$log" "job-a"
  assert_contains "B: repo snapshot fetched into /workspace" "$log" "ci-snapshot-marker"
  assert_contains "B: CI_TEST_SECRET injected" "$log" "secret=ci-e2e-secret"
fi

# ── C: parallel jobs — job b also ran in the same run
njobs=$(curl_api "$AW/runs/$run_a/jobs" | python3 -c 'import sys,json; print(len(json.load(sys.stdin).get("jobs",[])))' 2>/dev/null || echo 0)
assert_eq "C: both parallel jobs present" 2 "$njobs"

# ── D: manual dispatch enqueues a new run
WID=$(curl_api "$AW/workflows" | python3 -c 'import sys,json
for w in json.load(sys.stdin).get("workflows",[]):
    if w.get("path")==".jjlab-ci.yml": print(w.get("id")); break')
[ -n "$WID" ] || WID=1
code=$(curl_api -o /dev/null -w '%{http_code}' -X POST "$AW/workflows/$WID/dispatch")
assert_code "D: workflow_dispatch accepted" 200 "$code"
run_d=$(curl_api "$AW/runs" | python3 -c 'import sys,json; rs=json.load(sys.stdin).get("runs",[]); print(rs[-1]["id"] if rs else "")')
st=$(await_run_terminal "D: dispatched run terminal" "$run_d")
assert_eq "D: dispatched run status" "success" "$st"

# ── E: pull_request — MR head update fires a run at the new head
HEAD_SHA=$(curl_api "$R/branches" | python3 -c "import sys,json; print(json.load(sys.stdin)['branches'][0]['sha'])")
code=$(curl_api -o /dev/null -w '%{http_code}' -X POST "$R/branches/feature" \
  -H 'Content-Type: application/json' -d "{\"target\":\"$HEAD_SHA\"}")
assert_code "E: create feature branch" 200 "$code"

WF_PR='name: CI
on:
  - push
  - pull_request
jobs:
  prcheck:
    steps:
      - run: echo pr-ci-ran'
code=$(curl_api -o /dev/null -w '%{http_code}' -X PUT "$R/contents/.jjlab-ci.yml?ref=feature" \
  -H 'Content-Type: application/json' \
  --data-binary "$(python3 -c "import json,sys; print(json.dumps({'content':sys.stdin.read()}))" <<< "$WF_PR")")
assert_code "E: branch CI declares pull_request" 200 "$code"

code=$(curl_api -o /dev/null -w '%{http_code}' -X POST "$R/pulls" \
  -H 'Content-Type: application/json' -d '{"title":"e2e pr","head":"feature","base":"main"}')
assert_code "E: create MR" 201 "$code"
sleep 5
before=$(curl_api "$AW/runs" | python3 -c "import sys,json; print(len(json.load(sys.stdin).get('runs', [])))")

code=$(curl_api -o /dev/null -w '%{http_code}' -X PUT "$R/pulls/1/head" \
  -H 'Content-Type: application/json' -d '{"head":"feature"}')
assert_code "E: MR head update" 200 "$code"
sleep 8
after_runs=$(curl_api "$AW/runs")
n_after=$(echo "$after_runs" | python3 -c "import sys,json; print(len(json.load(sys.stdin).get('runs', [])))")
if [ "$n_after" -gt "$before" ]; then pass "E: pull_request enqueued a run"; else fail "E: pull_request enqueued a run"; fi
pr_run=$(echo "$after_runs" | python3 -c "import sys,json; print(json.load(sys.stdin)['runs'][-1]['id'])")
st=$(await_run_terminal "E: pr run terminal" "$pr_run")
assert_eq "E: pr run status" "success" "$st"
pr_job=$(first_job_id "$pr_run")
pr_log=$(job_log "$pr_job")
assert_contains "E: pr run executed prcheck" "$pr_log" "pr-ci-ran"

# ── teardown (best-effort; run rows go with the repo)
curl_api -o /dev/null -X DELETE "$R"

echo "$PASS $FAIL $SKIP" > "$WORK/ci.result"
summary "ci"
