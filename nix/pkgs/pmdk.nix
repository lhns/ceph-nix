# libpmem and libpmemobj for Ceph's RBD persistent write-log cache (WITH_RBD_RWL, WITH_SYSTEM_PMDK): nixpkgs has no
# pmdk. Upstream's el9 Ceph links the distribution's shared pmdk (1.12/1.13); this is the release 1.13.1 without
# libndctl (NDCTL_ENABLE=n: the RWL cache needs no namespace management, BlueStore PMEM is off), examples, benchmarks
# and docs. The libraries pick their memcpy variant (SSE2/AVX/AVX512) at run time, so the baseline CPU is fine.
{
  lib,
  stdenv,
  fetchurl,
  pkg-config,
}:
stdenv.mkDerivation rec {
  pname = "pmdk";
  version = "1.13.1";

  src = fetchurl {
    url = "https://github.com/pmem/pmdk/releases/download/${version}/pmdk-${version}.tar.gz";
    hash = "sha256-1eXt7YJc1tdC7INjUgAejLJi5CiSbnZ/VUmPFsLZd+E=";
  };

  nativeBuildInputs = [ pkg-config ];

  postPatch = ''
    patchShebangs utils
    # src/deps/miniasync (a CMake project that wants perl) is for libpmem2's async API; libpmem and libpmemobj
    # do not use it
    printf 'all:\nclean:\nclobber:\n' > src/deps/miniasync/Makefile
  '';

  # pmdk sets _FORTIFY_SOURCE itself
  hardeningDisable = [ "fortify" ];

  makeFlags = [
    "prefix=${placeholder "out"}"
    "NDCTL_ENABLE=n"
    "BUILD_EXAMPLES=n"
    "BUILD_BENCHMARKS=n"
    "DOC=n"
    "LIB_PREFIX=lib"
    "EXTRA_CFLAGS=-Wno-error"
  ];

  enableParallelBuilding = true;
  doCheck = false;

  meta = {
    description = "Persistent Memory Development Kit: libpmem and libpmemobj";
    homepage = "https://pmem.io/pmdk/";
    license = lib.licenses.bsd3;
    platforms = [ "x86_64-linux" ];
  };
}
