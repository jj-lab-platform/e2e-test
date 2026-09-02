#!/usr/bin/env bash
# In-container entrypoint: run ONE suite (a single CLI) against the jjlab
# service, then persist its result + workdir into /out for the orchestrator
# to collect. Exits with the suite's own pass/fail code.
set -uo pipefail

SUITE="${SUITE:?SUITE is required}"
export WORK="${WORK:-/work}"
export BASE="${BASE:-http://jj-lab.temp.svc.cluster.local}"
mkdir -p "$WORK" /out/artifacts

# A hard outer timeout guarantees the Job terminates even if a child (e.g. a
# gradle daemon or a skopeo process) holds the stdout pipe open after the
# suite's script finished. Prevents "stuck Running" jobs in the k8s parallel
# orchestrator.
SUITE_TIMEOUT="${SUITE_TIMEOUT:-600}"
timeout "${SUITE_TIMEOUT}" bash "/e2e/$SUITE/run.sh"
rc=$?

echo "$rc" > /out/exit
res=$(ls "$WORK"/*.result 2>/dev/null | head -1 || true)
[ -n "$res" ] && cp "$res" /out/result 2>/dev/null || true
( cd "$WORK" && tar -czf "/out/artifacts/$SUITE.tar.gz" . ) 2>/dev/null || true

exit "$rc"