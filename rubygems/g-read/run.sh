#!/usr/bin/env bash
# G: read-only metadata/search endpoints over the registry's API surface.
set -uo pipefail
cd "$(dirname "$0")"
source ../../lib.sh
NAME=$(cat "$WORK/gem-name" 2>/dev/null)

# compact index /versions contains the pushed gem + version
out=$(curl_api "$API/pkgs/rubygems/versions")
[ -n "$NAME" ] && assert_contains "G: versions index lists $NAME" "$out" "$NAME"

# /info/{name}
out=$(curl_api "$API/pkgs/rubygems/info/$NAME")
assert_contains "G: compact info" "$out" '---'

# api/v1/versions/{name}.json (JSON array with number fields)
out=$(curl_api "$API/pkgs/rubygems/api/v1/versions/$NAME.json")
assert_contains "G: versions api number" "$out" '"number"'
[ -n "$NAME" ] && assert_contains "G: versions api 1.0.1" "$out" '1.0.1'

# api/v1/versions/{name}/latest
out=$(curl_api "$API/pkgs/rubygems/api/v1/versions/$NAME/latest")
assert_contains "G: latest version field" "$out" '"version"'

# api/v1/gems/{name} (text/plain) + search
out=$(curl_api "$API/pkgs/rubygems/api/v1/gems/$NAME")
[ -n "$NAME" ] && assert_contains "G: gems info lists 1.0.1" "$out" '1.0.1'
out=$(curl_api "$API/pkgs/rubygems/api/v1/search.json?query=$NAME")
[ -n "$NAME" ] && assert_contains "G: search finds $NAME" "$out" "$NAME"

# dependencies (Bundler resolver) — Marshal 4.8 stream starts 0x04 0x08
code=$(curl_api -o "$WORK/gem-dep.bin" -w '%{http_code}' "$API/pkgs/rubygems/api/v1/dependencies?gems=$NAME")
assert_eq "G: dependencies 200" 200 "$code"
hdr=$(od -An -tx1 -N2 "$WORK/gem-dep.bin" 2>/dev/null | tr -d ' ')
case "$hdr" in 0408) pass "G: dependencies marshal header";; *) fail "G: dependencies marshal header (got $hdr)";; esac