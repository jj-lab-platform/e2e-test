#!/usr/bin/env bash
# system: /pkgs/system admin surface (upstreams/proxy/packages) C/R/U/D.
set -uo pipefail
cd "$(dirname "$0")"
source ../lib.sh

section "system"
LOG="$WORK/system.log"
: > "$LOG"
if [ -f proxy/run.sh ]; then bash proxy/run.sh >> "$LOG" 2>&1; fi
cat "$LOG"
PASS=$(grep -c 'PASS:' "$LOG" || true); FAIL=$(grep -c 'FAIL:' "$LOG" || true); SKIP=$(grep -c 'SKIP:' "$LOG" || true)
PASS=${PASS:-0}; FAIL=${FAIL:-0}; SKIP=${SKIP:-0}
echo "$PASS $FAIL $SKIP" > "$WORK/system.result"
summary "system"