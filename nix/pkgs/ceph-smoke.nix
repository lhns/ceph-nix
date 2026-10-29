# Loads librados, librbd and libcephfs and builds a CephContext in each: a CPU-feature smoke test (tests/cpu.sh).
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
