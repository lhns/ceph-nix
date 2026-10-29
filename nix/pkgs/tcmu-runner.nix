# tcmu-runner as upstream's image has it (EL9 RPM tcmu-runner-1.5.2-101.g0fd5eda): Ceph's fork, which is v1.5.2 plus
# 101 commits (fortify fixes, newer librbd). Handlers file_optical, zbc, qcow and rbd; no glusterfs handler (not in the
# RPM's file list) and no tcmalloc (the RPM links gperftools; an allocator only, so skipped).
{
  lib,
  stdenv,
  fetchFromGitHub,
  cmake,
  pkg-config,
  glib,
  libnl,
  kmod,
  zlib,
  ceph, # the scope's ceph: the rbd handler is built against the same librbd the image ships
}:
stdenv.mkDerivation {
  pname = "tcmu-runner";
  version = "1.5.2-101.g0fd5eda";

  src = fetchFromGitHub {
    owner = "ceph";
    repo = "tcmu-runner";
    rev = "0fd5edac42fbacb600af4e712e8d0d0af833b57d";
    hash = "sha256-rt9l/So3XzplO1xDmJuqHymogZfznRmzIG3X8WoveT0=";
  };

  nativeBuildInputs = [
    cmake
    pkg-config
    glib
    glib.dev # gdbus-codegen
  ];
  buildInputs = [
    glib
    libnl
    kmod
    zlib
    ceph.lib
    ceph.dev
  ];

  postPatch = ''
    # the upstream build installs into /etc and /usr (and backs up files there); install under the prefix instead
    sed -i \
      -e 's/ -Werror//' \
      -e 's|^set(tcmu-runner_HANDLER_PATH .*|set(tcmu-runner_HANDLER_PATH "/usr/lib64/tcmu-runner")|' \
      -e '/^install(SCRIPT /d' \
      -e 's|DESTINATION /usr/share/dbus-1/system-services|DESTINATION share/dbus-1/system-services|' \
      -e 's|DESTINATION /etc/dbus-1/system.d|DESTINATION etc/dbus-1/system.d|' \
      CMakeLists.txt
    grep -q 'tcmu-runner_HANDLER_PATH "/usr/lib64/tcmu-runner"' CMakeLists.txt
    cat >> CMakeLists.txt <<'CMAKE'
    install(FILES tcmu.conf DESTINATION etc/tcmu)
    install(FILES logrotate.conf DESTINATION etc/logrotate.d RENAME tcmu-runner)
    CMAKE
  '';

  cmakeFlags = [
    "-Dwith-glfs=false"
    "-Dwith-tcmalloc=false"
    "-DSUPPORT_SYSTEMD=OFF"
    "-DCMAKE_POLICY_VERSION_MINIMUM=3.5"
    "-DCMAKE_INSTALL_RPATH=${placeholder "out"}/lib"
  ];

  meta = {
    description = "Userspace side of the LIO TCM-User backstore, with the Ceph RBD handler";
    homepage = "https://github.com/open-iscsi/tcmu-runner";
    license = [
      lib.licenses.asl20
      lib.licenses.lgpl21Plus
    ];
    platforms = lib.platforms.linux;
    mainProgram = "tcmu-runner";
  };
}
