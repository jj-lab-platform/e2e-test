#!/usr/bin/env bash
# G: read-only metadata/search endpoints over the registry's API surface.
set -uo pipefail
cd "$(dirname "$0")"
source ../../lib.sh
NAME=$(cat "$WORK/comp-name" 2>/dev/null)

# packages.json root with metadata-url / providers
code=$(curl_api -o /dev/null -w '%{http_code}' "$API/pkgs/composer/packages.json")
assert_eq "G: composer packages.json 200" 200 "$code"
out=$(curl_api "$API/pkgs/composer/packages.json")
assert_contains "G: metadata-url set" "$out" 'metadata-url'

# p2 metadata lists the pushed version (json)
out=$(curl_api "$API/pkgs/composer/p2/e2e-test/$NAME.json")
[ -n "$NAME" ] && assert_contains "G: p2 includes $NAME" "$out" "$NAME"
assert_contains "G: p2 includes dist" "$out" '"dist"'

# search.json returns results for query
out=$(curl_api "$API/pkgs/composer/search.json?q=$NAME")
[ -n "$NAME" ] && assert_contains "G: search finds $NAME" "$out" "$NAME"

# list.json returns packageNames
out=$(curl_api "$API/pkgs/composer/list.json")
[ -n "$NAME" ] && assert_contains "G: list.json includes $NAME" "$out" "$NAME"

# bin-compat providers endpoint
code=$(curl_api -o /dev/null -w '%{http_code}' "$API/pkgs/composer/providers/e2e-test/$NAME.json")
assert_eq "G: providers .json 200" 200 "$code"