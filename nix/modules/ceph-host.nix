# A NixOS host for Ceph daemons run by cephadm (ADR 0004).
#
# cephadm expects an FHS host: it writes units to /etc/systemd/system (a store symlink on NixOS),
# and its units and the orchestrator's helper scripts call /bin/bash, /usr/bin/python3, LVM tools in
# /usr/sbin and so on. This module provides those pieces; it does not import nixos-cloudinit or choose
# a bootloader, networking or disks.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.ceph-host;

  imageInfo = builtins.fromJSON (builtins.readFile ../ceph-image.json);

  unitsState = "${cfg.stateDir}/systemd-units";
  upper = "${unitsState}/upper";
  corePath = lib.makeBinPath [
    pkgs.coreutils
    pkgs.util-linux
  ];

  # LVM tools ceph-volume runs on the host through nsenter; it only searches /usr/sbin and friends.
  lvmTools = [
    "dmsetup"
    "lvchange"
    "lvcreate"
    "lvdisplay"
    "lvextend"
    "lvm"
    "lvreduce"
    "lvremove"
    "lvrename"
    "lvresize"
    "lvs"
    "pvchange"
    "pvcreate"
    "pvdisplay"
    "pvmove"
    "pvremove"
    "pvresize"
    "pvs"
    "vgchange"
    "vgcreate"
    "vgdisplay"
    "vgextend"
    "vgreduce"
    "vgremove"
    "vgrename"
    "vgs"
  ];
  usrSbin =
    pkgs.runCommand "ceph-host-usr-sbin"
      {
        lvm = lib.getBin pkgs.lvm2;
      }
      ''
        mkdir -p $out
        for t in ${toString lvmTools}; do
          ln -s $lvm/bin/$t $out/$t
        done
      '';

  # switch-to-configuration stops active units whose file is in /etc/systemd/system but not in the new
  # generation, which takes every daemon down through PartOf. X-StopOnRemoval=false prevents that. The
  # patched cephadm writes it itself; units written by an unpatched one (the mgr uses the cephadm of the
  # image) get a drop-in, from activation and whenever cephadm changes the unit directory.
  keepUnits = pkgs.writeShellScript "ceph-host-keep-units" ''
    PATH=${corePath}
    for f in ${upper}/ceph*.service ${upper}/ceph*.target; do
      [ -f "$f" ] || continue
      n=$(basename "$f")
      d=/etc/systemd/system/$n.d
      [ -e "$d/90-nixos-keep.conf" ] && continue
      mkdir -p "$d"
      printf '[Unit]\nX-StopOnRemoval=false\n' > "$d/90-nixos-keep.conf"
    done
  '';
in
{
  options.services.ceph-host = {
    enable = lib.mkEnableOption "a Ceph host managed by cephadm";

    image = lib.mkOption {
      type = lib.types.str;
      default = "${imageInfo.image}:${imageInfo.tag}@${imageInfo.digest}";
      defaultText = lib.literalExpression "image, tag and digest from nix/ceph-image.json";
      description = ''
        Container image cephadm uses, exported as `CEPHADM_IMAGE` so `cephadm bootstrap` picks it
        up and written to `/etc/ceph-nix/image`. The default is the pinned upstream release; the
        release flow points it at the ghcr.io/lhns/ceph-nix image.
      '';
    };

    cephadmPackage = lib.mkOption {
      type = lib.types.package;
      default = pkgs.callPackage ../pkgs/cephadm-host.nix { };
      defaultText = lib.literalExpression "pkgs.callPackage ./nix/pkgs/cephadm-host.nix { }";
      description = ''
        cephadm for this host. Its unit templates carry `X-StopOnRemoval=false`. The mgr copies the
        cephadm of the *image* to the hosts it manages, so the patch fully applies only once the
        image ships it; the drop-in writer covers the gap.
      '';
    };

    orchestratorKeys = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = ''
        SSH public keys allowed to log in as root, e.g. the cluster's `/etc/ceph/ceph.pub`
        (cephadm manages other hosts as root over SSH).
      '';
    };

    openFirewall = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Open the Ceph ports (mon, osd/mgr/mds range, dashboard, exporters).";
    };

    clientKernelModules = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Load the `rbd` and `ceph` kernel client modules, for hosts that map RBD images or mount
        CephFS. mon, mgr and OSD hosts do not need them.
      '';
    };

    stateDir = lib.mkOption {
      type = lib.types.path;
      default = "/var/lib/ceph-nix";
      description = "Where the unit directory overlay keeps what cephadm writes.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = !(config.system.etc.overlay.enable or false);
        message = ''
          services.ceph-host does not support system.etc.overlay.enable: the writable
          /etc/systemd/system is built on classic /etc (activation replaces the store symlink with an
          overlay mount), and the combination is untested. Set system.etc.overlay.enable = false.
        '';
      }
    ];

    # cephadm needs a root shell over SSH.
    services.openssh.enable = lib.mkDefault true;
    services.openssh.settings.PermitRootLogin = lib.mkForce "prohibit-password";
    users.users.root.openssh.authorizedKeys.keys = cfg.orchestratorKeys;

    virtualisation.podman.enable = true;
    services.chrony.enable = true;
    environment.systemPackages = [
      cfg.cephadmPackage
      pkgs.lvm2
      pkgs.python3
    ];
    boot.kernelModules = lib.mkIf cfg.clientKernelModules [
      "rbd"
      "ceph"
    ];

    networking.firewall = lib.mkIf cfg.openFirewall {
      allowedTCPPorts = [
        3300 # mon v2
        6789 # mon v1
        8443 # dashboard
        8765 # mgr service discovery
        9283 # mgr prometheus
        9926 # ceph-exporter
      ];
      allowedTCPPortRanges = [
        {
          from = 6800;
          to = 7300;
        }
      ];
    };

    environment.variables.CEPHADM_IMAGE = cfg.image;

    environment.etc = {
      "ceph-nix/image".text = cfg.image + "\n";
      # cephadm's units read EnvironmentFile=-/etc/environment, and their ExecStop runs `bash` from
      # PATH, which systemd's default PATH on NixOS lacks. Host-wide for every unit that reads it.
      "environment".text = ''
        PATH=/run/wrappers/bin:/run/current-system/sw/bin
      '';
    };

    # The FHS paths cephadm's units, the mgr's copy of cephadm and ceph-volume hard-code.
    systemd.tmpfiles.rules = [
      "L+ /bin/bash - - - - ${pkgs.bash}/bin/bash"
      "L+ /bin/rm - - - - ${pkgs.coreutils}/bin/rm"
      "L+ /bin/ls - - - - ${pkgs.coreutils}/bin/ls"
      "L+ /usr/bin/python3 - - - - ${pkgs.python3}/bin/python3"
      "L+ /usr/sbin - - - - ${usrSbin}"
      # every cephadm call writes /etc/logrotate.d/cephadm and fails without the directory
      "d /etc/logrotate.d 0755 root root - -"
      "d ${cfg.stateDir} 0755 root root - -"
      "d ${upper} 0755 root root - -"
    ];

    # cephadm writes /etc/logrotate.d/{cephadm,ceph-<fsid>}; NixOS's logrotate does not read that directory.
    services.logrotate = {
      enable = true;
      settings.header.include = "/etc/logrotate.d";
      checkConfig = false; # the build sandbox has no /etc/logrotate.d
    };

    # Writable /etc/systemd/system. It is a symlink into the store on NixOS (also with etc.overlay),
    # so cephadm cannot write units there. Every activation drops the overlay before `etc` (so
    # setup-etc can place its symlink), then replaces the symlink with an overlay mount: lower is a
    # copy of this generation's unit directory, upper is persistent and holds what cephadm wrote.
    # Units that cephadm removed stay removed (whiteouts persist across generations).
    system.activationScripts.cephHostUnitDirPre = {
      deps = [ "specialfs" ];
      text = ''
        (
          PATH=${corePath}
          if mountpoint -q /etc/systemd/system; then
            umount /etc/systemd/system || umount -l /etc/systemd/system
          fi
          if [ -d /etc/systemd/system ] && [ ! -L /etc/systemd/system ]; then
            rmdir /etc/systemd/system
          fi
        )
      '';
    };
    system.activationScripts.etc.deps = [ "cephHostUnitDirPre" ];
    system.activationScripts.cephHostUnitDir = {
      deps = [ "etc" ];
      text = ''
        (
          PATH=${corePath}
          set -e
          mkdir -p ${upper} ${unitsState}/work /run/ceph-nix
          lower=$(mktemp -d /run/ceph-nix/units-lower.XXXXXX)
          cp -a "$(readlink -f /etc/systemd/system)/." "$lower/"
          rm /etc/systemd/system
          mkdir /etc/systemd/system
          mount -t overlay overlay \
            -o lowerdir="$lower",upperdir=${upper},workdir=${unitsState}/work /etc/systemd/system
          for d in /run/ceph-nix/units-lower.*; do
            [ "$d" = "$lower" ] || rm -rf "$d"
          done
          ${keepUnits}
        ) || _localstatus=$?
      '';
    };

    systemd.paths.ceph-host-keep-units = {
      wantedBy = [ "multi-user.target" ];
      pathConfig.PathChanged = upper;
    };
    systemd.services.ceph-host-keep-units = {
      description = "Keep cephadm's units running across NixOS switches";
      serviceConfig = {
        Type = "oneshot";
        ExecStart = keepUnits;
      };
    };
  };
}
