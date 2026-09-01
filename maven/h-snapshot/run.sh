#!/usr/bin/env bash
# H: SNAPSHOT semantics — upload a timestamped snapshot and assert both the
# version-level <snapshot> block and the artifact-level <release> exclusion.
set -uo pipefail
cd "$(dirname "$0")"
source ../../lib.sh
ARM=$(cat "$WORK/mvn-art-name" 2>/dev/null)

# Upload a timestamped snapshot artifact (maven timestamped form).
SNAP="${ARM}-1.0.1-20240101.120000-1.jar"
code=$(curl_api -s -o /dev/null -w '%{http_code}' -X PUT "$API/pkgs/maven/com/e2e/$ARM/1.0.1-SNAPSHOT/$SNAP" --data-binary "snapshot-bytes")
assert_eq "H: snapshot upload" 201 "$code"

# version-level metadata for the SNAPSHOT version emits the timestamp block.
out=$(curl_api "$API/pkgs/maven/com/e2e/$ARM/1.0.1-SNAPSHOT/maven-metadata.xml")
assert_contains "H: snapshot timestamp block" "$out" '<snapshot>'
assert_contains "H: snapshot timestamp value" "$out" '<timestamp>20240101.120000</timestamp>'
assert_contains "H: snapshot build number" "$out" '<buildNumber>1</buildNumber>'

# artifact-level metadata: the SNAPSHOT is listed as a version but never
# promoted to <release> (release = highest non-snapshot => 10.0.0).
out=$(curl_api "$API/pkgs/maven/com/e2e/$ARM/maven-metadata.xml")
assert_contains "H: versions lists snapshot" "$out" '1.0.1-SNAPSHOT'
assert_contains "H: release == 10.0.0 (not snapshot)" "$out" '<release>10.0.0</release>'