#!/usr/bin/env bash
# G: read-only metadata/search endpoints over the registry's API surface.
set -uo pipefail
cd "$(dirname "$0")"
source ../../lib.sh

# The stored swift scope/name is xcliorg.xclikit (fixed by the suite).
SCOPE="xcliorg"
PKG="xclikit"

# identifiers returns the stored identifier
out=$(curl_api "$API/pkgs/swift/identifiers")
assert_contains "G: identifiers includes scope.name" "$out" 'xcliorg.xclikit'

# releases map carries version keys + url
out=$(curl_api "$API/pkgs/swift/$SCOPE/$PKG" -H 'Accept: application/vnd.swift.registry.v1+json')
assert_contains "G: releases map" "$out" '"releases"'
assert_contains "G: releases includes 1.0.0" "$out" '"1.0.0"'

# version metadata (checksum resources)
out=$(curl_api "$API/pkgs/swift/$SCOPE/$PKG/1.0.0")
assert_contains "G: version meta checksum" "$out" '"source-archive"'

# source archive zip downloadable
code=$(curl_api -o /dev/null -w '%{http_code}' "$API/pkgs/swift/$SCOPE/$PKG/1.0.0.zip")
assert_eq "G: source archive zip 200" 200 "$code"