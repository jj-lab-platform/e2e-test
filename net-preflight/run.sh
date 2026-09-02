#!/usr/bin/env bash
# Upstream connectivity preflight: writes a flags file consumed by other suites.
set -uo pipefail
cd "$(dirname "$0")"
source ../lib.sh
section "net-preflight"

FLAGS="$WORK/upstream.flags"
: > "$FLAGS"
# probe the in-cluster registry (BASE) — pull-through handles the public
# upstream, so the runner never needs egress.
BF="${BF:-${API:-${BASE:-http://jj-lab.temp.svc.cluster.local}}}"

probe() { # probe <flag> <url> [proxy]
  local flag="$1" url="$2" p="${3:-}" code
  if [ -n "$p" ]; then
    code=$(env -u no_proxy -u NO_PROXY curl -s --max-time 12 -o /dev/null -w '%{http_code}' -x "$p" "$url" 2>/dev/null || true)
  else
    code=$(curl -s --noproxy '*' --max-time 8 -o /dev/null -w '%{http_code}' "$url" 2>/dev/null || true)
  fi
  if [[ "$code" =~ ^[0-9]{3}$ ]] && [ "$code" -ge 200 ] && [ "$code" -lt 500 ]; then
    echo "$flag=1" >> "$FLAGS"
    pass "$flag reachable ($code)"
  else
    echo "$flag=0" >> "$FLAGS"
    skip "$flag unreachable ($code)"
  fi
}

# In-cluster pull-through reachability (jjlab serves all protocols; the
# pull-through itself reaches the public upstream, so the runner needs no
# egress). Probe the jjlab registry paths each protocol uses.
probe NPM_OK    "$BF/pkgs/npm/lodash"
probe PYPI_OK   "$BF/pkgs/pypi/simple/requests/"
probe CARGO_OK  "$BF/pkgs/cargo/config.json"
probe CARGO_STATIC_OK "$BF/pkgs/cargo/index/config.json"
probe MAVEN_OK  "$BF/pkgs/maven/junit/junit/maven-metadata.xml"
probe COMPOSER_OK "$BF/pkgs/composer/p2/symfony/console.json"
probe NUGET_OK  "$BF/pkgs/nuget/v3/index.json"
probe RUBYGEMS_OK "$BF/pkgs/rubygems/versions"
probe HEX_OK    "$BF/pkgs/hex/api/packages/jason"
probe PUB_OK    "$BF/pkgs/pub/api/packages/http"
probe CONAN_OK  "$BF/pkgs/conan/v2/conans/search?q=zlib"
probe DOCKER_OK "$BF/v2/"
probe GITHUB_OK "$BF/pkgs/go/github.com/pkg/errors/@v/list"
probe GO_OK     "$BF/pkgs/go/github.com/pkg/errors/@v/list"

echo "$PASS $FAIL $SKIP" > "$WORK/net-preflight.result"
summary "net-preflight"
