#!/usr/bin/env bash
# G: read-only metadata/search endpoints over the registry's API surface.
set -uo pipefail
cd "$(dirname "$0")"
source ../../lib.sh
NAME=$(cat "$WORK/conan-name" 2>/dev/null)

# authenticate returns the round-tripped write token (plain text, not JSON).
out=$(curl_api "$API/pkgs/conan/v2/users/authenticate")
[ "$out" = "$WRITE_TOKEN" ] && pass "G: authenticate returns write token" || fail "G: authenticate returns token (got $out)"

# check_credentials
code=$(curl_api -o /dev/null -w '%{http_code}' "$API/pkgs/conan/v2/users/check_credentials")
assert_eq "G: check_credentials 200" 200 "$code"

# search finds the pushed name/version
out=$(curl_api "$API/pkgs/conan/v2/conans/search?q=$NAME")
[ -n "$NAME" ] && assert_contains "G: search finds $NAME" "$out" "$NAME"

# latest returns a revision
out=$(curl_api "$API/pkgs/conan/v2/conans/$NAME/1.0.0/ci/stable/latest")
assert_contains "G: latest revision field" "$out" '"revision"'

# revisions list (fields: revisions[])
out=$(curl_api "$API/pkgs/conan/v2/conans/$NAME/1.0.0/ci/stable/revisions")
assert_contains "G: revisions listed" "$out" 'revisions'