#!/usr/bin/env bash
# G: read-only metadata/search endpoints over the registry's own API surface.
set -uo pipefail
cd "$(dirname "$0")"
source ../../lib.sh
NAME=$(cat "$WORK/cargo-pkg-name" 2>/dev/null)

# config.json exists for sparse-index bootstrap
out=$(curl_api "$API/pkgs/cargo/config.json")
assert_contains "G: config.json served" "$out" 'dl'

# /me endpoint
out=$(curl_api "$API/pkgs/cargo/me")
assert_contains "G: /me returns user" "$out" '"login"'

# search returns the pushed crate
out=$(curl_api "$API/pkgs/cargo/api/v1/crates?q=$NAME")
[ -n "$NAME" ] && assert_contains "G: search finds $NAME" "$out" "$NAME"
assert_contains "G: search total" "$out" '"total"'

# crate metadata (api/v1/crates/{name}) lists versions
out=$(curl_api "$API/pkgs/cargo/api/v1/crates/$NAME")
[ -n "$NAME" ] && assert_contains "G: crate meta lists version" "$out" '1.0.0'

# owners (was empty; add/remove round-trips)
code=$(curl_api -o /dev/null -w '%{http_code}' -X PUT "$API/pkgs/cargo/api/v1/crates/$NAME/owners" -H 'Content-Type: application/json' -d '{"users":["alice","bob"]}')
assert_eq "G: cargo add owners" 200 "$code"
out=$(curl_api "$API/pkgs/cargo/api/v1/crates/$NAME/owners")
assert_contains "G: owners listed" "$out" 'alice'
code=$(curl_api -o /dev/null -w '%{http_code}' -X DELETE "$API/pkgs/cargo/api/v1/crates/$NAME/owners" -H 'Content-Type: application/json' -d '{"users":["bob"]}')
assert_eq "G: cargo remove owner" 200 "$code"
out=$(curl_api "$API/pkgs/cargo/api/v1/crates/$NAME/owners")
case "$out" in *bob*) fail "G: owner removed";; *) pass "G: owner removed";; esac

# yank status is reflected in sparse index
out=$(curl_api "$API/pkgs/cargo/$NAME")
assert_contains "G: sparse index lists $NAME" "$out" "$NAME"