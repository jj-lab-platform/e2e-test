#!/usr/bin/env bash
# Auth boundary: every protocol enforces read-only-anon + write-requires-token.
set -uo pipefail
cd "$(dirname "$0")"
source ../lib.sh
source ../flag.sh
AU="$API/pkgs/system"
AO="$API/v2"
WRITE="$WRITE_TOKEN"

# 1) anonymous read OK
code=$(curl_anon -o /dev/null -w '%{http_code}' "$AU/upstreams")
assert_code "anon read: system upstreams 200" 200 "$code"

# 2) anonymous write denied
code=$(curl_anon -o /dev/null -w '%{http_code}' -X PUT "$AU/upstreams/npm" -H 'Content-Type: application/json' -d '{"url":"https://x.example"}')
assert_code "anon write: system PUT 401" 401 "$code"

# 3) write token (Authorization: token <t>) write OK
code=$(curl_api -o /dev/null -w '%{http_code}' -X PUT "$AU/upstreams/npm" -H 'Content-Type: application/json' -d '{"url":"https://registry.npmjs.org"}')
assert_status_in "write token: system PUT" "$code" "200 201"

# 4) unknown upstream key rejects write (404) but read 404 too
code=$(curl_anon -o /dev/null -w '%{http_code}' "$AU/upstreams/nonexistent")
assert_code "anon read: unknown upstream 404" 404 "$code"
code=$(curl_api -o /dev/null -w '%{http_code}' -X PUT "$AU/upstreams/nonexistent" -H 'Content-Type: application/json' -d '{"url":"https://x"}')
assert_code "write: unknown upstream 404" 404 "$code"

# 5) system packages anonymous read lists repositories
code=$(curl_anon -o /dev/null -w '%{http_code}' "$AU/packages")
assert_code "anon read: system packages 200" 200 "$code"

# 6) npm: anonymous publish denied, bearer token publish OK
AN="$API/pkgs/npm"
code=$(curl_anon -o /dev/null -w '%{http_code}' -X PUT "$AN/x-auth-deny" -H 'Content-Type: application/json' -d '{"name":"x-auth-deny","versions":{"1.0.0":{"name":"x-auth-deny","version":"1.0.0"}}}')
assert_code "anon npm publish 401" 401 "$code"
code=$(curl_api -o /dev/null -w '%{http_code}' -X PUT "$AN/x-auth-ok" -H 'Content-Type: application/json' -H "Authorization: Bearer $WRITE" -d '{"name":"x-auth-ok","versions":{"1.0.0":{"name":"x-auth-ok","version":"1.0.0"}}}')
assert_status_in "bearer token npm publish" "$code" "200 201"

# 7) OCI: anonymous /v2/ 401 challenge; token flow allows push.
code=$(curl_anon -o /dev/null -w '%{http_code}' "$AO/")
assert_code "OCI anon ping 401" 401 "$code"
CH=$(curl_anon -I "$AO/" 2>/dev/null | grep -i www-authenticate | head -1)
assert_contains "OCI WWW-Authenticate challenge" "$CH" 'Bearer realm'
assert_contains "OCI realm uses self_base" "$CH" "$REG_HOST"
TOK=$(curl_api "$API/v2/token?service=oci-registry&scope=repository:x-auth-oci:push,pull" -H "Authorization: token $WRITE" | python3 -c "import json,sys; print(json.load(sys.stdin)['token'])" 2>/dev/null)
[ -n "$TOK" ] && pass "OCI token issued" || fail "OCI token issued"
echo -n "auth-blob-data" > "$WORK/auth-blob"
BD="sha256:$(sha256sum "$WORK/auth-blob" | cut -d' ' -f1)"
code=$(curl_api -o /dev/null -w '%{http_code}' -X POST --data-binary @"$WORK/auth-blob" "$AO/x-auth-oci/blobs/uploads/?digest=$BD" -H "Authorization: Bearer $TOK")
assert_status_in "OCI push with token" "$code" "200 201"

# 8) nuget: anonymous push denied, X-NuGet-ApiKey (write token) push OK
python3 - <<PYEOF
import zipfile
z = zipfile.ZipFile('$WORK/xcli-auth.nupkg','w')
z.writestr('xcli.auth.nuspec', '<package><metadata><id>Xcli.Auth</id><version>1.0.0</version></metadata></package>')
z.close()
PYEOF
ANU="$API/pkgs/nuget"
code=$(curl_anon -o /dev/null -w '%{http_code}' -X PUT --data-binary @"$WORK/xcli-auth.nupkg" "$ANU/api/v2/package")
assert_code "anon nuget push 401" 401 "$code"
code=$(curl_api -o /dev/null -w '%{http_code}' -X PUT --data-binary @"$WORK/xcli-auth.nupkg" -H "X-NuGet-ApiKey: $WRITE" "$ANU/api/v2/package")
assert_status_in "X-NuGet-ApiKey push" "$code" "200 201"

# 9) per-protocol anonymous write matrix (generic/pypi/maven/composer)
code=$(curl_anon -o /dev/null -w '%{http_code}' -X PUT "$API/pkgs/generic/x-anon/1.0.0/f.txt" --data-binary "x")
assert_code "anon generic PUT 401" 401 "$code"
code=$(curl_anon -o /dev/null -w '%{http_code}' -X POST "$API/pkgs/pypi/upload" -F name=x-anon -F version=1.0.0 -F content=@/dev/null)
assert_code "anon pypi upload 401" 401 "$code"
code=$(curl_anon -o /dev/null -w '%{http_code}' -X PUT "$API/pkgs/maven/com/x/anon/1.0.0/anon-1.0.0.pom" --data-binary "<project/>")
assert_code "anon maven PUT 401" 401 "$code"
code=$(curl_anon -o /dev/null -w '%{http_code}' -X PUT "$API/pkgs/composer/api/packages" --data-binary "x")
assert_code "anon composer PUT 401" 401 "$code"
code=$(curl_anon -o /dev/null -w '%{http_code}' -X POST "$API/pkgs/helm/api/charts" --data-binary "x")
assert_code "anon helm upload 401" 401 "$code"
code=$(curl_anon -o /dev/null -w '%{http_code}' -X PUT "$API/pkgs/go/upload?module=x/y&version=v1.0.0" --data-binary "x")
assert_code "anon go upload 401" 401 "$code"
code=$(curl_anon -o /dev/null -w '%{http_code}' -X POST "$API/pkgs/hex/packages/x/releases" --data-binary "x")
assert_code "anon hex publish 401" 401 "$code"
code=$(curl_anon -o /dev/null -w '%{http_code}' -X POST "$API/pkgs/pub/api/packages/versions/newUpload" --data-binary "x")
assert_code "anon pub upload 401" 401 "$code"

# 10) skopeo push with creds OK; anonymous denied.
if have skopeo && [ "$(flag DOCKER_OK)" = "1" ]; then
  if skopeo copy --src-tls-verify=false --dest-tls-verify=false --dest-creds "x:$WRITE" "docker://$REG_HOST/library/alpine:latest" "docker://$REG_HOST/x-auth/alpine:ok" >/dev/null 2>&1; then
    pass "skopeo push with creds"
  else
    fail "skopeo push with creds"
  fi
  if skopeo copy --src-tls-verify=false --dest-tls-verify=false "docker://$REG_HOST/library/alpine:latest" "docker://$REG_HOST/x-auth/alpine:denied" >/dev/null 2>&1; then
    fail "skopeo push anon should fail"
  else
    pass "skopeo push anon denied"
  fi
else
  skip "skopeo/docker.io unavailable"
fi

echo "$PASS $FAIL $SKIP" > "$WORK/auth.result"
summary "auth"