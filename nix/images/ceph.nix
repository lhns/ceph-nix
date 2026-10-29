# mkCephImage: a Ceph container image with the file layout of quay.io/ceph/ceph (ADR 0002), for cephadm and Rook.
# Streamed (streamLayeredImage): the closure is several GB, so no tarball is stored in /nix/store.
#   $(nix build .#ceph-image-tentacle --print-out-paths --no-link) | docker load
{ pkgs }:
{
  ceph, # the scope's `ceph` (outputs out, lib, dev, client, ...), with passthru.pythonEnv
  ganesha ? null, # default: nfs-ganesha with the Ceph/RGW FSALs from this `ceph`
  cephadm, # derivation with bin/cephadm (nix/pkgs/cephadm.nix)
  smoke ? null, # derivation with libexec/ceph-nix/smoke (nix/pkgs/ceph-smoke.nix), for tests/cpu.sh
  extraPython ? [ ], # python packages the mgr needs beyond ceph.pythonEnv, from the same python
  extraPackages ? [ ],
  version,
  cephRef, # CEPH_REF / CEPH_VERSION, as upstream sets them (the release branch name)
  rev ? "dirty",
  name ? "ceph-nix",
  tag ? version,
}:
let
  inherit (pkgs) lib;
  pyEnv = ceph.pythonEnv;
  python = pyEnv.python;
  sitePackages = python.sitePackages;

  ganeshaPkg =
    if ganesha != null then
      ganesha
    else
      (pkgs.nfs-ganesha.override {
        useCeph = true;
        inherit ceph;
      }).overrideAttrs
        (old: {
          # Ganesha 9 (upstream's image has 5) aborts without CAP_SYS_RESOURCE (PR_SET_IO_FLUSHER), which
          # cephadm's NFS containers don't get; make the option's default "tolerate failure".
          postPatch = (old.postPatch or "") + ''
            f=$(grep -rl allow_set_io_flusher_fail src | head -n1)
            sed -i 's/\("allow_set_io_flusher_fail",[[:space:]]*\)false/\1true/' "$f"
            grep -q '"allow_set_io_flusher_fail",[[:space:]]*true' "$f"
          '';
        });

  # Earlier entries win name clashes in /usr/bin.
  userland =
    with pkgs;
    [
      bashInteractive
      coreutils
      findutils
      gnugrep
      gnused
      gawk
      gnutar
      gzip
      bzip2
      xz
      unzip
      zip
      diffutils
      less
      which
      curl
      jq
      openssh
      openssl
      procps
      psmisc
      hostname
      iproute2
      getopt
      # ceph-volume and Rook
      util-linux
      lvm2
      e2fsprogs
      xfsprogs
      gptfdisk
      parted
      kmod
      systemdMinimal # udevadm
      shadow
      logrotate
      quota
      thin-provisioning-tools
      glibc
      getent
      keyutils
      libcap
      libnbd
      glib
      cryptsetup
      nvme-cli
      smartmontools
      sg3_utils
      attr
      acl
      fuse
      fuse3
      # NFS
      nfs-utils
      rpcbind
      dbus
      # rgw lua scripts
      lua5_4
      lua5_4.pkgs.luarocks
    ]
    ++ extraPackages;

  binPackages = [
    cephadm
    ceph
    pyEnv
    ganeshaPkg
  ]
  ++ map lib.getBin userland
  # tools that nixpkgs puts in the default output rather than the bin one (lvm2's blkdeactivate, fsadm, ...)
  ++ userland;

  pythonPath = lib.concatStringsSep ":" (
    [
      "${pyEnv}/${sitePackages}"
      "${ceph}/${sitePackages}"
    ]
    ++ lib.optional (extraPython != [ ]) (python.pkgs.makePythonPath extraPython)
  );

  # The udev settings from upstream's Containerfile (the container can't reach udev), plus the Open CAS block device
  # type so ceph-volume's LVM sees PVs on /dev/casX-Y.
  lvmConf = pkgs.writeTextDir "etc/lvm/lvm.conf" ''
    devices {
        obtain_device_list_from_udev = 0
        types = [ "cas", 16 ]
    }
    activation {
        udev_sync = 0
        udev_rules = 0
    }
  '';

  files = pkgs.symlinkJoin {
    name = "ceph-image-files";
    paths = [
      lvmConf
      (pkgs.writeTextDir "etc/passwd" ''
        root:x:0:0:root:/root:/bin/bash
        daemon:x:2:2:daemon:/:/sbin/nologin
        ceph:x:167:167:Ceph daemons:/var/lib/ceph:/sbin/nologin
        dbus:x:81:81:System message bus:/:/sbin/nologin
        nobody:x:65534:65534:Kernel Overflow User:/:/sbin/nologin
      '')
      (pkgs.writeTextDir "etc/group" ''
        root:x:0:
        daemon:x:2:
        sys:x:3:
        adm:x:4:
        tty:x:5:
        disk:x:6:
        lp:x:7:
        mem:x:8:
        kmem:x:9:
        wheel:x:10:
        cdrom:x:11:
        mail:x:12:
        dialout:x:18:
        floppy:x:19:
        tape:x:33:
        video:x:39:
        audio:x:63:
        kvm:x:36:
        input:x:104:
        users:x:100:
        ceph:x:167:
        dbus:x:81:
        nobody:x:65534:
      '')
      (pkgs.writeTextDir "etc/nsswitch.conf" ''
        passwd: files
        group: files
        hosts: files dns
      '')
      (pkgs.writeTextDir "etc/os-release" ''
        NAME="ceph-nix"
        ID=ceph-nix
        VERSION_ID="${version}"
        PRETTY_NAME="ceph-nix ${version}"
        HOME_URL="https://github.com/lhns/ceph-nix"
      '')
    ];
  };

  # The FHS view: /usr/bin, /usr/sbin (same directory), /usr/libexec/ceph, /usr/lib64, /usr/share/ceph.
  # Plain symlinks into the store, so everything resolves.
  fhs = pkgs.runCommand "ceph-image-fhs" { } ''
    mkdir -p $out/usr/bin $out/usr/libexec $out/usr/lib64 $out/usr/share
    for p in ${lib.concatStringsSep " " binPackages}; do
      for d in bin sbin; do
        [ -d "$p/$d" ] || continue
        for f in "$p/$d"/*; do
          b=''${f##*/}
          [ -e "$out/usr/bin/$b" ] || [ -L "$out/usr/bin/$b" ] || ln -s "$f" "$out/usr/bin/$b"
        done
      done
    done
    ln -s tar $out/usr/bin/gtar
    ln -s bin $out/usr/sbin
    ln -s usr/bin $out/bin
    ln -s usr/sbin $out/sbin

    ln -s ${ceph.lib}/libexec/ceph $out/usr/libexec/ceph
    ln -s ${ceph.lib}/lib/ceph $out/usr/share/ceph
    ln -s ${pkgs.tzdata}/share/zoneinfo $out/usr/share/zoneinfo
    ln -s ${pkgs.dbus}/share/dbus-1 $out/usr/share/dbus-1
    for l in ${ceph.lib}/lib/* ${ganeshaPkg}/lib/*; do
      [ -e "$out/usr/lib64/''${l##*/}" ] || ln -s "$l" "$out/usr/lib64/"
    done
    ${lib.optionalString (smoke != null) ''
      mkdir -p $out/usr/libexec/ceph-nix
      ln -s ${smoke}/libexec/ceph-nix/smoke $out/usr/libexec/ceph-nix/smoke
    ''}
    mkdir -p $out/etc/ssl/certs $out/etc/dbus-1
    ln -s ${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt $out/etc/ssl/certs/ca-bundle.crt
    ln -s ${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt $out/etc/ssl/certs/ca-certificates.crt
    ln -s ${pkgs.dbus}/share/dbus-1/system.conf $out/etc/dbus-1/system.conf
    ln -s ${pkgs.dbus}/share/dbus-1/session.conf $out/etc/dbus-1/session.conf
  '';
in
pkgs.dockerTools.streamLayeredImage {
  inherit name tag;
  maxLayers = 120;
  contents = [
    files
    fhs
  ];

  fakeRootCommands = ''
    mkdir -p tmp root run/ceph run/ganesha run/dbus var/lib/ceph var/log/ceph etc/ceph
    ln -s ../run var/run
    chmod 1777 tmp
    chmod 700 root
    chown 167:167 var/lib/ceph var/log/ceph run/ceph
    chmod 750 var/lib/ceph
    chmod 770 var/log/ceph run/ceph
  '';

  config = {
    Cmd = [ "/bin/bash" ];
    Env = [
      "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
      "PYTHONPATH=${pythonPath}"
      "PYTHONNOUSERSITE=1"
      "SSL_CERT_FILE=/etc/ssl/certs/ca-bundle.crt"
      "CEPH_IS_DEVEL=false"
      "CEPH_REF=${cephRef}"
      "CEPH_VERSION=${cephRef}"
    ];
    Labels = {
      "org.opencontainers.image.title" = name;
      "org.opencontainers.image.source" = "https://github.com/lhns/ceph-nix";
      "org.opencontainers.image.version" = version;
      "org.opencontainers.image.revision" = rev;
      "org.opencontainers.image.licenses" = "LGPL-2.1-or-later AND GPL-2.0-only";
      "ceph" = "True";
      "CEPH_REF" = cephRef;
    };
  };
}
