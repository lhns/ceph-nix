# libstoragemgmt as upstream's image has it (EL9 RPM 1.10.1): lsmcli, lsmd, the C library, the python binding (`lsm`,
# which ceph-volume and cephadm use for drive LEDs and health) and the simulator plugins sim/simc. The vendor plugins
# (smispy, ontap, nstor, targetd, megaraid, hpsa, arcconf, nfs) are separate RPMs that the image does not install.
# Python-side scripts use /usr/bin/python3 like the RPM; the image puts $out/<sitePackages> on PYTHONPATH.
{
  lib,
  stdenv,
  fetchurl,
  pkg-config,
  perl,
  python3, # the Ceph scope's python: the C extension must match the image's interpreter
  libxml2,
  glib,
  sqlite,
  libconfig,
  openssl,
  systemdLibs,
  sg3_utils,
  ledmon,
}:
let
  python = python3;
in
stdenv.mkDerivation (finalAttrs: {
  pname = "libstoragemgmt";
  version = "1.10.1";

  src = fetchurl {
    url = "https://github.com/libstorage/libstoragemgmt/releases/download/${finalAttrs.version}/libstoragemgmt-${finalAttrs.version}.tar.gz";
    hash = "sha256-lL43POVekg+Dzc9qRbKpuh8/jlAtWKqCKxIeXnW85PM=";
  };

  nativeBuildInputs = [
    pkg-config
    perl
    (python.withPackages (ps: [ ps.six ]))
  ];
  buildInputs = [
    libxml2
    glib
    sqlite
    libconfig
    openssl
    systemdLibs
    sg3_utils
    ledmon
    python
  ];

  # the python binding's C extension and its sim plugin; the vendor plugins are not built
  configureFlags = [
    "--with-python3"
    "--without-test"
    "--without-smispy"
    "--without-megaraid"
    "--without-hpsa"
    "--without-arcconf"
    "--without-targetd"
    "--without-nfs"
    "--without-bash-completion"
    "--with-systemdsystemunitdir=no"
    "--with-systemd-tmpfilesdir=no"
    "--sysconfdir=/etc"
    "--localstatedir=/var"
    "--disable-static"
  ];
  # -Werror from configure.ac trips on current gcc
  postConfigure = ''
    find . -name Makefile -exec sed -i 's/-Werror//g' {} +
  '';

  # sysconfdir is /etc at build time (compiled-in lookup path); install the files into $out
  installFlags = [
    "sysconfdir=${placeholder "out"}/etc"
    "localstatedir=${placeholder "out"}/var"
    "pythondir=${placeholder "out"}/${python.sitePackages}"
    "pyexecdir=${placeholder "out"}/${python.sitePackages}"
  ];

  # the scripts must run in the image's python (the build python has no `lsm` and no six)
  postFixup = ''
    grep -rlI '^#!.*python' $out/bin $out/libexec 2>/dev/null | while read -r f; do
      sed -i '1s|^#!.*python.*|#!/usr/bin/python3|' "$f"
    done
  '';
  dontPatchShebangs = true;

  meta = {
    description = "Library and tools for managing storage arrays and local drives";
    homepage = "https://github.com/libstorage/libstoragemgmt";
    license = lib.licenses.lgpl21Plus;
    platforms = lib.platforms.linux;
  };
})
