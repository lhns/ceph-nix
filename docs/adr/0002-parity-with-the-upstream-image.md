# 2. Parity with the upstream Ceph image

Status: Accepted (2026-10)

## Context

Consumers (cephadm, Rook, ceph-csi) expect `quay.io/ceph/ceph` behaviour. Upstream's reference is
`container/Containerfile` at the image's `CEPH_SHA1` label, built from the el9 `ceph.spec.in`. A Nix build can
silently lack features (dashboard, iSCSI, NFS-Ganesha with Ceph FSAL) or helper tools.

## Decision

Parity is checked in two dimensions:

1. File trees: everything under upstream's `/usr/bin`, `/usr/sbin`, `/usr/libexec/ceph`, `/usr/share/ceph/mgr/*`
   and `/usr/lib64/ceph` exists in ours, including transitive requires such as cephadm, blkid, lsblk, udevadm,
   sgdisk, partprobe and the lvm tools.
2. Build flags: the el9 `ceph.spec.in` bconds are compared with our `cmakeFlags`.

`tests/parity.sh` enforces (1) with an allowlist. Every accepted deviation is a line in
`tests/parity-allow.txt` with its reason, so a deviation is reviewed in the diff that adds it.

## Consequences

- A new upstream release can fail parity and block publishing until the deviation is fixed or recorded here.
- Deviations are explicit and reviewable instead of discovered in production.
