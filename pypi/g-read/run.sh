#!/usr/bin/env bash
# G: read-only metadata/search endpoints over the registry's API surface.
set -uo pipefail
cd "$(dirname "$0")"
source ../../lib.sh
NAME=$(cat "$WORK/py-pkg-name" 2>/dev/null)

# /simple/ index (HTML) links the project
out=$(curl_api "$API/pkgs/pypi/simple/")
[ -n "$NAME" ] && assert_contains "G: simple root lists $NAME" "$out" "$NAME"

# /simple/{name}/  HTML shows the wheel link + sha256 anchor
out=$(curl_api "$API/pkgs/pypi/simple/$NAME/")
assert_contains "G: simple project wheel link" "$out" '.whl'
assert_contains "G: simple project sha256" "$out" 'sha256='

# PEP 658 / JSON form (vnd.pypi.simple.v1+json)
code=$(curl_api -o /dev/null -w '%{http_code}' "$API/pkgs/pypi/simple/$NAME/" -H 'Accept: application/vnd.pypi.simple.v1+json')
assert_eq "G: simple JSON 200" 200 "$code"
out=$(curl_api "$API/pkgs/pypi/simple/$NAME/" -H 'Accept: application/vnd.pypi.simple.v1+json')
assert_contains "G: simple JSON files[]" "$out" '"files"'
assert_contains "G: simple JSON filename" "$out" '"filename"'

# delete files endpoint rejects anonymous? (auth is already proven; here read path)
code=$(curl_api -o /dev/null -w '%{http_code}' "$API/pkgs/pypi/simple/$NAME/")
assert_eq "G: project page reachable" 200 "$code"