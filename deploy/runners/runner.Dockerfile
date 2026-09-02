# syntax=docker/dockerfile:1
# Generic per-CLI runner image for the jjlab registry e2e suites.
#
# One image per protocol CLI, so each container tests a single client against
# the deployed jjlab service. Built via the shared buildkitd and pushed to the
# internal artifact registry (jj-lab.temp.svc.cluster.local), no public net.
#
#   buildctl --addr tcp://buildkitd.temp.svc.cluster.local:1234 build \
#     --frontend dockerfile.v0 \
#     --local context=<repo-root> \
#     --local dockerfile=<repo-root>/deploy/runners \
#     --opt build-arg:BASE=jj-lab.temp.svc.cluster.local/library/alpine:3.24 \
#     --opt build-arg:APK_PKGS=helm \
#     --output type=image,name=jj-lab.temp.svc.cluster.local/jjlab-e2e/runner-helm:<tag>,push=true

ARG BASE
FROM ${BASE}

# Proxied egress during build (apt/apk/pip/mix all need it). The `NO_PROXY`
# from the build args keeps cluster-internal names direct.
ARG HTTP_PROXY ARG HTTPS_PROXY ARG NO_PROXY
ENV HTTP_PROXY=${HTTP_PROXY} HTTPS_PROXY=${HTTPS_PROXY} NO_PROXY=${NO_PROXY}

# Point every OS package manager at Aliyun mirrors (faster + stable in-cluster):
#   - Alpine  -> apk  -> mirrors.aliyun.com/alpine
#   - Debian  -> apt  -> mirrors.aliyun.com/debian (+ -security)
#   - Ubuntu  -> apt  -> mirrors.aliyun.com/ubuntu
# Then top up the common harness tooling (bash, curl, python3, tar, zip, git,
# ca-certs) + any per-suite extras (ARG APK_PKGS / APT_PKGS).
ARG APK_PKGS=""
ARG APT_PKGS=""
RUN set -eu; \
    if [ -f /etc/alpine-release ]; then \
      sed -i 's|dl-cdn.alpinelinux.org|mirrors.aliyun.com|g' /etc/apk/repositories; \
      apk add --no-cache bash curl python3 tar zip git ca-certificates ${APK_PKGS}; \
    else \
      . /etc/os-release 2>/dev/null || true; \
      rm -f /etc/apt/sources.list /etc/apt/sources.list.d/*; \
      if [ "${ID:-}" = "ubuntu" ]; then \
        printf '%s\n' \
          "deb https://mirrors.aliyun.com/ubuntu/ ${VERSION_CODENAME} main restricted universe multiverse" \
          "deb https://mirrors.aliyun.com/ubuntu/ ${VERSION_CODENAME}-updates main restricted universe multiverse" \
          "deb https://mirrors.aliyun.com/ubuntu/ ${VERSION_CODENAME}-security main restricted universe multiverse" \
          "deb https://mirrors.aliyun.com/ubuntu/ ${VERSION_CODENAME}-backports main restricted universe multiverse" \
          > /etc/apt/sources.list; \
      else \
        printf '%s\n' \
          "deb https://mirrors.aliyun.com/debian/ ${VERSION_CODENAME} main contrib non-free" \
          "deb https://mirrors.aliyun.com/debian/ ${VERSION_CODENAME}-updates main contrib non-free" \
          "deb https://mirrors.aliyun.com/debian-security/ ${VERSION_CODENAME}-security main contrib non-free" \
          > /etc/apt/sources.list; \
      fi; \
      apt-get update -o Acquire::http::Timeout=60 -o Acquire::https::Timeout=60; \
      DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        bash curl python3 tar zip git ca-certificates ${APT_PKGS}; \
      rm -rf /var/lib/apt/lists/*; \
    fi

# Trust the internal nip.io CA so https-ingress targets (swift, nuget) resolve.
COPY deploy/nipio-ca.crt /usr/local/share/ca-certificates/nipio-ca.crt
RUN if [ -f /etc/alpine-release ]; then \
      cp /usr/local/share/ca-certificates/nipio-ca.crt /usr/local/share/ca-certificates/nipio-ca.pem; \
      update-ca-certificates 2>/dev/null || true; \
    else \
      cp /usr/local/share/ca-certificates/nipio-ca.crt /usr/local/share/ca-certificates/nipio-ca.pem; \
      update-ca-certificates 2>/dev/null || true; \
    fi

# Optional pip tools (e.g. `uv` for pypi, `conan` for conan). Python is not
# guaranteed on every base, so keep it guarded. Uses the Aliyun PyPI mirror.
ARG PIP_PKGS=""
RUN if command -v python3 >/dev/null 2>&1 && [ -n "${PIP_PKGS}" ]; then \
      python3 -m pip install --no-cache-dir --break-system-packages \
        -i https://mirrors.aliyun.com/pypi/simple/ ${PIP_PKGS} || true; \
    fi

# Optional per-cli one-shot setup (e.g. `mix local.hex --force`).
ARG SETUP_CMD=""
RUN if [ -n "${SETUP_CMD}" ]; then sh -c "${SETUP_CMD}" || true; fi

COPY . /e2e
COPY deploy/runner-entrypoint.sh /usr/local/bin/runner
RUN chmod +x /usr/local/bin/runner

ENV NO_PROXY=* no_proxy=*
ENTRYPOINT ["/usr/local/bin/runner"]