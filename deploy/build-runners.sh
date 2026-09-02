#!/usr/bin/env bash
# Build + push the per-CLI runner images via the shared buildkitd.
#
# Each runner image is `artifact.temp.svc.cluster.local/jjlab-e2e/runner-<cli>:<tag>`
# and installs exactly one protocol's client toolchain on top of a base image
# pulled through the internal registry (see deploy/runners/runner.Dockerfile).
#
# Usage:  ./build-runners.sh [cli ...]     (defaults to ALL)
# Env:    TAG=dev  REGISTRY=artifact.temp.svc.cluster.local:80
set -euo pipefail

CDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$CDIR/.." && pwd)"
REGISTRY="${REGISTRY:-jj-lab.temp.svc.cluster.local}"
TAG="${TAG:-dev}"
BUILDKIT="${BUILDKIT_ADDR:-tcp://buildkitd.temp.svc.cluster.local:1234}"
PROXY="${PROXY:-http://mihomo.develop.svc.cluster.local:7890}"

# cli -> (base image, apk packages, pip packages)
# Base images are resolved through the internal registry, NOT docker.io.
declare -A BASE=(
  [npm]="jj-lab.temp.svc.cluster.local/library/node:22-alpine3.24"
  [pypi]="jj-lab.temp.svc.cluster.local/library/python:3.12-alpine3.24"
  [cargo]="jj-lab.temp.svc.cluster.local/library/rust:1-alpine3.24"
  [go]="jj-lab.temp.svc.cluster.local/library/golang:1.26-alpine3.24"
  [generic]="jj-lab.temp.svc.cluster.local/library/alpine:3.24"
  [composer]="jj-lab.temp.svc.cluster.local/library/php:8-alpine3.24"
  [rubygems]="jj-lab.temp.svc.cluster.local/library/ruby:3-alpine3.24"
  [hex]="jj-lab.temp.svc.cluster.local/library/elixir:1.18-alpine"
  [conan]="jj-lab.temp.svc.cluster.local/library/python:3.12-alpine3.24"
  [pub]="jj-lab.temp.svc.cluster.local/library/dart:3"
  [nuget]="jj-lab.temp.svc.cluster.local/mcr.microsoft.com/dotnet/sdk:10.0"
  [maven]="jj-lab.temp.svc.cluster.local/library/gradle:8-jdk17-alpine"
  [helm]="jj-lab.temp.svc.cluster.local/library/alpine:3.24"
  [oci]="jj-lab.temp.svc.cluster.local/library/alpine:3.24"
  [auth]="jj-lab.temp.svc.cluster.local/library/alpine:3.24"
  [swift]="jj-lab.temp.svc.cluster.local/library/swift:latest"
  [net-preflight]="jj-lab.temp.svc.cluster.local/library/alpine:3.24"
  [system]="jj-lab.temp.svc.cluster.local/library/alpine:3.24"
)
declare -A APK_PKGS=(
  [composer]="composer"
  [helm]="helm"
  [conan]="build-base cmake ninja"
  [oci]="skopeo"
  [auth]="skopeo"
)
declare -A PIP_PKGS=(
  [pypi]="uv"
  [conan]="conan"
)
declare -A SETUP_CMD=(
  [hex]="mix local.hex --force && mix local.rebar --force"
)

build_one() {
  local cli="$1" base="${2}" apk="${APK_PKGS[$cli]:-}" pip="${PIP_PKGS[$cli]:-}" setup="${SETUP_CMD[$cli]:-}"
  local dest="${REGISTRY}/jjlab-e2e/runner-${cli}:${TAG}"
  echo "═══ runner-${cli}  (${base}) -> ${dest} ═══"
  buildctl --addr "${BUILDKIT}" build \
    --frontend dockerfile.v0 \
    --local "context=${ROOT}" \
    --local "dockerfile=${CDIR}/runners" \
    --opt "filename=runner.Dockerfile" \
    --opt "build-arg:BASE=${base}" \
    --opt "build-arg:APK_PKGS=${apk}" \
    --opt "build-arg:PIP_PKGS=${pip}" \
    --opt "build-arg:SETUP_CMD=${setup}" \
    --opt "build-arg:HTTP_PROXY=${PROXY}" \
    --opt "build-arg:HTTPS_PROXY=${PROXY}" \
    --opt "build-arg:NO_PROXY=localhost,127.0.0.1,.svc.cluster.local,.svc,.nip.io,archive.ubuntu.com,security.ubuntu.com,ports.ubuntu.com,deb.debian.org" \
    --output "type=image,name=${dest},push=true" \
    --progress plain
}

if [ $# -gt 0 ]; then
  for cli in "$@"; do
    build_one "$cli" "${BASE[$cli]:?unknown cli: $cli}"
  done
else
  for cli in "${!BASE[@]}"; do
    build_one "$cli" "${BASE[$cli]}"
  done
fi
echo "done."