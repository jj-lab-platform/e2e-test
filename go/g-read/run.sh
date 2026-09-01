#!/usr/bin/env bash
# G: read-only metadata/search endpoints over the registry's API surface.
set -uo pipefail
cd "$(dirname "$0")"
source ../../lib.sh
MOD=$(cat "$WORK/go-mod-name" 2>/dev/null)

# @latest returns the highest semantic version
out=$(curl_api "$API/pkgs/go/$MOD/@latest")
[ -n "$MOD" ] && assert_contains "G: @latest Version field" "$out" '"Version"'

# @v/list returns one version per line (text/plain)
out=$(curl_api "$API/pkgs/go/$MOD/@v/list")
[ -n "$MOD" ] && assert_contains "G: @v/list contains v1.0.0" "$out" 'v1.0.0'

# .info / .mod / .zip are servable for a stored version
out=$(curl_api "$API/pkgs/go/$MOD/@v/v1.0.0.info")
assert_contains "G: .info Version" "$out" '"Version"'
code=$(curl_api -o /dev/null -w '%{http_code}' "$API/pkgs/go/$MOD/@v/v1.0.0.mod")
assert_eq "G: .mod served" 200 "$code"
code=$(curl_api -o /dev/null -w '%{http_code}' "$API/pkgs/go/$MOD/@v/v1.0.0.zip")
assert_eq "G: .zip served" 200 "$code"