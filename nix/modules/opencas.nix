# Open CAS (lhns fork) on NixOS: kernel module, casadm/casctl, /etc/opencas generated from options.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.opencas;

  cacheModes = [
    "wt"
    "wb"
    "wa"
    "wo"
    "pt"
  ];

  ioClassType = lib.types.submodule {
    options = {
      id = lib.mkOption {
        type = lib.types.ints.between 0 32;
        description = "IO class id. Id 0 is the catch-all and is always named `unclassified`.";
      };
      name = lib.mkOption {
        type = lib.types.str;
        description = "Classification rule, e.g. `metadata&done` or `core_id:eq:1&done`. No commas or quotes.";
      };
      priority = lib.mkOption {
        type = lib.types.nullOr (lib.types.ints.between 0 255);
        default = null;
        description = "Eviction priority (lower is evicted later); null means pinned.";
      };
      allocation = lib.mkOption {
        type = lib.types.str;
        default = "1.00";
        description = "Maximum share of the cache for this class, `0.00` to `1.00`.";
      };
      cacheMode = lib.mkOption {
        type = lib.types.nullOr (lib.types.enum cacheModes);
        default = null;
        description = "Cache mode for IOs of this class; null inherits the cache mode.";
      };
    };
  };

  cacheType = lib.types.submodule {
    options = {
      device = lib.mkOption {
        type = lib.types.path;
        example = "/dev/disk/by-id/nvme-EXAMPLE";
        description = "Cache device. casadm only accepts /dev/disk/by-id or /dev/disk/by-path links.";
      };
      mode = lib.mkOption {
        type = lib.types.enum cacheModes;
        default = "wt";
        description = "Cache mode: write-through, write-back, write-around, write-only, pass-through.";
      };
      cacheLineSize = lib.mkOption {
        type = lib.types.nullOr (
          lib.types.enum [
            4
            8
            16
            32
            64
          ]
        );
        default = null;
        description = "Cache line size in KiB; null uses the casadm default.";
      };
      extraFlags = lib.mkOption {
        type = lib.types.attrsOf lib.types.str;
        default = { };
        example = {
          cleaning_policy = "alru";
          promotion_policy = "nhit";
        };
        description = "Extra fields of the cache line in opencas.conf (see opencas.conf(5)).";
      };
      ioClasses = lib.mkOption {
        type = lib.types.nullOr (lib.types.listOf ioClassType);
        default = null;
        description = ''
          IO classification. null writes no IO class file. The `Cache mode` column is only
          written when at least one class sets `cacheMode`. Class 0 (`unclassified`) is added with
          priority 22 and allocation 1.00 unless you define it.
        '';
      };
      cores = lib.mkOption {
        type = lib.types.listOf lib.types.path;
        default = [ ];
        description = ''
          Core devices (by-id or by-path links). Core ids are assigned from 1 in list order,
          so the first core is `core_id:eq:1` and shows up as /dev/cas<cache id>-1.
        '';
      };
    };
  };

  ioClassFile = id: "/etc/opencas/ioclass-config-${id}.csv";

  ioClassCsv =
    classes:
    let
      withZero =
        if lib.any (c: c.id == 0) classes then
          classes
        else
          [
            {
              id = 0;
              name = "unclassified";
              priority = 22;
              allocation = "1.00";
              cacheMode = null;
            }
          ]
          ++ classes;
      sorted = lib.sort (a: b: a.id < b.id) withZero;
      withMode = lib.any (c: c.cacheMode != null) classes;
      row =
        c:
        lib.concatStringsSep "," (
          [
            (toString c.id)
            (if c.id == 0 then "unclassified" else c.name)
            (lib.optionalString (c.priority != null) (toString c.priority))
            c.allocation
          ]
          ++ lib.optional withMode (lib.optionalString (c.cacheMode != null) c.cacheMode)
        );
      header =
        "IO class id,IO class name,Eviction priority,Allocation"
        + lib.optionalString withMode ",Cache mode";
    in
    lib.concatStringsSep "\n" ([ header ] ++ map row sorted) + "\n";

  # opencas.py lowercases the extra fields, so the file name has to be lowercase.
  cacheLine =
    id: c:
    let
      flags =
        c.extraFlags
        // lib.optionalAttrs (c.cacheLineSize != null) { cache_line_size = toString c.cacheLineSize; }
        // lib.optionalAttrs (c.ioClasses != null) { ioclass_file = ioClassFile id; };
      extra = lib.concatStringsSep "," (lib.mapAttrsToList (k: v: "${k}=${v}") flags);
    in
    "${id}\t${c.device}\t${c.mode}${lib.optionalString (extra != "") "\t${extra}"}";

  rawDevices = lib.concatLists (lib.mapAttrsToList (_: c: [ c.device ] ++ c.cores) cfg.caches);

  coreLines = id: c: lib.imap1 (n: dev: "${id}\t${toString n}\t${dev}") c.cores;

  opencasConf = ''
    version=19.3.0
    # Generated from services.opencas.caches
    [caches]
    ${lib.concatStringsSep "\n" (lib.mapAttrsToList cacheLine cfg.caches)}

    [cores]
    ${lib.concatStringsSep "\n" (lib.concatLists (lib.mapAttrsToList coreLines cfg.caches))}
  '';

  # Creates caches that hold no Open CAS metadata yet (first boot); known caches are left to
  # open-cas.service, which loads them. Formatting happens at most once per cache id: a marker
  # in /var/lib/opencas/initialized records it, and with a marker present a cache that does not
  # load is an error, never a reason to format (dirty write-back data may sit behind it).
  initScript = pkgs.writeScript "opencas-init" ''
    #!${pkgs.python3}/bin/python3
    import json
    import os
    import subprocess
    import sys
    sys.path.insert(0, "${cfg.package}/lib/opencas")
    import opencas

    MARKER_DIR = "/var/lib/opencas/initialized"


    def error(msg):
        print(f"opencas-init: ERROR: {msg}", file=sys.stderr)


    def serial(dev):
        out = subprocess.run(["lsblk", "-dno", "SERIAL", dev], capture_output=True, text=True)
        return out.stdout.strip()


    opencas.wait_for_cas_ctrl()
    os.makedirs(MARKER_DIR, exist_ok=True)
    config = opencas.cas_config.from_file(opencas.cas_config.default_location, allow_incomplete=True)
    failed = False
    for cache in config.caches.values():
        if opencas.is_cache_started(cache):
            continue
        # A casadm error here raises and fails the unit without touching the device.
        if opencas.check_cache_device(cache.device)["Is cache"] == "yes":
            continue
        marker = os.path.join(MARKER_DIR, str(cache.cache_id))
        if os.path.exists(marker):
            error(f"cache {cache.cache_id} ({cache.device}) was initialized before but holds no "
                  f"loadable Open CAS metadata; refusing to format it again. Check the device, "
                  f"then remove {marker} to allow a new format.")
            failed = True
            continue
        if subprocess.run(["blkid", "-p", cache.device], capture_output=True).returncode != 2:
            error(f"{cache.device} carries a signature or could not be probed; refusing to format it")
            failed = True
            continue
        print(f"opencas-init: creating cache {cache.cache_id} on {cache.device}")
        opencas.start_cache(cache, load=False, force=True)
        with open(marker, "w") as f:
            json.dump({"device": os.path.realpath(cache.device), "serial": serial(cache.device)}, f)
        opencas.configure_cache(cache)
        for core in cache.cores.values():
            opencas.add_core(core, False)
    sys.exit(1 if failed else 0)
  '';

  deactivateCasVgs = pkgs.writeShellScript "opencas-deactivate-vgs" ''
    PATH=${
      lib.makeBinPath [
        pkgs.lvm2
        pkgs.gawk
        pkgs.coreutils
      ]
    }
    for vg in $(pvs --noheadings -o vg_name,pv_name | awk '$2 ~ "^/dev/cas" { print $1 }' | sort -u); do
      vgchange -an --noudevsync "$vg"
    done
  '';

  # LVM event-activates a VG from a raw core as soon as udev sees it, a few seconds before the cache is
  # loaded and before the by-id links its global_filter relies on exist. The activated LVs hold the
  # core open, so Open CAS cannot attach it. Release them before open-cas.service attaches cores.
  releaseRawDevices = pkgs.writeShellScript "opencas-release-raw-devices" ''
    PATH=${
      lib.makeBinPath [
        pkgs.lvm2
        pkgs.coreutils
        pkgs.systemd
      ]
    }
    udevadm settle --timeout=30
    for dev in ${lib.escapeShellArgs rawDevices}; do
      real=$(readlink -f "$dev") || continue
      for holder in /sys/class/block/$(basename "$real")/holders/*; do
        [ -e "$holder/dm/name" ] || continue
        dmsetup remove "$(cat "$holder/dm/name")"
      done
    done
  '';
in
{
  options.services.opencas = {
    enable = lib.mkEnableOption "Open CAS block device caching";

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.open-cas;
      defaultText = lib.literalExpression "pkgs.open-cas";
      description = "Userspace package (casadm, casctl, udev rules, units).";
    };

    kernelPackage = lib.mkOption {
      type = lib.types.package;
      default = config.boot.kernelPackages.open-cas;
      defaultText = lib.literalExpression "config.boot.kernelPackages.open-cas";
      description = ''
        Kernel module package. Defaults to the one built for `boot.kernelPackages`, which is
        marked broken for kernels outside what this Open CAS release supports (5.10 to 7.0).
      '';
    };

    caches = lib.mkOption {
      type = lib.types.attrsOf cacheType;
      default = { };
      example = lib.literalExpression ''
        {
          "1" = {
            device = "/dev/disk/by-id/nvme-EXAMPLE";
            mode = "wb";
            cores = [ "/dev/disk/by-id/wwn-0x123456789abcdef0" ];
          };
        }
      '';
      description = "Caches by cache id (1 to 16384), written to /etc/opencas/opencas.conf.";
    };

    initializeBlankCaches = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Create caches whose device has no Open CAS metadata at boot (casadm --start-cache --force),
        then add their cores. Without it, a new cache has to be created once with `casctl init`.
        This overwrites the cache device, so only enable it for devices dedicated to caching.
        A cache is formatted at most once: `blkid -p` must find no signature, and the unit records
        /var/lib/opencas/initialized/<cache id>. If that marker exists and the cache does not load,
        the unit fails with an error instead of formatting again (remove the marker to allow it).
      '';
    };

    settleTimeout = lib.mkOption {
      type = lib.types.ints.positive;
      default = 1780;
      description = "Seconds open-cas.service waits for all configured caches and cores at boot.";
    };
  };

  config = lib.mkIf cfg.enable {
    boot.extraModulePackages = [ cfg.kernelPackage ];
    boot.kernelModules = [ "cas_cache" ];

    services.udev.packages = [ cfg.package ];
    systemd.packages = [ cfg.package ];
    environment.systemPackages = [ cfg.package ];

    environment.etc = {
      "opencas/opencas.conf".text = opencasConf;
      # LVM ignores unknown block devices; cas devices need an explicit type (max 16 partitions).
      # The raw cache and core devices must not be scanned: a core carries the same PV signature as
      # its cas device, which makes LVM refuse both ("duplicates"). LVM only knows the kernel names
      # unless the by-id/by-path directories are scanned, and the filter needs those aliases.
      "lvm/lvm.conf".text = lib.mkIf config.services.lvm.enable ''
        devices/types = [ "cas", 16 ]
        devices/obtain_device_list_from_udev = 0
        devices/scan = [ "/dev", "/dev/disk/by-id", "/dev/disk/by-path" ]
        devices/global_filter = [ ${lib.concatMapStringsSep ", " (d: ''"r|^${d}$|"'') rawDevices} ]
      '';
    }
    // lib.mapAttrs' (
      id: c: lib.nameValuePair "opencas/ioclass-config-${id}.csv" { text = ioClassCsv c.ioClasses; }
    ) (lib.filterAttrs (_: c: c.ioClasses != null) cfg.caches);

    systemd.services.open-cas = {
      overrideStrategy = "asDropinIfExists";
      requiredBy = [
        "local-fs.target"
        "local-fs-pre.target"
      ];
      after = [ "systemd-modules-load.service" ];
      serviceConfig.ExecStartPre = "-${releaseRawDevices}";
      serviceConfig.ExecStart = [
        ""
        "${cfg.package}/bin/casctl settle --timeout ${toString cfg.settleTimeout} --interval 5"
      ];
    };

    # An active LV on a cas device keeps the cache open, so `casctl stop` fails and the cache comes back
    # dirty with its core inactive. Deactivate every VG with a PV on a cas device first, and run after
    # the consumers (ceph.target is harmless when Ceph is not installed).
    systemd.services.open-cas-shutdown = {
      overrideStrategy = "asDropinIfExists";
      wantedBy = [ "final.target" ];
      after = [ "ceph.target" ];
      serviceConfig.ExecStartPre = "-${deactivateCasVgs}";
    };

    systemd.services.opencas-init = lib.mkIf cfg.initializeBlankCaches {
      description = "Create blank Open CAS caches";
      unitConfig.DefaultDependencies = false;
      after = [
        "systemd-modules-load.service"
        "systemd-udevd.service"
      ];
      before = [ "open-cas.service" ];
      wantedBy = [ "open-cas.service" ];
      path = [
        cfg.package
        pkgs.util-linux
      ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = initScript;
      };
    };
  };
}
