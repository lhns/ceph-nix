# 3. Release each built image once, only when it changed

Status: Accepted (2026-10)

## Context

The image is published as `ghcr.io/lhns/ceph-nix:v<ver>-<n>`. `dockerTools` output is reproducible, so unchanged
inputs yield an unchanged digest. Consumers pin digests and must not see tags move.

## Decision

A release tag `v<ver>-<n>` is pushed only when the built digest differs from the newest `v<ver>-*` release. Tags
are never overwritten. Each GitHub release records the image digest and the `flake.lock` revisions.

## Consequences

- Scheduled bumps are cheap: no change in digest, no release.
- A rebuild with a new nixpkgs (e.g. a security fix) gets the next `<n>`.
- The Tentacle dev image (cached 20.2.4) is not published as a release.
