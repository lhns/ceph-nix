# 8. Companion daemons pinned to upstream's versions

Status: Accepted (2026-10)

## Context

The image ships daemons that are not part of Ceph: NFS-Ganesha, tcmu-runner, ceph-iscsi, libstoragemgmt. nixpkgs has
newer releases of some of them (Ganesha 9.x; upstream's v20.2.4 image ships 5.9). Users migrate an existing cephadm
cluster from upstream's image to ours in place. With Ganesha 9 the NFS export stayed in grace forever after
`ceph orch upgrade`: a different major changes the rados_cluster recovery state it reads and writes.

## Decision

Each companion is packaged at the exact version upstream's `quay.io/ceph/ceph` image ships for that Ceph release
(`rpm -q` in that image), in `nix/pkgs/`. Bumping a Ceph release re-checks these versions.

## Consequences

- Swapping the image changes the build, not the daemon behaviour; `tests/upgrade.sh` covers the migration.
- Ganesha differs per track: 5.9 for Tentacle 20.2.4, 9.16 (`nfs-ganesha-9.16-3`) for Umbrella 21.2.0. tcmu-runner,
  ceph-iscsi (3.9) and libstoragemgmt (1.10.1) are the same in both upstream images.
- We own the old-version packaging (patches against current toolchains) instead of nixpkgs.
