# NFS-Ganesha pinned to the release upstream's quay.io/ceph/ceph image ships for this Ceph release (ADR 0008:
# 5.9 for Tentacle 20.2.4), not nixpkgs' 9.x. A different Ganesha major changes the rados_cluster recovery
# behaviour: after `ceph orch upgrade` the export stayed in grace forever (tests/upgrade.sh).
# Same FSALs and options as upstream's RPM: FSAL_CEPH, FSAL_RGW, RADOS_RECOV, RADOS_URLS.
{ pkgs, ceph }:
let
  inherit (pkgs) lib;
  nixpkgsGanesha = pkgs.nfs-ganesha;
in
pkgs.stdenv.mkDerivation (finalAttrs: {
  pname = "nfs-ganesha";
  version = "5.9";

  outputs = [
    "out"
    "man"
    "tools"
  ];

  src = pkgs.fetchFromGitHub {
    owner = "nfs-ganesha";
    repo = "nfs-ganesha";
    tag = "V${finalAttrs.version}";
    fetchSubmodules = true; # the bundled nTIRPC of this release; nixpkgs' is for 9.x
    hash = "sha256-cqX69vc9wPklguqXMnp75zai6vtBrl6IgfwFbNHaKBA=";
  };

  # 5.9's CMakeLists has the same dbus block as 9.x (offset only)
  patches = [ "${pkgs.path}/pkgs/by-name/nf/nfs-ganesha/allow-bypassing-dbus-pkg-config-test.patch" ];

  preConfigure = "cd src";

  env.NIX_CFLAGS_COMPILE = toString [
    "-Wno-redundant-move"
    "-Wno-error"
    "-std=gnu17"
    "-Wno-incompatible-pointer-types"
    "-Wno-int-conversion"
    "-Wno-implicit-function-declaration"
  ];

  cmakeFlags = [
    "-DCMAKE_POLICY_VERSION_MINIMUM=3.5"
    "-DUSE_SYSTEM_NTIRPC=OFF"
    "-DSYSSTATEDIR=/var"
    "-DENABLE_VFS_POSIX_ACL=ON"
    "-DUSE_ACL_MAPPING=ON"
    "-DCMAKE_BUILD_WITH_INSTALL_RPATH=ON"
    "-DUSE_MAN_PAGE=ON"
    "-DUSE_RADOS_RECOV=ON"
    "-DRADOS_URLS=ON"
    "-DUSE_FSAL_CEPH=ON"
    "-DUSE_FSAL_RGW=ON"
    "-DUSE_DBUS=ON"
    "-DDBUS_NO_PKGCONFIG=ON"
    "-DDBUS_LIBRARY_DIRS=${lib.getLib pkgs.dbus}/lib"
    "-DDBUS_INCLUDE_DIRS=${lib.getDev pkgs.dbus}/include/dbus-1.0\;${lib.getLib pkgs.dbus}/lib/dbus-1.0/include"
    "-DDBUS_LIBRARIES=dbus-1"
  ];

  nativeBuildInputs = with pkgs; [
    cmake
    pkg-config
    bison
    flex
    sphinx
    dbus
  ];

  buildInputs = with pkgs; [
    acl
    krb5
    xfsprogs
    btrfs-progs
    jemalloc
    dbus.lib
    libcap
    liburcu
    nfs-utils
    util-linux.dev
    libnsl
    ceph
  ];

  postPatch = ''
    substituteInPlace src/tools/mount.9P --replace-fail "/bin/mount" "/usr/bin/env mount"
    # the default config path must be /etc/ganesha/ganesha.conf (Rook mounts it there), not the store's etc
    sed -i 's|GANESHA_CONFIG_PATH "@SYSCONFDIR@/ganesha/ganesha.conf"|GANESHA_CONFIG_PATH "/etc/ganesha/ganesha.conf"|' src/include/config-h.in.cmake
    grep -q 'GANESHA_CONFIG_PATH "/etc/ganesha/ganesha.conf"' src/include/config-h.in.cmake
  '';

  postFixup = ''
    # the bundled nTIRPC and ganesha's own libraries live in $out/lib: every binary and module finds them there
    for f in $out/bin/* $(find $out/lib -name '*.so*' -type f); do
      patchelf --add-rpath $out/lib "$f" 2>/dev/null || true
    done
  '';

  postInstall = ''
    # the bundled nTIRPC installs to lib64; keep one library dir, and drop its .pc (broken paths, unused)
    if [ -d $out/lib64 ]; then
      mkdir -p $out/lib
      cp -a $out/lib64/. $out/lib/
      rm -rf $out/lib64
    fi
    rm -rf $out/lib/pkgconfig
    install -Dm755 ../tools/mount.9P $tools/bin/mount.9P
    # policy for the D-Bus statistics interface
    install -Dm644 $src/src/scripts/ganeshactl/org.ganesha.nfsd.conf $out/etc/dbus-1/system.d/org.ganesha.nfsd.conf
  '';

  meta = nixpkgsGanesha.meta;
})
