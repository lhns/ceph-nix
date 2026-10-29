# cas_cache.ko for one kernel; instantiated through the linuxPackages extension in the overlay.
{
  lib,
  stdenv,
  kernel,
  kernelModuleMakeFlags,
  kmod,
  python3,
  util-linux,
  procps,
  which,
  gawk,
  src,
}:
let
  common = import ./common.nix;
  # v26.03.3 added Linux 7.0 support (commit "Add support for kernel 7.0 and Ubuntu 26.04").
  # The lower bound is the oldest kernel nixpkgs ships; configure.d probes older APIs but
  # nothing below 6.6 is tested here.
  supported = lib.versionAtLeast kernel.version "5.10" && lib.versionOlder kernel.version "7.1";
in
stdenv.mkDerivation {
  pname = "open-cas-kmod";
  version = "${common.version}-${kernel.version}";
  inherit src;

  hardeningDisable = [
    "pic"
    "format"
  ];

  nativeBuildInputs = [
    kmod
    python3
    util-linux
    procps
    which
    gawk
  ]
  ++ kernel.moduleBuildDependencies;

  postPatch = ''
    ${common.prepareVersion}
    patchShebangs configure configure.d tools
  '';

  # configure compiles ~70 probe modules against the kernel and writes modules/generated_defines.h.
  configurePhase = ''
    runHook preConfigure
    export KERNEL_DIR=${kernel.dev}/lib/modules/${kernel.modDirVersion}/build
    ./configure
    runHook postConfigure
  '';

  enableParallelBuilding = true;

  makeFlags = kernelModuleMakeFlags ++ [
    "KERNEL_DIR=${kernel.dev}/lib/modules/${kernel.modDirVersion}/build"
    "KERNEL_VERSION=${kernel.modDirVersion}"
  ];

  preBuild = "cd modules";
  postBuild = "cd ..";

  installPhase = ''
    runHook preInstall
    install -Dm644 modules/cas_cache/cas_cache.ko \
      $out/lib/modules/${kernel.modDirVersion}/extra/cas_cache.ko
    runHook postInstall
  '';

  meta = {
    description = "Open CAS kernel module (cas_cache) for Linux ${kernel.version}";
    homepage = "https://github.com/lhns/open-cas-linux";
    license = lib.licenses.bsd3;
    platforms = [ "x86_64-linux" ];
    broken = !supported;
  };
}
