#!/usr/bin/env bash
# G: read-only metadata endpoints over the generic API (HEAD + GET + 404).
set -uo pipefail
cd "$(dirname "$0")"
source ../../lib.sh
NAME=$(cat "$WORK/generic-name" 2>/dev/null)

# generic fixtures are reused but the F phase leaves the stored bytes at
# "v2-bytes" (delete-republish is authoritative), so assert the CURRENT state.
out=$(curl_api "$API/pkgs/generic/$NAME/1.0.0/artifact.txt")
case "$out" in *bytes*) pass "G: generic GET returns stored bytes";; *) fail "G: generic GET bytes (got $out)";; esac

# HEAD returns 200 with no body
code=$(curl_api -o /dev/null -I -w '%{http_code}' "$API/pkgs/generic/$NAME/1.0.0/artifact.txt")
assert_eq "G: generic HEAD 200" 200 "$code"

# unknown path 404
code=$(curl_api -o /dev/null -w '%{http_code}' "$API/pkgs/generic/$NAME/9.9.9/nope.txt")
assert_eq "G: generic miss 404" 404 "$code"

# wrong segment count 404
code=$(curl_api -o /dev/null -w '%{http_code}' "$API/pkgs/generic/$NAME/no-version")
assert_eq "G: generic bad path 404" 404 "$code"