# AGENTS.md — standing rules for jjlab-e2e work

## Purpose
This repo is the **standalone end-to-end test harness for the jj-lab package
registry**. It drives the real deployed jjlab service over cluster DNS
(`http://jj-lab.temp.svc.cluster.local`) through the official clients of all 16
protocols, and collects artifacts (per-suite logs, result counts, client-built
package files) under `artifacts/`.

## Hard rules (do not violate)
1. **Never commit to jj-lab.** Do not `git commit`, `git push`, or edit source
   files under `/home/user/jj-lab` (or any `jj-lab*` source repo). jj-lab is
   maintained separately by its owner.
2. **Never modify jj-lab code to fix a bug.** The e2e suite only *observes* the
   deployed service. When a test fails and the root cause is in jj-lab
   (`crates/…`, `frontend/…`, `deploy/…`), **do not patch it here**. Instead,
   **report the bug** to the user with:
   - failing suite + phase (e.g. `cargo/b-push`)
   - the exact client command, expected vs actual
   - the jj-lab file/function implicated (if traceable from the error)
   - the artifact path holding the raw evidence
3. **Artifacts are the deliverable.** Always let `run-all.sh` collect
   `artifacts/` (unless `NO_ARTIFACTS=1`). Point to the tarball/summary when
   reporting. `artifacts/` is git-ignored; never commit it.

## Working layout
- `/home/user/jj-lab-e2e` — this repo (clone of `jj-lab/jjlab-e2e` on Forgejo).
- `/home/user/jj-lab` — jj-lab source (read-only for us; **hands off**).

## Test target & auth
- `BASE` (default `http://jj-lab.temp.svc.cluster.local`) — https ingress:
  `https://jj-lab.temp.10.199.64.20.nip.io`.
- `WRITE_TOKEN` (default `devtoken`) is the single write token from
  `JJLAB_TOKENS`; anonymous is read-only.

## Run
- `./run-all.sh` (or `./run-all.sh <suite…>`), `NO_ARTIFACTS=1` to skip collect.
