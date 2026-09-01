#!/usr/bin/env bash
# G: read-only metadata/search endpoints over the registry's API surface.
set -uo pipefail
cd "$(dirname "$0")"
source ../../lib.sh
ARM=$(cat "$WORK/mvn-art-name" 2>/dev/null)

# artifact-level maven-metadata.xml exposes the version list + <release>
out=$(curl_api "$API/pkgs/maven/com/e2e/$ARM/maven-metadata.xml")
assert_contains "G: metadata lists versions" "$out" '<versions>'
assert_contains "G: metadata release set" "$out" '<release>'
[ -n "$ARM" ] && assert_contains "G: metadata mentions $ARM" "$out" "$ARM"

# version-level metadata rejects snapshot routing on a plain (numeric-looking)
# artifactId that isn't -SNAPSHOT: still served as artifact metadata.
out=$(curl_api "$API/pkgs/maven/com/e2e/$ARM/maven-metadata.xml")
assert_contains "G: artifactId with digits ok" "$out" "$ARM"