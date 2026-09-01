#!/usr/bin/env bash
# Shared helpers for the jjlab package-registry end-to-end suites.
#
# Drives the REAL jjlab service over the cluster DNS name — not a local port —
# so the exact in-process pkglab registry surface (OCI /v2 + /pkgs/<fmt>) plus
# jjlab's token auth model are exercised against the deployed server.
#
#   A (a-pull)   : official client pulls a PUBLIC package through pull-through
#   B (b-push)   : official client publishes a self-made package
#   C (c-consume): a fresh project consumes the package pushed in B
#   D (d-mutate) : deprecate/yank/retire/unlist/delete (or immutable 405)
#   E (e-upgrade): publish a new version, assert latest/index move semantically
#   F (f-republish): same-version overwrite + delete-republish + name norm

set -uo pipefail

# The registry is served in-process by jjlab at its cluster address. The
# HTTP surface is the SAME router as the git REST + SPA, so these paths prove
# the registry is not shadowed by the catch-all.
REGISTRY_BASE="${REGISTRY_BASE:-${BASE:-http://jj-lab.temp.svc.cluster.local}}"
API="$REGISTRY_BASE"
# Hostname (no scheme/port) derived from the target, so suites that need a
# bare registry host for OCI/skopeo URLs follow whatever the harness points at.
REG_HOST="${REGISTRY_BASE#*://}"
REG_HOST="${REG_HOST%%/*}"
export REG_HOST

# SwiftPM's package-registry `login` requires HTTPS (no --allow-insecure-http
# on that subcommand), so the swift suite targets the wildcard nip.io https
# face of *the same* harness instance. `<name>.<ns>.svc.cluster.local` maps to
# `<name>.<ns>.10.199.64.20.nip.io` via the host Caddy gateway (wildcard TLS,
# CA bundled into the runners). Explicitly overridable via SWIFT_BASE.
if [ -z "${SWIFT_BASE:-}" ] && [[ "$API" == http://*.svc.cluster.local ]]; then
  SWIFT_BASE="https://${API#http://}"
  SWIFT_BASE="${SWIFT_BASE%.svc.cluster.local}.10.199.64.20.nip.io"
fi
export SWIFT_BASE

# jjlab token auth: JJLAB_TOKENS="devtoken=write" (single write token).
# Anonymous = read-only. Write paths must present the write token.
WRITE_TOKEN="${WRITE_TOKEN:-devtoken}"
# TOKEN is the legacy name used across the ported suites; point it at the
# write token so every CLI's credential slot carries the jjlab token.
TOKEN="${TOKEN:-$WRITE_TOKEN}"

WORK="${WORK:-$(mktemp -d)}"
export WORK
if [ -z "${RUN_ID:-}" ]; then
  if [ -f "$WORK/.run_id" ]; then RUN_ID=$(cat "$WORK/.run_id"); else
    RUN_ID="$(date +%s)$RANDOM"; echo "$RUN_ID" > "$WORK/.run_id"
  fi
fi
export RUN_ID

PASS="${PASS:-0}"; FAIL="${FAIL:-0}"; SKIP="${SKIP:-0}"
export PASS FAIL SKIP

pass() { echo "    PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "    FAIL: $1"; FAIL=$((FAIL+1)); }
skip() { echo "    SKIP: $1"; SKIP=$((SKIP+1)); }

section() { echo ""; echo "  [$1]"; }

assert_eq() {
  if [ "$2" = "$3" ]; then pass "$1 ($3)"; else fail "$1 (want $2, got $3)"; fi
}

assert_code() {
  if [ "$2" = "$3" ]; then pass "$1 ($3)"; else fail "$1 (want $2, got $3)"; fi
}

assert_status_in() {
  case " $3 " in
    *" $2 "*) pass "$1 ($2)";;
    *) fail "$1 (got $2, want one of: $3)";;
  esac
}

assert_contains() {
  case "$2" in *"$3"*) pass "$1";; *) fail "$1 (missing: $3)";; esac
}

# assert_json <label> <json-text> <jq-filter> <want>
# Compares the value produced by `echo "$json" | python3 -c` against <want>.
assert_json() {
  local v
  v=$(printf '%s' "$2" | python3 -c "import sys,json; d=json.load(sys.stdin); print($3)" 2>/dev/null || true)
  if [ "$v" = "$4" ]; then pass "$1 ($4)"; else fail "$1 (want $4, got $v)"; fi
}

# assert_json_eq <label> <json-text> <python-expr>   (truthy/falsy)
assert_json_ok() {
  if printf '%s' "$2" | python3 -c "import sys,json; d=json.load(sys.stdin); sys.exit(0 if ($3) else 1)" 2>/dev/null; then
    pass "$1"
  else
    fail "$1"
  fi
}

# All client invocations must bypass local env proxies — they reach the
# registry via cluster DNS (not routed through mihomo).
export no_proxy='*' NO_PROXY='*'
unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY 2>/dev/null || true

curl_api() { curl -s --noproxy '*' --max-time 30 -H "Authorization: token $TOKEN" "$@"; }

# Anonymous variant for auth-matrix negative tests.
curl_anon() { curl -s --noproxy '*' --max-time 30 "$@"; }

# curl_api with a single retry on transient 5xx (useful under parallel load when
# jjlab sqlite may briefly report busy). Retries up to 2 times with 1s backoff.
curl_api_retry() {
  local attempt code
  for attempt in 1 2 3; do
    code=$(curl -s --noproxy '*' --max-time 30 -o /tmp/e2e-retry.$$ -w '%{http_code}' -H "Authorization: token $TOKEN" "$@")
    case "$code" in
      500|503) sleep 1; continue;;
      *) cat /tmp/e2e-retry.$$; rm -f /tmp/e2e-retry.$$; return 0;;
    esac
  done
  cat /tmp/e2e-retry.$$; rm -f /tmp/e2e-retry.$$
}

# Fresh scratch dir per project: dir <name>
dir() { mkdir -p "$WORK/$1" && echo "$WORK/$1"; }

summary() {
  echo ""
  echo "  ── $1: $PASS passed, $FAIL failed, $SKIP skipped"
  [ "$FAIL" -eq 0 ]
}

# have <cmd> returns 0 if the tool is installed, else prints a skip.
have() {
  command -v "$1" >/dev/null 2>&1
}
