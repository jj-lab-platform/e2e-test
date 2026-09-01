#!/usr/bin/env bash
# jjlab registry e2e — k8s orchestrator.
#
# Deploys a THROWAWAY jjlab instance into `temp` (via jj-lab's chart, renamed
# to a unique release so it never collides with the real `jj-lab` deploy), then
# runs each requested protocol suite inside its own per-CLI runner container
# (k8s Job) against that instance, collects every pod's stdout as an artifact,
# and tears the instance down.
#
# This is the "a series of containers, each testing one CLI, rotating a temp
# deployment" model.
#
# Usage:
#   ./deploy/run-k8s.sh [suite ...]            # default: npm cargo go
#   ./deploy/run-k8s.sh --once ...             # one jjlab instance for all suites
#   JJLAB_TAG=v0.2.0 ./deploy/run-k8s.sh npm   # image tag of jjlab under test
#
# Env:
#   JJLAB_TAG      jjlab image tag        (default v0.2.0)
#   JJLAB_CHART    path to jj-lab chart   (default ~/jj-lab/deploy/chart)
#   KUBE_CONTEXT   k8s context            (default temp)
#   WRITE_TOKEN    write token            (default devtoken)
set -euo pipefail

CS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$CS/.." && pwd)"
cd "$ROOT"

KUBECTL="kubectl --context ${KUBE_CONTEXT:-temp} --namespace temp"
JJLAB_TAG="${JJLAB_TAG:-v0.3.0}"
JJLAB_CHART="${JJLAB_CHART:-$HOME/jj-lab/deploy/chart}"
WRITE_TOKEN="${WRITE_TOKEN:-devtoken}"
NS="temp"
RELEASE="jjlab-e2e"
SVC="$RELEASE.$NS.svc.cluster.local"
BASE="http://$SVC"
REGISTRY="${REGISTRY:-artifact.temp.svc.cluster.local}"
RUN_TAG="${RUN_TAG:-dev}"

MODE="each"
if [ "${1:-}" = "--once" ]; then MODE="once"; shift; fi
SUITES=("$@")
[ ${#SUITES[@]} -gt 0 ] || SUITES=(npm cargo go)

ART="$ROOT/artifacts/k8s"
RUN_ID="$(date +%Y%m%d%H%M%S)-$$"
OUT="$ART/$RUN_ID"
mkdir -p "$OUT"
echo "run-id:  $RUN_ID"
echo "out-dir: $OUT"
echo "suites:  ${SUITES[*]}"
echo "jjlab:   ${REGISTRY}/jj-lab:${JJLAB_TAG} @ $BASE"
echo ""

deploy_jjlab() {
  echo "═══ deploying jjlab ($RELEASE @ $JJLAB_TAG) ═══"
  helm --kube-context "${KUBE_CONTEXT:-temp}" upgrade --install "$RELEASE" "$JJLAB_CHART" \
    --namespace "$NS" \
    --set fullnameOverride="$RELEASE" \
    --set image.repository="${REGISTRY}/jj-lab" \
    --set image.tag="$JJLAB_TAG" \
    --set image.pullPolicy=Always \
    --set registry.selfBase="http://$SVC" \
    --set tokens="${WRITE_TOKEN}=write" \
    --wait --timeout 120s >/dev/null
  echo "═══ waiting for readiness ═══"
  $KUBECTL wait --for=condition=available deployment/"$RELEASE" --timeout=120s >/dev/null
  curl -s --noproxy '*' --max-time 10 "$BASE/api/v1/health" -o /dev/null \
    || curl -s --noproxy '*' --max-time 10 "$BASE/pkgs/npm/-/ping" -o /dev/null
  echo "═══ health OK at $BASE ═══"
  echo ""
}

teardown_jjlab() {
  echo "═══ uninstalling $RELEASE ═══"
  helm --kube-context "${KUBE_CONTEXT:-temp}" uninstall "$RELEASE" --namespace "$NS" --wait --timeout 120s >/dev/null 2>&1 \
    || $KUBECTL delete deployment/"$RELEASE" service/"$RELEASE" >/dev/null 2>&1 || true
  echo ""
}

run_suite() {
  local suite="$1"
  local job="e2e-${suite}-${RUN_ID}"
  echo "════ $suite ════  (job $job)"
  cat <<EOF | $KUBECTL apply -f - >/dev/null
apiVersion: batch/v1
kind: Job
metadata:
  name: $job
  namespace: $NS
spec:
  backoffLimit: 0
  ttlSecondsAfterFinished: 300
  template:
    spec:
      restartPolicy: Never
      containers:
        - name: runner
          image: ${REGISTRY}/jjlab-e2e/runner-${suite}:${RUN_TAG}
          imagePullPolicy: Always
          env:
            - name: SUITE
              value: "$suite"
            - name: BASE
              value: "$BASE"
            - name: WRITE_TOKEN
              value: "$WRITE_TOKEN"
            - name: WORK
              value: "/work"
            - name: NO_PROXY
              value: "*"
            - name: no_proxy
              value: "*"
          resources:
            requests:
              cpu: 100m
              memory: 256Mi
            limits:
              cpu: "1"
              memory: 1Gi
EOF
  # Wait for completion/failure, then capture stdout (the artifact).
  $KUBECTL wait --for=condition=complete job/"$job" --timeout=900s >/dev/null 2>&1 && rc=0 || rc=1
  if [ "$rc" -ne 0 ]; then
    $KUBECTL wait --for=condition=failed job/"$job" --timeout=20s >/dev/null 2>&1 || true
  fi
  $KUBECTL logs "job/$job" > "$OUT/$suite.log" 2>&1 || true
  local p=0 f=0 s=
  p=$(grep -oE 'PASS:' "$OUT/$suite.log" | wc -l | tr -d ' ')
  f=$(grep -oE 'FAIL:' "$OUT/$suite.log" | wc -l | tr -d ' ')
  s=$(grep -oE 'SKIP:' "$OUT/$suite.log" | wc -l | tr -d ' ')
  local line
  line=$(grep -E "── $suite:" "$OUT/$suite.log" | tail -1 || true)
  printf '  %-10s %s\n' "$suite" "${line:-"(no summary)"}"
  echo "$p $f $s" > "$OUT/$suite.result"
  $KUBECTL delete job/"$job" --ignore-not-found >/dev/null 2>&1 || true
  echo ""
}

overall=
for s in "${SUITES[@]}"; do
  case "$MODE" in
    each) deploy_jjlab ;;
    once) [ -z "${DEPLOYED:-}" ] && { deploy_jjlab; DEPLOYED=1; } ;;
  esac
  run_suite "$s" || true
  case "$MODE" in
    each) teardown_jjlab ;;
  esac
  f=$(awk '{print $2}' "$OUT/$s.result" 2>/dev/null || echo 0)
  [ "$f" = "0" ] || overall=1
done
[ "$MODE" = "once" ] && teardown_jjlab || true

echo "──────────────────────────────────────────"
echo "k8s run $RUN_ID  ->  $OUT"
TOT_P=0; TOT_F=0; TOT_S=0
for s in "${SUITES[@]}"; do
  read -r p f sk < "$OUT/$s.result" 2>/dev/null || p=0
  printf '  %-12s %-3s passed  %-3s failed  %-3s skipped\n' "$s" "$p" "$f" "$sk"
  TOT_P=$((TOT_P+p)); TOT_F=$((TOT_F+f)); TOT_S=$((TOT_S+sk))
done
echo "TOTAL: $TOT_P passed, $TOT_F failed, $TOT_S skipped"
echo "artifacts: $OUT"
exit "${overall:-0}"