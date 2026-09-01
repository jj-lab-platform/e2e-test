#!/usr/bin/env bash
# G: read-only metadata/search endpoints over the registry's API surface.
set -uo pipefail
cd "$(dirname "$0")"
source ../../lib.sh
NAME=$(cat "$WORK/npm-pkg-name" 2>/dev/null)

# packument root (npm ping relies on this)
code=$(curl_api -o /dev/null -w '%{http_code}' "$API/pkgs/npm/")
assert_eq "G: npm registry root 200" 200 "$code"

# packument carries dist-tags, versions, and the pushed tarball url
out=$(curl_api "$API/pkgs/npm/$NAME")
[ -n "$NAME" ] && assert_contains "G: packument name" "$out" "$NAME"
assert_contains "G: packument dist-tags" "$out" '"dist-tags"'
assert_contains "G: packument tarball" "$out" '.tgz'

# tarball fetch returns bytes
TB="$NAME-1.0.0.tgz"
code=$(curl_api -o /dev/null -w '%{http_code}' "$API/pkgs/npm/$NAME/-/$TB")
assert_eq "G: tarball downloadable" 200 "$code"