#!/usr/bin/env bash
# G: read-only metadata/search endpoints over the registry's API surface.
set -uo pipefail
cd "$(dirname "$0")"
source ../../lib.sh
NAME=$(cat "$WORK/helm-name" 2>/dev/null)

# index.yaml enumerates the chart and both versions
out=$(curl_api "$API/pkgs/helm/index.yaml")
assert_contains "G: index.yaml apiVersion" "$out" 'apiVersion: v1'
[ -n "$NAME" ] && assert_contains "G: index lists $NAME" "$out" "$NAME"
assert_contains "G: index lists 0.2.0" "$out" '0.2.0'

# chart tarball endpoint serves
code=$(curl_api -o /dev/null -w '%{http_code}' "$API/pkgs/helm/charts/$NAME-0.2.0.tgz")
assert_eq "G: chart tgz 200" 200 "$code"