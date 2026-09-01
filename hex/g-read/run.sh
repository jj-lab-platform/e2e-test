#!/usr/bin/env bash
# G: read-only metadata/search endpoints over the registry's API surface.
set -uo pipefail
cd "$(dirname "$0")"
source ../../lib.sh
PKG=$(cat "$WORK/hex-pkgname" 2>/dev/null)

# public_key (PEM)
out=$(curl_api "$API/pkgs/hex/public_key")
assert_contains "G: public_key PEM" "$out" 'BEGIN PUBLIC KEY'

# names / versions are signed+gzipped protobuf — assert gzip magic + payload
curl_api "$API/pkgs/hex/names" -o "$WORK/hex-names.gz"
hdr=$(od -An -tx1 -N2 "$WORK/hex-names.gz" 2>/dev/null | tr -d ' ')
[ "$hdr" = "1f8b" ] && pass "G: names gzip magic" || fail "G: names gzip magic (got $hdr)"
gunzip -c "$WORK/hex-names.gz" 2>/dev/null | strings | grep -q "$PKG" && pass "G: names includes $PKG" || fail "G: names includes $PKG"

curl_api "$API/pkgs/hex/versions" -o "$WORK/hex-versions.gz"
hdr=$(od -An -tx1 -N2 "$WORK/hex-versions.gz" 2>/dev/null | tr -d ' ')
[ "$hdr" = "1f8b" ] && pass "G: versions gzip magic" || fail "G: versions gzip magic (got $hdr)"
gunzip -c "$WORK/hex-versions.gz" 2>/dev/null | strings | grep -q "$PKG" && pass "G: versions includes $PKG" || fail "G: versions includes $PKG"

# package metadata (signed+gzipped protobuf) — always carries the package
# name (field 2). Version strings depend on which releases survived D/E, so
# assert the stable identifier instead.
curl_api "$API/pkgs/hex/packages/$PKG" -o "$WORK/hex-pkg.bin"
( gunzip -c "$WORK/hex-pkg.bin" 2>/dev/null || cat "$WORK/hex-pkg.bin" 2>/dev/null ) \
  | strings | grep -q "$PKG" && pass "G: pkg metadata includes name" || fail "G: pkg metadata includes name"

# owners returns []
code=$(curl_api -o /dev/null -w '%{http_code}' "$API/pkgs/hex/packages/$PKG/owners")
assert_eq "G: owners 200" 200 "$code"