# 1. Build Ceph from source with Nix

Status: Accepted (2026-10)

## Context

Ceph Umbrella 21.2.0 (2026-10-27) moved `quay.io/ceph/ceph:v21*` to Rocky 10, which requires x86-64-v3 (AVX2) and
dies on Ivy Bridge nodes. An EL9 rebuild is not viable: CentOS Stream 9 is EOL on 2027-05-31, and shaman has no EL9
`ceph-iscsi`. nixpkgs targets x86-64-v1, so a Nix build is AVX-free by construction. nixpkgs ships Ceph 20.2.4
(Hydra-cached, `overrideScope`-able) with gaps: dashboard frontend off, no `asyncssh` in the mgr env, no
`tcmu-runner`/`ceph-iscsi`.

## Decision

Build Ceph from source with Nix. One build serves the container image and the hosts. The sibling
[ceph-csi-x86-64-v2](https://github.com/lhns/ceph-csi-x86-64-v2) deliberately does not rebuild the Ceph image; see
its [ADR 0003](https://github.com/lhns/ceph-csi-x86-64-v2/blob/main/docs/adr/0003-ceph-image-lives-in-ceph-nix.md).

## Consequences

- We own the version bump, the patches and the missing packaging (dashboard, iSCSI, asyncssh).
- Generic changes (Umbrella bump, asyncssh, dashboard) should go upstream to nixpkgs to shrink the delta.
- The build is `big-parallel` and long; see ADR 0007 for the builder.
