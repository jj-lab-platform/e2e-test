# jjlab-e2e

Dedicated end-to-end test suite for the **jj-lab** package registry, kept in its
own repository on purpose. It drives the **real deployed jjlab service** over
cluster DNS (not a local devserver), exercising the in-process pkglab registry
surface (`OCI /v2` + `/pkgs/<fmt>`) plus jjlab's token-auth model through the
official client of every protocol.

> This repo is the source of truth for jjlab e2e. jj-lab code lives elsewhere
> and must **never** be modified from here — bugs are reported back to the
> jj-lab maintainers.

## Protocol coverage

16 protocols, each run through the A/B/C/D/E/F lifecycle:

| phase | what it proves |
| --- | --- |
| A `a-pull`      | official client pulls a PUBLIC package through pull-through |
| B `b-push`      | official client publishes a self-made package |
| C `c-consume`   | a fresh project consumes the package pushed in B |
| D `d-mutate`    | deprecate / yank / retire / unlist / delete (or immutable 405) |
| E `e-upgrade`   | publish a new version; assert latest/index move semantically |
| F `f-republish` | same-version overwrite + delete-republish + name normalisation |

Suites (17): `net-preflight`, `npm`, `pypi`, `cargo`, `go`, `maven`, `composer`,
`nuget`, `rubygems`, `hex`, `pub`, `swift`, `conan`, `helm`, `generic`, `oci`,
`auth`.

## Target & auth

- Registry base defaults to `http://jj-lab.temp.svc.cluster.local`
  (override with `BASE`, e.g. the https ingress).
- Token auth: `WRITE_TOKEN` (default `devtoken`) = the write token from
  `JJLAB_TOKENS`. Anonymous is read-only; the `auth` suite asserts the
  negative paths across protocols.

## Run

Two modes:

### 1. In-process (one container per CLI, rotating a throwaway jjlab)

```sh
# build the per-CLI runner images (aliyun mirrors), then run
./deploy/build-runners.sh
./deploy/run-k8s.sh            # default: npm cargo go, fresh jjlab per suite

# one throwaway jjlab shared by all suites, then torn down
./deploy/run-k8s.sh --once      # runs every suite

# specific suites, pinned jjlab image tag
JJLAB_TAG=v0.2.0 ./deploy/run-k8s.sh --once npm pypi swift
```

`run-k8s.sh` helm-installs a unique `jjlab-e2e` release (from jj-lab's own
chart, renamed so it never collides with the real `jj-lab` deploy), runs each
suite in its own runner container against it, captures each pod's stdout as the
artifact, and uninstalls it — see `artifacts/k8s/<run-id>/`.

Runner images are built via the shared buildkitd and pushed to the internal
registry as `jjlab-e2e/runner-<cli>:<tag>`. Every OS package manager is
rewired to **Aliyun mirrors** (`mirrors.aliyun.com`: apk, apt/debian, ubuntu,
pip) inside the Dockerfile.

### 2. Direct on host (all suites in one process)

```sh
./run-all.sh
./run-all.sh npm cargo oci
BASE=https://jj-lab.temp.10.199.64.20.nip.io WRITE_TOKEN=devtoken ./run-all.sh
```

Every client invocation bypasses the local proxy (`no_proxy='*'`) and reaches
the registry via cluster DNS.

## Artifacts

After a run, `run-all.sh` tars the whole working dir (per-suite logs, result
counts, upstream reachability flags, and any package files the clients built)
into `artifacts/jjlab-e2e-<run-id>.tar.gz` plus a `artifacts/summary.txt`.

- Set `NO_ARTIFACTS=1` to skip collection.
- Set `ARTIFACTS_DIR=/some/path` to relocate the output dir.

These are the raw evidence of what the real CLIs produced/pushed — useful for
repro and for attaching to bug reports against jj-lab. `artifacts/` is
git-ignored; CI uploads it as a workflow artifact instead.

## CI

`.forgejo/workflows/e2e.yml` runs the suite on push/PR and uploads
`artifacts/` as a Forgejo Actions artifact. It needs a registered
`forgejo-runner` (none is registered in this cluster yet).
