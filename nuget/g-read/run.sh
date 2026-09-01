#!/usr/bin/env bash
# G: read-only metadata/search endpoints over the registry's API surface.
set -uo pipefail
cd "$(dirname "$0")"
source ../../lib.sh
ID=$(cat "$WORK/nuget-name" 2>/dev/null)
LOWER=$(printf '%s' "$ID" | tr 'A-Z' 'a-z')

# service index enumerates read resources
out=$(curl_api "$API/pkgs/nuget/v3/index.json")
assert_contains "G: service index query" "$out" 'SearchQueryService'
assert_contains "G: service index registration" "$out" 'RegistrationsBaseUrl'
assert_contains "G: service index flatcontainer" "$out" 'PackageBaseAddress'

# registration index lists the pushed version
out=$(curl_api "$API/pkgs/nuget/v3/registration/$LOWER/index.json")
[ -n "$ID" ] && assert_contains "G: registration leaf" "$out" '1.0.0'
assert_contains "G: registration packageContent" "$out" 'packageContent'

# flatcontainer index + file
out=$(curl_api "$API/pkgs/nuget/v3/flatcontainer/$LOWER/index.json")
assert_contains "G: flatcontainer versions" "$out" '"versions"'
code=$(curl_api -o /dev/null -w '%{http_code}' "$API/pkgs/nuget/v3/flatcontainer/$LOWER/1.0.0/$LOWER.1.0.0.nupkg")
assert_eq "G: flatcontainer nupkg 200" 200 "$code"

# query + autocomplete
out=$(curl_api "$API/pkgs/nuget/v3/query?q=$LOWER")
[ -n "$ID" ] && assert_contains "G: query finds $LOWER" "$out" "$LOWER"
out=$(curl_api "$API/pkgs/nuget/v3/autocomplete?q=$LOWER")
[ -n "$ID" ] && assert_contains "G: autocomplete finds $LOWER" "$out" "$LOWER"