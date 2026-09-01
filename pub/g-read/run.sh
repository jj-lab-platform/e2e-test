#!/usr/bin/env bash
# G: read-only metadata/search endpoints over the registry's API surface.
set -uo pipefail
cd "$(dirname "$0")"
source ../../lib.sh
NAME=$(cat "$WORK/pub-name" 2>/dev/null)

# /api/packages list
out=$(curl_api "$API/pkgs/pub/api/packages")
[ -n "$NAME" ] && assert_contains "G: packages list includes $NAME" "$out" "$NAME"
assert_contains "G: packages list total" "$out" '"total"'

# versions/new
out=$(curl_api "$API/pkgs/pub/api/packages/versions/new")
assert_contains "G: versions new url" "$out" 'newUpload'

# pkg metadata: latest + versions list + archive_sha256
out=$(curl_api "$API/pkgs/pub/api/packages/$NAME")
assert_contains "G: pkg metadata latest" "$out" '"latest"'
[ -n "$NAME" ] && assert_contains "G: pkg metadata version" "$out" '"1.0.0"'
assert_contains "G: pkg metadata sha256" "$out" 'archive_sha256'

# version metadata
code=$(curl_api -o /dev/null -w '%{http_code}' "$API/pkgs/pub/api/packages/$NAME/versions/1.0.0")
assert_eq "G: version metadata 200" 200 "$code"

# advisories
out=$(curl_api "$API/pkgs/pub/api/packages/$NAME/advisories")
assert_contains "G: advisories array" "$out" '"advisories"'

# newUploadFinish (POST, write) returns success envelope
out=$(curl_api -X POST "$API/pkgs/pub/api/packages/versions/newUploadFinish")
assert_contains "G: newUploadFinish success" "$out" 'Successfully uploaded'