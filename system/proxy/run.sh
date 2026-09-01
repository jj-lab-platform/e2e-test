#!/usr/bin/env bash
# H: system /proxy + /upstreams + /packages runtime admin surface.
set -uo pipefail
cd "$(dirname "$0")"
source ../../lib.sh
SYS="$API/pkgs/system"
WRITE="$WRITE_TOKEN"

out=$(curl_api "$SYS/upstreams")
assert_contains "H: upstreams object" "$out" '"upstreams"'

out=$(curl_api "$SYS/proxy")
assert_contains "H: proxy list" "$out" '"proxy"'
assert_contains "H: proxy states cover npm" "$out" '"npm"'

out=$(curl_api "$SYS/proxy/npm")
assert_contains "H: proxy/npm key" "$out" '"proxy"'

code=$(curl_api -o /dev/null -w '%{http_code}' -X PUT "$SYS/proxy/npm" -H 'Content-Type: application/json' -d '{"proxy":"http://mihomo.develop.svc.cluster.local:7890"}')
assert_eq "H: set proxy npm 200" 200 "$code"
out=$(curl_api "$SYS/proxy/npm")
assert_contains "H: proxy/npm now set" "$out" 'mihomo'

code=$(curl_api -o /dev/null -w '%{http_code}' -X DELETE "$SYS/proxy/npm")
assert_eq "H: reset proxy npm 200" 200 "$code"
out=$(curl_api "$SYS/proxy/npm")
case "$out" in *mihomo*) fail "H: proxy reset";; *) pass "H: proxy reset direct";; esac

code=$(curl_api -o /dev/null -w '%{http_code}' -X PUT "$SYS/proxy/cargo" -H 'Content-Type: application/json' -d '{"proxy":"http://127.0.0.1:9"}')
assert_eq "H: set proxy cargo 200" 200 "$code"
out=$(curl_api "$SYS/proxy/cargo.static")
assert_contains "H: cargo.static walks to cargo proxy" "$out" '127.0.0.1'
code=$(curl_api -o /dev/null -w '%{http_code}' -X DELETE "$SYS/proxy/cargo")
assert_eq "H: reset proxy cargo 200" 200 "$code"

code=$(curl_api -o /dev/null -w '%{http_code}' "$SYS/proxy/nope")
assert_eq "H: get unknown proxy 404" 404 "$code"
code=$(curl_api -o /dev/null -w '%{http_code}' -X PUT "$SYS/proxy/nope" -H 'Content-Type: application/json' -d '{"proxy":"x"}')
assert_eq "H: set unknown proxy 404" 404 "$code"

out=$(curl_api "$SYS/packages")
assert_contains "H: system packages object" "$out" '"packages"'