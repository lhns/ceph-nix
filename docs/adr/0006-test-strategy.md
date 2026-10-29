# 6. Test strategy

Status: Accepted (2026-10)

## Context

The point of the project is "runs without AVX2", which a green build does not show. There is no local Linux; CI is
the only test environment.

## Decision

- CPU: qemu-user IvyBridge/Nehalem runs every binary. Negative control: upstream's image fails on IvyBridge and
  passes on Haswell.
- Parity: per ADR 0002.
- Functional: cephadm and ceph-csi's Rook e2e on GitHub Ubuntu runners from the image artifact.
- NixOS VM tests on the builder with AVX2 masked, first asserting the guest has no `avx2`.

## Consequences

- Negative controls keep the tests honest, at the cost of pulling the upstream image.
- Heavy functional tests run on throwaway GitHub runners, VM tests only on the builder (ADR 0007).
