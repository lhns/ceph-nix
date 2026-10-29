# Spike (plan step 0): can cephadm run Ceph on NixOS hosts, and with which unit-dir mechanism?
# Upstream image and cephadm, two nodes on the nixos-cloudinit base, bootstrap + host add + OSDs,
# then reboot and switch-to-configuration. Findings are printed to the log; see the PR for the summary.
{ pkgs, nixos-cloudinit }:

let
  inherit (pkgs) lib;

  version = "21.2.0";

  # amd64 manifest of quay.io/ceph/ceph:v21.2.0
  cephImage = pkgs.dockerTools.pullImage {
    imageName = "quay.io/ceph/ceph";
    imageDigest = "sha256:403c079a3f1efa7b58895750e9dd18c6da4701e60b746b084385c8cc545877b6";
    hash = "sha256-l/1Eyay6CUxLYkj1NBFPGxHQh278U4w63csVZB3IQwM=";
    finalImageName = "quay.io/ceph/ceph";
    finalImageTag = "v${version}";
    os = "linux";
    arch = "amd64";
  };

  cephadmZipapp = pkgs.fetchurl {
    url = "https://download.ceph.com/rpm-${version}/el9/noarch/cephadm";
    hash = "sha256-9JTvZ2AfWIjXLdJrT4zJQcyG3qxpMA6LgWB4eNBRtRY=";
  };

  cephadm = pkgs.writeShellScriptBin "cephadm" ''
    exec ${pkgs.python3}/bin/python3 -s ${cephadmZipapp} "$@"
  '';

  registry = "node1:5000";
  image = "${registry}/ceph/ceph:v${version}";

  # The nixos-cloudinit base, minus what a VM test cannot provide.
  base =
    hostName:
    { lib, ... }:
    {
      imports = [ nixos-cloudinit.nixosModules.default ];
      # No datasource in the test; cloud-init would set the hostname.
      services.cloud-init.enable = lib.mkForce false;
      networking.hostName = lib.mkForce hostName;
      # The test VM has no partition table to grow.
      boot.growPartition = lib.mkForce false;
      system.stateVersion = "26.05";
    };

  # Mechanism (b): a persistent overlay on /etc/systemd/system.
  # /etc/systemd/system is a symlink into the store (classic /etc and etc overlay alike), so
  # cephadm cannot write its units there. Each activation drops the overlay before setup-etc,
  # lets setup-etc place its symlink, then replaces it with an overlay: lower = a copy of this
  # generation's unit dir, upper = persistent dir holding what cephadm wrote.
  unitOverlay =
    { pkgs, ... }:
    let
      state = "/var/lib/ceph-nix/systemd-units";
      path = lib.makeBinPath [
        pkgs.coreutils
        pkgs.util-linux
      ];
    in
    {
      system.activationScripts.cephadmUnitDirPre = {
        deps = [ "specialfs" ];
        text = ''
          (
            PATH=${path}
            if mountpoint -q /etc/systemd/system; then
              umount /etc/systemd/system || umount -l /etc/systemd/system
            fi
            if [ -d /etc/systemd/system ] && [ ! -L /etc/systemd/system ]; then
              rmdir /etc/systemd/system
            fi
          )
        '';
      };
      system.activationScripts.etc.deps = [ "cephadmUnitDirPre" ];
      system.activationScripts.cephadmUnitDir = {
        deps = [ "etc" ];
        text = ''
          (
            PATH=${path}
            set -e
            mkdir -p ${state}/upper ${state}/work /run/ceph-nix
            lower=$(mktemp -d /run/ceph-nix/units-lower.XXXXXX)
            cp -a "$(readlink -f /etc/systemd/system)/." "$lower/"
            rm /etc/systemd/system
            mkdir /etc/systemd/system
            mount -t overlay overlay \
              -o lowerdir="$lower",upperdir=${state}/upper,workdir=${state}/work /etc/systemd/system
            for d in /run/ceph-nix/units-lower.*; do
              [ "$d" = "$lower" ] || rm -rf "$d"
            done
            # switch-to-configuration stops active units whose file is in /etc/systemd/system but
            # not in the new generation. Mark cephadm's units so a switch leaves the daemons alone.
            for f in ${state}/upper/ceph*.service ${state}/upper/ceph*.target; do
              [ -f "$f" ] || continue
              n=$(basename "$f")
              mkdir -p "/etc/systemd/system/$n.d"
              printf '[Unit]\nX-StopOnRemoval=false\n' > "/etc/systemd/system/$n.d/90-nixos-keep.conf"
            done
          ) || _localstatus=$?
        '';
      };
    };

  cephHost =
    { pkgs, ... }:
    {
      imports = [ unitOverlay ];

      environment.systemPackages = [
        cephadm
        pkgs.lvm2
        pkgs.python3
      ];

      virtualisation.podman.enable = true;
      virtualisation.containers.registries.insecure = [ registry ];
      services.chrony.enable = true;

      # The orchestrator logs in as root with a key; the cloudinit base forbids root login.
      services.openssh.settings.PermitRootLogin = lib.mkForce "prohibit-password";

      # cephadm's units hardcode /bin/bash and /bin/rm; the mgr runs its copied cephadm zipapp
      # directly, so its shebang (#!/usr/bin/python3 -s) must resolve.
      systemd.tmpfiles.rules = [
        "L+ /bin/bash - - - - ${pkgs.bash}/bin/bash"
        "L+ /bin/rm - - - - ${pkgs.coreutils}/bin/rm"
        "L+ /usr/bin/python3 - - - - ${pkgs.python3}/bin/python3"
        # Every cephadm invocation writes /etc/logrotate.d/cephadm and fails if the dir is missing.
        "d /etc/logrotate.d 0755 root root - -"
        # ceph-volume runs LVM tools on the host via nsenter, looking them up only in
        # /usr/local/bin, /bin, /usr/bin, /usr/local/sbin, /usr/sbin and /sbin, probing with /bin/ls.
        "L+ /bin/ls - - - - ${pkgs.coreutils}/bin/ls"
        "L+ /usr/sbin - - - - ${lib.getBin pkgs.lvm2}/bin"
      ];
      # cephadm units read EnvironmentFile=-/etc/environment; their ExecStop runs `bash` from PATH,
      # which systemd's default PATH on NixOS lacks. NixOS's pam_env does not read this file.
      environment.etc."environment".text = ''
        PATH=/run/wrappers/bin:/run/current-system/sw/bin
      '';

      # cephadm writes /etc/logrotate.d/{cephadm,ceph-<fsid>}; NixOS's logrotate ignores that dir.
      services.logrotate.settings.header.include = "/etc/logrotate.d";
      services.logrotate.checkConfig = false; # the build sandbox has no /etc/logrotate.d
      services.logrotate.enable = true;

      # Test VMs ship without switch-to-configuration; the spike needs it.
      system.switch.enable = true;

      networking.firewall.allowedTCPPorts = [
        3300 # mon v2
        6789 # mon v1
        8443 # dashboard
        8765 # mgr service discovery
        9283 # mgr prometheus
        9926 # ceph-exporter
      ];
      networking.firewall.allowedTCPPortRanges = [
        {
          from = 6800;
          to = 7300;
        }
      ];

      virtualisation = {
        cores = 2;
        memorySize = 5120;
        diskSize = 16384;
        emptyDiskImages = [
          10240
          10240
          10240
        ];
      };
    };
in
pkgs.testers.runNixOSTest {
  name = "cephadm-spike";
  globalTimeout = 4 * 3600;
  meta.timeout = 4 * 3600;
  skipTypeCheck = true;

  nodes = {
    # Mechanism (0): plain NixOS, classic /etc.
    plain = {
      imports = [ (base "plain") ];
      virtualisation.memorySize = 1024;
    };
    # Mechanism (a): mutable etc overlay.
    etcoverlay = {
      imports = [ (base "etcoverlay") ];
      boot.initrd.systemd.enable = true;
      system.etc.overlay.enable = true;
      system.etc.overlay.mutable = true;
      virtualisation.memorySize = 1024;
    };
    node1 = {
      imports = [
        (base "node1")
        cephHost
      ];
      services.dockerRegistry = {
        enable = true;
        listenAddress = "0.0.0.0";
        port = 5000;
        openFirewall = true;
      };
      # No internet: node1 serves time to node2, or the mons see skew from the 1 s RTC.
      services.chrony.extraConfig = ''
        local stratum 10
        allow 192.168.1.0/24
      '';
      networking.firewall.allowedUDPPorts = [ 123 ];
    };
    node2 = {
      imports = [
        (base "node2")
        cephHost
      ];
      services.chrony.servers = [ "node1" ];
      services.chrony.extraConfig = "makestep 0.1 -1";
    };
  };

  testScript =
    { nodes, ... }:
    ''
      import json
      import time

      ip1 = "${nodes.node1.networking.primaryIPAddress}"
      ip2 = "${nodes.node2.networking.primaryIPAddress}"
      hosts = [node1, node2]


      def run(m, cmd, timeout=900):
          # stdin: `cephadm shell` runs podman -i, which otherwise waits on the test backdoor's stdin
          rc, out = m.execute(f"( {cmd} ) </dev/null 2>&1", timeout=timeout)
          print(f"[{m.name}] $ {cmd}\n[rc={rc}]\n{out}")
          return rc, out


      def ok(m, cmd, timeout=900):
          rc, out = run(m, cmd, timeout)
          assert rc == 0, f"{m.name}: '{cmd}' failed"
          return out


      def ceph(cmd, timeout=600):
          return ok(node1, f"cephadm shell -- ceph {cmd}", timeout)


      def ceph_json(cmd):
          rc, out = node1.execute(f"cephadm shell -- ceph {cmd} -f json </dev/null 2>/dev/null", timeout=600)
          assert rc == 0, f"ceph {cmd} failed"
          return json.loads(out.strip().splitlines()[-1])


      def diagnostics():
          for c in ["health detail", "orch ps", "orch device ls", "osd tree", "log last 100 cephadm"]:
              run(node1, f"cephadm shell -- ceph {c}", 600)
          for m in hosts:
              run(m, "systemctl list-units 'ceph*' --all --no-pager")
              run(m, "journalctl -u 'ceph*' --no-pager -n 150")


      def wait_healthy(osds=6, timeout=2400):
          start = time.time()
          last = None
          while time.time() - start < timeout:
              rc, out = node1.execute("cephadm shell -- ceph -s -f json </dev/null 2>/dev/null", timeout=600)
              if rc == 0:
                  s = json.loads(out.strip().splitlines()[-1])
                  health = s["health"]["status"]
                  om = s["osdmap"]
                  pgs = s["pgmap"].get("pgs_by_state", [])
                  summary = (health, om["num_osds"], om["num_up_osds"], om["num_in_osds"],
                             sorted(s["health"].get("checks", {}).keys()), pgs)
                  if summary != last:
                      print(f"[{int(time.time() - start)}s] {summary}")
                      last = summary
                  if health == "HEALTH_OK" and om["num_up_osds"] == osds and om["num_in_osds"] == osds:
                      return
              time.sleep(20)
          diagnostics()
          raise Exception(f"cluster not HEALTH_OK with {osds} OSDs after {timeout}s")


      def osds_per_host():
          tree = ceph_json("osd tree")
          return {n["name"]: len(n.get("children", [])) for n in tree["nodes"] if n["type"] == "host"}


      def daemon_starts(m):
          # unit -> (MainPID, ActiveEnterTimestampMonotonic) of every cephadm daemon unit
          out = m.succeed(
              "systemctl list-units 'ceph-*@*.service' --plain --no-legend --state=active | awk '{print $1}'"
          ).split()
          res = {}
          for u in out:
              res[u] = m.succeed(f"systemctl show -p MainPID -p ActiveEnterTimestampMonotonic --value {u}").split()
          return res


      def switch(m):
          before = daemon_starts(m)
          rc, out = run(m, "/run/current-system/bin/switch-to-configuration test", 900)
          # rc 4 = only the root *user* manager failed to reload (the orchestrator's ssh sessions keep
          # one alive); unrelated to the system units checked here.
          assert rc == 0 or (rc == 4 and "user activation for root failed" in out), rc
          time.sleep(30)
          after = daemon_starts(m)
          restarted = sorted(u for u in before if before[u] != after.get(u))
          missing = sorted(u for u in before if u not in after)
          print(f"[{m.name}] switch: {len(before)} daemons, restarted={restarted}, not active={missing}")
          if missing:
              run(m, "systemctl start ceph.target")
          ok(m, "ls /etc/systemd/system/ | grep -E '^ceph'")
          return restarted, missing


      # ---------------------------------------------------------------- mechanisms (0) and (a)
      with subtest("mechanisms (0) plain /etc and (a) mutable etc overlay"):
          for m in [plain, etcoverlay]:
              m.start()
          for m in [plain, etcoverlay]:
              m.wait_for_unit("multi-user.target")
              run(m, "ls -ld /etc/systemd/system; readlink -f /etc/systemd/system; findmnt -T /etc")
              rc, _ = run(m, "printf '[Unit]\\n' > /etc/systemd/system/cephadm-probe.service")
              print(f"RESULT mechanism {m.name}: unit dir writable = {rc == 0}")
              run(m, "ls -ld /etc/sysctl.d /usr/lib/sysctl.d /etc/logrotate.d /etc/ceph /bin/bash /usr/bin/python3")
              m.shutdown()

      # ---------------------------------------------------------------- hosts
      with subtest("host facts"):
          for m in hosts:
              m.start()
          for m in hosts:
              m.wait_for_unit("multi-user.target")
              m.wait_for_unit("sshd.service")
              ok(m, "findmnt /etc/systemd/system")
              ok(m, "touch /etc/systemd/system/.probe && rm /etc/systemd/system/.probe")
              run(m, "ls -l /bin/bash /bin/rm /usr/bin/python3 /etc/environment")
              run(m, "ls -ld /etc/sysctl.d /usr/lib/sysctl.d /etc/logrotate.d /etc/ceph")
              run(m, "systemctl is-enabled chronyd; systemctl is-active chronyd; chronyc tracking")
              run(m, "systemd-run --wait --pipe /bin/bash -c 'command -v bash || echo NO_BASH_IN_SYSTEMD_PATH'")
              run(m, "systemd-run --wait --pipe -p EnvironmentFile=-/etc/environment /bin/bash -c 'command -v bash'")
              run(m, "lsblk")

      with subtest("non-interactive root ssh, as the orchestrator uses it"):
          ok(node1, "mkdir -p /root/.ssh && ssh-keygen -q -t ed25519 -N ''' -f /root/.ssh/id_ed25519")
          pub = node1.succeed("cat /root/.ssh/id_ed25519.pub").strip()
          for m in hosts:
              m.succeed(f"mkdir -p /root/.ssh && echo '{pub}' >> /root/.ssh/authorized_keys")
          for target in ["node1", "node2"]:
              ok(node1, f"ssh -o StrictHostKeyChecking=no -o BatchMode=yes root@{target} "
                 "'echo PATH=$PATH; for c in podman python3 lvcreate chronyc systemctl sysctl ls chmod mv touch; "
                 "do command -v $c || echo MISSING $c; done; /usr/bin/python3 -s --version'")
              ok(node1, f"ssh -o BatchMode=yes root@{target} cephadm check-host")

      with subtest("registry with the upstream image"):
          node1.wait_for_unit("docker-registry.service")
          node1.wait_for_open_port(5000)
          ok(node1, "podman load -i ${cephImage}", 1800)
          ok(node1, "podman tag quay.io/ceph/ceph:v${version} ${image}")
          ok(node1, "podman push --tls-verify=false ${image}", 1800)
          # Re-pull so the local RepoDigest is the registry's: cephadm pins that digest for other hosts.
          ok(node1, "podman rmi quay.io/ceph/ceph:v${version} ${image} && podman pull ${image}", 1800)

      try:
          with subtest("bootstrap"):
              ok(node1, f"cephadm --image ${image} bootstrap --mon-ip {ip1} --single-host-defaults "
                 "--skip-monitoring-stack --initial-dashboard-password spike-pass --dashboard-password-noupdate",
                 3600)
              ceph("-s")
              ceph("config set osd osd_memory_target 939524096")
              run(node1, "ls -la /etc/systemd/system/ /var/lib/ceph-nix/systemd-units/upper")

          with subtest("host add and OSDs"):
              cpub = node1.succeed("cat /etc/ceph/ceph.pub").strip()
              node2.succeed(f"echo '{cpub}' >> /root/.ssh/authorized_keys")
              ceph(f"orch host add node2 {ip2}")
              ceph("orch apply osd --all-available-devices")
              wait_healthy()
              per_host = osds_per_host()
              print(f"RESULT OSDs per host: {per_host}")
              assert per_host.get("node1", 0) > 0 and per_host.get("node2", 0) > 0, per_host
              ceph("orch ps")
              ceph("health detail")

          with subtest("host paths cephadm wrote"):
              for m in hosts:
                  run(m, "ls -la /etc/systemd/system/ | grep -i ceph; ls -R /var/lib/ceph-nix/systemd-units/upper")
                  run(m, "ls -la /etc/sysctl.d /etc/logrotate.d /etc/ceph; cat /etc/sysctl.d/*ceph* || true")
                  run(m, "sysctl fs.aio-max-nr kernel.pid_max")
                  run(m, "systemctl start logrotate.service; systemctl status logrotate.service --no-pager")
                  run(m, "cat /etc/systemd/system/ceph-*@.service")

          with subtest("switch-to-configuration before any drop-in exists"):
              for m in [node2, node1]:
                  switch(m)
              wait_healthy()

          with subtest("reboot"):
              node2.shutdown()
              node1.shutdown()
              node1.start()
              node2.start()
              for m in hosts:
                  m.wait_for_unit("multi-user.target")
              wait_healthy()
              for m in hosts:
                  run(m, "systemctl list-units 'ceph*' --no-pager; sysctl fs.aio-max-nr kernel.pid_max")
                  run(m, "systemctl list-units --failed --no-pager")
                  run(m, "journalctl -b -1 -u 'ceph-*' --no-pager | grep -iE 'not found|No such file' | head -20")

          with subtest("switch-to-configuration with drop-ins"):
              for m in hosts:
                  run(m, "ls -d /etc/systemd/system/ceph*.d; cat /etc/systemd/system/ceph.target.d/*")
              for m in [node2, node1]:
                  restarted, missing = switch(m)
                  assert not restarted and not missing, (restarted, missing)
              wait_healthy()
              for m in hosts:
                  ok(m, "systemctl list-units 'ceph-*@*.service' --no-pager --state=active")
      except Exception:
          diagnostics()
          raise
    '';
}
