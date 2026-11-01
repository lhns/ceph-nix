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

3. Python environment: every distribution installed in upstream's `python3` (the mgr's), and every top-level
   module no distribution owns, is present in ours (`tests/pydists.py`, names normalized). A dependency of the mgr
   that is missing makes its modules fail silently (the dashboard's NVMe-oF client imports `grpc` inside
   `try/except ImportError`), which the module-import check cannot see. The dashboard client import is checked too.

`tests/parity.sh` enforces (1) and (3) with an allowlist. Every accepted deviation is a line in
`tests/parity-allow.txt` with its reason, so a deviation is reviewed in the diff that adds it.

Accepted deviations of (3), in `tests/parity-allow.txt` as `pydist:`/`pymod:` entries: the python bindings of dnf,
rpm and libselinux (no package manager or SELinux policy tooling in a Nix image); EL's transitive python dependencies
that nothing in Ceph imports (cloudpickle, ply, urwid, kmod, cachetools, rsa, chardet, pysocks, toml, dbus-python,
systemd-python, backports-tarfile); ceph-iscsi, which is installed without dist-info metadata.

## Consequences

- A new upstream release can fail parity and block publishing until the deviation is fixed or recorded here.
- Deviations are explicit and reviewable instead of discovered in production.
