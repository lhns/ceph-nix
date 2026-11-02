# 11. Both Ceph tracks are our builds, with shared overrides

Status: Accepted (2026-11)

Supersedes ADR 0010.

## Context

The linkage check (ADR 0002) showed build-level gaps against upstream's el9/el10 spec that nixpkgs' Ceph recipe has by
design: it links jemalloc where upstream builds tcmalloc, uses facebook/rocksdb where upstream statically links Ceph's
fork, builds no RBD persistent cache, and Umbrella uses fuse 2 where el10 uses fuse3. Closing them changes the Ceph
derivation, so Tentacle can no longer be a cache.nixos.org hit.

## Decision

- Both tracks are nixpkgs' Ceph scope with overrides (`nix/pkgs/ceph`): `common.nix` holds what both share, and
  `default.nix` adds the Umbrella source bump and its fixes.
  - `jemalloc = null` and `-DALLOCATOR=tcmalloc`: gperftools, as upstream. `osd_memory_target` autotuning and
    `ceph tell osd.N heap` need it.
  - `WITH_SYSTEM_ROCKSDB=false`: the `src/rocksdb` submodule from the release tarball (Ceph's fork, built offline by
    Ceph's own ExternalProject) replaces nixpkgs' rocksdb. Its CMake needs the bundled static liburing, so
    `WITH_SYSTEM_LIBURING=false` as well (upstream builds it so too).
  - Umbrella builds against fuse3 (`fuse = fuse3`), Tentacle stays on fuse 2, as upstream.
  - `WITH_RBD_SSD_CACHE=true` on both (the spec sets it; nixpkgs never did). Tentacle also sets `WITH_RBD_RWL` with a
    shared libpmem/libpmemobj (`nix/pkgs/pmdk.nix`, pmdk is not in nixpkgs), as upstream's el9 does. Umbrella's spec
    has no system pmdk, so Umbrella stays as is.
- Every job that needs a Ceph build uses the composite action `.github/actions/ceph-build` with `track`, which is
  ADR 0010's cache mechanism keyed `ceph-<track>-<drv hash>`: restore the paths cache.nixos.org does not serve,
  otherwise build and save them. `ceph.yml`, `release.yml` and `vm-tests.yml` use it for both tracks.

## Consequences

- A change to either Ceph derivation (nixpkgs bump, override) costs one cold build of about 2 h per track. The
  deltas live in one place and apply to both tracks.
- The Tentacle image is no longer reproducible from cache.nixos.org alone; the rest of ADR 0010 (no self-hosted
  builder, 7-day eviction, branch-scoped caches, unsigned imports) is unchanged.
- The bundled rocksdb and liburing are compiled in, so the Ceph binaries no longer link shared rocksdb, jemalloc or
  liburing; the allowlist entries for tcmalloc, libfuse3 and libpmem* are gone.
- The wrong claim in ADR 0002 that the RBD SSD cache was available is corrected.
