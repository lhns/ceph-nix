# 2. Parity with the upstream Ceph image

Status: Accepted (2026-10)

## Context

Consumers (cephadm, Rook, ceph-csi) expect `quay.io/ceph/ceph` behaviour. Upstream's reference is
`container/Containerfile` at the image's `CEPH_SHA1` label, built from the el9 (Tentacle) or el10 (Umbrella)
`ceph.spec.in`. A Nix build can silently lack features (dashboard, iSCSI, NFS-Ganesha with Ceph FSAL) or helper tools.

## Decision

Parity is checked in four dimensions:

1. File trees: everything under upstream's `/usr/bin`, `/usr/sbin`, `/usr/libexec/ceph`, `/usr/share/ceph/mgr/*`,
   `/usr/lib64/{ceph,rados-classes,ganesha,tcmu-runner}` and the Ceph libraries
   `/usr/lib64/lib{rados,rbd,cephfs,rgw,radosstriper,cephsqlite}.so*` exists in ours, including transitive requires
   such as cephadm, blkid, lsblk, udevadm, sgdisk, partprobe and the lvm tools.
2. Build flags: the el9/el10 `ceph.spec.in` bconds are compared with our `cmakeFlags` (audited once, see "Accepted
   build deviations"; repeat the audit when a release changes the spec's bconds).
3. Python environment: every distribution installed in upstream's `python3` (the mgr's), and every top-level
   module no distribution owns, is present in ours (`tests/pydists.py`, names normalized). A dependency of the mgr
   that is missing makes its modules fail silently (the dashboard's NVMe-oF client imports `grpc` inside
   `try/except ImportError`), which the module-import check cannot see. The dashboard client import is checked too.
4. Linkage: the `DT_NEEDED` sonames (versions dropped) of ceph-osd, -mon, -mgr, -mds, radosgw, rbd-mirror, ceph-fuse,
   rbd-nbd and of librados, librbd, libcephfs, librgw, libcephsqlite, libradosstriper and libceph-common
   (`tests/elfneeded.py`, run with each image's own python3). A soname upstream links directly and ours does not reach
   at all is a gap; one ours reaches through a shared library (zlib, lz4 and snappy through shared boost) is only
   reported. Sonames only ours links (shared boost) are reported.

`tests/parity.sh` enforces (1), (3) and (4) with an allowlist. Every accepted deviation is a line in
`tests/parity-allow.txt` with its reason, so a deviation is reviewed in the diff that adds it.

Accepted deviations of (3), in `tests/parity-allow.txt` as `pydist:`/`pymod:` entries: the python bindings of dnf,
rpm and libselinux (no package manager or SELinux policy tooling in a Nix image); EL's transitive python dependencies
that nothing in Ceph imports (cloudpickle, ply, urwid, kmod, cachetools, rsa, chardet, pysocks, toml, dbus-python,
systemd-python, backports-tarfile); ceph-iscsi, which is installed without dist-info metadata.

Accepted deviations of (4), as `so:<binary>:<soname>` entries: on Tentacle libthrift and libcurl (Jaeger).

### Accepted build deviations

Audit of 2026-11: `ceph.spec.in` at each image's `CEPH_SHA1` (Tentacle v20.2.4 `7f793731`, el9; Umbrella v21.2.0
`b060042d`, el10) against nixpkgs' `pkgs/by-name/ce/ceph/ceph.nix` at the `flake.lock` revision and
`nix/pkgs/ceph/default.nix`.

- Allocator: upstream builds with tcmalloc (gperftools), nixpkgs picks jemalloc. Fixed (ADR 0011): `jemalloc = null`,
  `-DALLOCATOR=tcmalloc`; tests/cephadm.sh checks `ceph tell osd.0 heap stats` and the memory autotuning.
- `WITH_SYSTEM_{BOOST,ZSTD,GTEST}=true`: upstream's spec leaves them off and bundles Ceph's pinned copies (statically
  linked), nixpkgs uses shared system ones (boost 1.87, ...). Accepted: same functionality, shown only as
  direct-vs-transitive sonames. `WITH_SYSTEM_ARROW` and `WITH_SYSTEM_UTF8PROC` are on in the spec too.
- rocksdb and liburing: upstream links Ceph's fork `ceph/rocksdb` (submodule `src/rocksdb`, 7.9.2 plus Ceph's patches)
  and Ceph's liburing statically. Fixed (ADR 0011): `WITH_SYSTEM_ROCKSDB=false` and `WITH_SYSTEM_LIBURING=false`
  (the bundled rocksdb's CMake needs the static liburing); BlueStore runs the same rocksdb code as upstream.
- `WITH_JAEGER=false`: the el9 spec builds Jaeger tracing (libthrift, libcurl linked); Umbrella's spec forces it off
  (crimson), so only Tentacle differs. Tracing export is off by default (`jaeger_tracing_enable`); nixpkgs cannot
  build the bundled opentelemetry-cpp. Accepted, allowlisted `[el9]`.
- RBD persistent write-back cache: nixpkgs sets neither `WITH_RBD_SSD_CACHE` nor `WITH_RBD_RWL` (both default OFF),
  so neither cache mode was available, not only the one needing persistent memory. Fixed (ADR 0011): the SSD mode on
  both tracks; the RWL mode on Tentacle, where upstream's el9 rbd-mirror links the distribution's shared libpmem and
  libpmemobj, with `nix/pkgs/pmdk.nix` (pmdk is not in nixpkgs). Umbrella's spec has no system pmdk and no such link,
  so it keeps the SSD mode only.
- fuse: Tentacle's spec uses fuse 2 like nixpkgs; Umbrella's spec uses fuse3 (`pkgconfig(fuse3)`). Fixed (ADR 0011):
  Umbrella is built with `fuse = fuse3`.
  Tentacle 20.2.5's spec moved to fuse3 too (`rpm -q`, `ldd` in upstream's image), so both tracks use it. That is the
  only build change in `ceph.spec.in` from 20.2.4 to 20.2.5, besides the new `rgw-policy-test` tool.
- `WITH_TESTS=false`, `WITH_CATCH2=false` (Umbrella clones Catch2 at configure time): the spec builds the tests into
  the separate ceph-test package, which the image does not install. Accepted.
- `WITH_UADK=false`: aarch64 only. `WITH_MGR_DASHBOARD_FRONTEND=false`: the spec passes OFF too; the prebuilt frontend
  ships in the release tarball and the file-tree parity confirms it. Accepted.
- `WITH_CRIMSON`: on in the Umbrella spec, off in Tentacle's; ours is never built with it (`ceph-osd-crimson`,
  `crimson-objectstore-tool` are allowlisted). Accepted: tech preview, not the default OSD flavor.
- `CEPHADM_BUNDLED_DEPENDENCIES`: `pip` upstream, `none` in nixpkgs; `nix/pkgs/cephadm.nix` bundles the pure-python
  dependencies itself.
- Not set by nixpkgs, with no effect on the compared file trees or linkage: `WITH_OCF` (Pacemaker resource agents),
  `WITH_SELINUX`, `WITH_SYSTEM_QATLIB/QATZIP`, `WITH_GRAFANA` (dashboards under `/etc/grafana`, not in the compared
  paths), `WITH_PYPKG` (el10 wheels), `WITH_FMT_HEADER_ONLY` (build-time). Not audited further.
- lttng, babeltrace, the RGW AMQP (rabbitmq-c) and Kafka (rdkafka) endpoints, numa and libradosstriper: no linkage gap.
  Ours additionally links liboath in librgw and radosgw (info only).

## Consequences

- A new upstream release can fail parity and block publishing until the deviation is fixed or recorded here.
- Deviations are explicit and reviewable instead of discovered in production.
