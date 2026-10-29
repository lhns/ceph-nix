# Boots a VM with one Open CAS cache (write-back, two IO classes with their own cache modes),
# writes through the cached core, reboots and checks the data and the cache come back.
{ pkgs, self }:

pkgs.testers.runNixOSTest {
  name = "opencas";
  node.pkgsReadOnly = false; # the module adds the overlay itself
  nodes.machine =
    { ... }:
    {
      imports = [ self.nixosModules.opencas ];
      virtualisation.memorySize = 2048;
      virtualisation.cores = 2;
      # casadm only takes /dev/disk/by-id links, so the disks need serials.
      virtualisation.emptyDiskImages = [
        {
          size = 1024;
          driveConfig.deviceExtraOpts.serial = "OCCACHE";
        }
        {
          size = 4096;
          driveConfig.deviceExtraOpts.serial = "OCCORE";
        }
      ];
      services.opencas = {
        enable = true;
        initializeBlankCaches = true;
        settleTimeout = 120;
        caches."1" = {
          device = "/dev/disk/by-id/virtio-OCCACHE";
          mode = "wb";
          cores = [ "/dev/disk/by-id/virtio-OCCORE" ];
          ioClasses = [
            {
              id = 1;
              name = "metadata&done";
              priority = 0;
              cacheMode = "wb";
            }
            {
              id = 10;
              name = "core_id:eq:1&done";
              priority = 5;
              cacheMode = "wt";
            }
          ];
        };
      };
    };

  testScript = ''
    machine.wait_for_unit("multi-user.target")
    machine.wait_for_unit("open-cas.service")

    with subtest("cache is created from the config"):
        out = machine.succeed("casadm -L")
        print(out)
        machine.succeed("casadm -L -o csv | grep -E '^cache,1,.*Running'")
        machine.succeed("test -b /dev/cas1-1")
        machine.succeed("grep -q cas_cache /proc/modules")

    with subtest("effective per-core cache mode"):
        # cache row: wb with the * marker for per-class overrides; core 1 is overridden to wt
        machine.succeed("casadm -L -o csv | grep -E '^cache,1,.*,wb\*'")
        machine.succeed("casadm -L -o csv | grep -E '^core,1,.*,Active,wt\*'")

    with subtest("IO class CSV has the mode column"):
        csv = machine.succeed("casadm --io-class --list --cache-id 1 --output-format csv")
        print(csv)
        lines = csv.strip().splitlines()
        assert lines[0].split(",")[-1] == "Cache mode", lines[0]
        modes = {l.split(",")[0]: l.split(",")[-1] for l in lines[1:]}
        assert modes["1"] == "wb", modes
        assert modes["10"] == "wt", modes
        assert modes["0"] in ("", "-"), modes

    with subtest("I/O through the core changes the stats"):
        before = machine.succeed("casadm -P -i 1 -o csv")
        machine.succeed("dd if=/dev/urandom of=/tmp/ref bs=1M count=64")
        machine.succeed("dd if=/tmp/ref of=/dev/cas1-1 bs=1M oflag=direct conv=fsync")
        after = machine.succeed("casadm -P -i 1 -o csv")
        assert before != after, "stats did not change"
        machine.succeed("cmp -n 67108864 /tmp/ref /dev/cas1-1")
        machine.succeed("md5sum /tmp/ref | cut -d' ' -f1 > /var/tmp/ref.md5")

    with subtest("cache and data survive a reboot"):
        machine.shutdown()
        machine.start()
        machine.wait_for_unit("multi-user.target")
        machine.wait_for_unit("open-cas.service")
        machine.succeed("casadm -L -o csv | grep -E '^cache,1,.*Running'")
        machine.succeed("casadm -L -o csv | grep -E '^core,1,.*Active'")
        sum_ = machine.succeed("head -c 67108864 /dev/cas1-1 | md5sum | cut -d' ' -f1").strip()
        ref = machine.succeed("cat /var/tmp/ref.md5").strip()
        assert sum_ == ref, (sum_, ref)
        csv = machine.succeed("casadm --io-class --list --cache-id 1 --output-format csv")
        assert "metadata&done" in csv and ",wt" in csv, csv

    with subtest("clean stop"):
        machine.succeed("casctl stop")
        out = machine.succeed("casadm -L")
        print(out)
        machine.fail("casadm -L -o csv | grep -E '^cache,'")
  '';
}
