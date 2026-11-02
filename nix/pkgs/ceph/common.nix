# Build deltas against nixpkgs' Ceph scope that both tracks share (ADR 0011, ADR 0002 "Accepted build deviations"):
# the allocator, rocksdb and RBD cache options of upstream's el9/el10 spec. Used as a scope overlay.
{
  lib,
  fuse3,
  pmdk,
}:
{
  # build ceph-fuse and the OSD's FuseStore against fuse3 (upstream el10); fuse 2 otherwise (el9, nixpkgs)
  withFuse3 ? false,
  # librbd's persistent write-log cache on persistent memory, with the shared libpmem/libpmemobj (upstream el9)
  withRbdRwl ? false,
}:
final: prev: {
  ceph =
    (prev.ceph.override (
      {
        # nixpkgs links jemalloc when it can; upstream builds with tcmalloc (gperftools), which
        # osd_memory_target autotuning and `ceph tell <osd> heap` rely on
        jemalloc = null;
        # upstream links Ceph's own rocksdb fork (src/rocksdb) statically, not the facebook/rocksdb of nixpkgs
        ceph-rocksdb = null;
        # the bundled rocksdb's CMake wants a static liburing (src/liburing, as upstream's spec builds it)
        liburing = null;
      }
      // lib.optionalAttrs withFuse3 { fuse = fuse3; }
    )).overrideAttrs
      (old: {
        buildInputs = old.buildInputs ++ lib.optional withRbdRwl pmdk;

        # later -D wins over nixpkgs' flags
        cmakeFlags =
          old.cmakeFlags
          ++ [
            (lib.cmakeFeature "ALLOCATOR" "tcmalloc")
            (lib.cmakeBool "WITH_SYSTEM_ROCKSDB" false)
            (lib.cmakeBool "WITH_SYSTEM_LIBURING" false)
            # the spec builds the SSD mode of the persistent write-back cache; nixpkgs leaves it off
            (lib.cmakeBool "WITH_RBD_SSD_CACHE" true)
          ]
          ++ lib.optionals withRbdRwl [
            (lib.cmakeBool "WITH_RBD_RWL" true)
            (lib.cmakeBool "WITH_SYSTEM_PMDK" true)
          ];
      });
}
