#!/usr/bin/env bash
# oci: skopeo inspect/ls/copy/delete + pull-through alpine.
set -uo pipefail
cd "$(dirname "$0")"
source ../lib.sh
source ../flag.sh

section "oci"
R="${REG_HOST}"

have skopeo || { skip "skopeo not installed"; echo "$PASS $FAIL $SKIP" > "$WORK/oci.result"; summary "oci"; exit 0; }

# A: pull-through from docker.io. The CLIENT only talks to our registry (no
# docker.io access needed); on a local miss the SERVER fetches alpine from
# docker.io through its own proxy and caches it.
if [ "$(flag DOCKER_OK)" = "1" ]; then
  DPT=$(dir oci-pt)
  if skopeo copy --src-tls-verify=false "docker://$R/library/alpine:latest" "dir:$DPT/alpine" >/dev/null 2>&1; then
    pass "A: skopeo pull-through alpine"
  else
    fail "A: skopeo pull-through alpine"
  fi
  out=$(curl_api "$API/pkgs/system/packages")
  assert_contains "A: alpine cached" "$out" 'alpine'
else
  skip "A: docker.io unreachable"
fi

# B: push a self-built OCI image (curl upload of config+layer+manifest).
D=$(dir oci-b)
mkdir -p "$D/oci"
NAME="e2eoci$RUN_ID"
echo "$NAME" > "$WORK/oci-name"
CFG='{"architecture":"amd64","os":"linux","rootfs":{"type":"layers","diff_ids":[]}}'
CFG_SHA=$(echo -n "$CFG" | sha256sum | cut -d' ' -f1)
CFG_SIZE=$(echo -n "$CFG" | wc -c)
LAYER='hello-oci-layer'
echo -n "$LAYER" | gzip -n > "$D/oci/layer.gz"
LAYER_SHA=$(sha256sum "$D/oci/layer.gz" | cut -d' ' -f1)
LAYER_SIZE=$(wc -c < "$D/oci/layer.gz")
echo -n "$CFG" > "$D/oci/cfg.json"
curl_api -o /dev/null -X POST --data-binary @"$D/oci/cfg.json" "$API/v2/e2e/$NAME/blobs/uploads/?digest=sha256:$CFG_SHA"
curl_api -o /dev/null -X POST --data-binary @"$D/oci/layer.gz" "$API/v2/e2e/$NAME/blobs/uploads/?digest=sha256:$LAYER_SHA"
MANIFEST=$(python3 -c "
import json, hashlib
cfg_bytes=open('$D/oci/cfg.json','rb').read()
layer_gz=open('$D/oci/layer.gz','rb').read()
m={'schemaVersion':2,'mediaType':'application/vnd.oci.image.manifest.v1+json',
   'config':{'mediaType':'application/vnd.oci.image.config.v1+json','digest':'sha256:$CFG_SHA','size':len(cfg_bytes)},
   'layers':[{'mediaType':'application/vnd.oci.image.layer.v1.tar+gzip','digest':'sha256:$LAYER_SHA','size':len(layer_gz)}]}
print(json.dumps(m))")
echo -n "$MANIFEST" > "$D/oci/manifest.json"
code=$(curl_api -o /dev/null -w '%{http_code}' -X PUT -H 'Content-Type: application/vnd.oci.image.manifest.v1+json' --data-binary @"$D/oci/manifest.json" "$API/v2/e2e/$NAME/manifests/1.0.0")
assert_eq "B: oci manifest push $NAME" 201 "$code"

# C: consume the pushed image back to dir
out=$(skopeo inspect --tls-verify=false --creds "x:$WRITE_TOKEN" "docker://$R/e2e/$NAME:1.0.0" 2>/dev/null)
assert_contains "C: skopeo inspect pushed" "$out" '"Digest"'
skopeo copy --src-tls-verify=false --dest-creds "x:$WRITE_TOKEN" "docker://$R/e2e/$NAME:1.0.0" "dir:$D/dl" >/dev/null 2>&1 \
  && pass "C: skopeo copy back" || fail "C: skopeo copy back"
code=$(skopeo delete --tls-verify=false --creds "x:$WRITE_TOKEN" "docker://$R/e2e/$NAME:1.0.0" >/dev/null 2>&1; echo $?)
[ "$code" = "0" ] && pass "C: skopeo delete" || fail "C: skopeo delete"

# G: registry metadata endpoints — _catalog + tags/list.
CC=$(curl_api "$API/v2/_catalog")
assert_contains "G: _catalog repositories" "$CC" '"repositories"'
CC=$(curl_api "$API/v2/e2e/$NAME/tags/list")
assert_contains "G: tags/list lists 1.0.0" "$CC" '"1.0.0"'

# H: chunked (PATCH) blob upload with resumed session + digest commit.
H=$(dir oci-h)
echo -n "chunked-oci-layer" > "$H/payload"
H_SHA=$(sha256sum "$H/payload" | cut -d' ' -f1)
# split into first half (PATCH) and second half (final PUT), same session.
hsize=$(wc -c < "$H/payload")
h1=$((hsize / 2))
dd if="$H/payload" of="$H/chunk1" bs=1 count=$h1 2>/dev/null
dd if="$H/payload" of="$H/chunk2" bs=1 skip=$h1 2>/dev/null
# start session (POST, no digest) -> capture Location
LOC=$(curl_api -i -X POST "$API/v2/e2e/$NAME/blobs/uploads/" 2>/dev/null | grep -i '^location:' | tr -d '\r' | awk '{print $2}' | sed 's|^/||')
if [ -n "$LOC" ]; then
  code=$(curl_api -o /dev/null -w '%{http_code}' -X PATCH -H 'Content-Type: application/octet-stream' --data-binary @"$H/chunk1" "$API/v2/$LOC")
  assert_eq "H: PATCH chunk1 202" 202 "$code"
  off=$((h1))
  code=$(curl_api -o /dev/null -w '%{http_code}' -X PUT -H "Content-Range: $off-$((hsize-1))" --data-binary @"$H/chunk2" "$API/v2/$LOC?digest=sha256:$H_SHA")
  assert_eq "H: final PUT commit 201" 201 "$code"
  # blob now stat-able
  code=$(curl_api -o /dev/null -w '%{http_code}' -I "$API/v2/e2e/$NAME/blobs/sha256:$H_SHA")
  assert_eq "H: blob HEAD after commit 200" 200 "$code"
else
  fail "H: upload session Location missing"
fi

echo "$PASS $FAIL $SKIP" > "$WORK/oci.result"
summary "oci"
