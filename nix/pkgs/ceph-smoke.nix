# Loads librados, librbd and libcephfs and builds a CephContext in each: a CPU-feature smoke test (tests/cpu.sh).
# Built against the same ceph.lib and stdenv as the image, so its loader and RUNPATH are in the image's closure; it is
# bind-mounted into the container by CI, not shipped in the image (ADR 0006).
{ runCommandCC, ceph }:
runCommandCC "ceph-smoke-${ceph.version}"
  {
    buildInputs = [
      ceph.dev
      ceph.lib
    ];
  }
  ''
    mkdir -p $out/libexec/ceph-nix
    $CC -O2 -D_FILE_OFFSET_BITS=64 -o $out/libexec/ceph-nix/smoke ${../../tests/smoke.c} \
      -I${ceph.dev}/include -L${ceph.lib}/lib -lrados -lrbd -lcephfs
  ''
