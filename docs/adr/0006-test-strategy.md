# 6. Test strategy

Status: Accepted (2026-10)

## Context

The point of the project is "runs without AVX2", which a green build does not show. There is no local Linux; CI is
the only test environment.

## Decision

- CPU: qemu-user IvyBridge/Nehalem runs `--version`/`--help` of each entry point plus the smoke binary
  (`tests/cpu.sh`); real coverage of runtime-dispatched code comes from the VM tests. Negative control: upstream's
  image fails on IvyBridge and passes on Haswell.
- Parity: per ADR 0002.
- Functional: cephadm and ceph-csi's Rook e2e on GitHub Ubuntu runners from the image artifact.
- NixOS VM tests on hosted runners (ADR 0010) with AVX2 masked, first asserting the guest has no `avx2`.

## Consequences

- Negative controls keep the tests honest, at the cost of pulling the upstream image.
- Heavy functional tests run on throwaway GitHub runners, VM tests likewise.

## Amendment (2026-11)

The Trivy scan of each image is no longer report-only. The full HIGH and CRITICAL report is still printed, then a
second run fails the job on any CRITICAL finding that has a fix (`--severity CRITICAL --ignore-unfixed`, exit code 1).
HIGH findings and unfixed ones stay informational. Exceptions go in `.trivyignore`, one ID per line with a reason in the
comment above it; an entry is removed once its cause is gone. The first one is certifi's GHSA-6q48-6c7w-9gw2: nixpkgs
replaces the bundle the advisory is about with its cacert package. `release.yml` additionally requires a successful
`vm-tests` run for the release commit, so the VM tests that back the "runs without AVX2" claim gate publishing too.

The Trivy scan sees language packages (Python, Go, Rust) but not the Nix-built native libraries: the image has no OS
package database. The Trivy image is pinned by digest in `ceph-track.yml`.

The smoke binary is no longer in the image. `ceph-track.yml` builds `ceph-smoke-<track>` after the image (Ceph is already
restored, so nothing compiles) and uploads it as the `smoke-<track>` artifact; the `cpu` job bind-mounts it read-only
into the container under test, which `tests/cpu.sh` takes as an optional fourth argument. It is built against the same
`ceph.lib` and stdenv as the image, so its loader and RUNPATH are in the image's closure. Production images carry only
what users run.
