# VM test for nixosModules.ceph-host (ADR 0004, 0006): two nodes on the nixos-cloudinit base run Ceph
# through cephadm. Bootstrap, OSDs on both hosts, rbd/cephfs/EC I/O, a switch-to-configuration that
# must not restart any daemon, a reboot of both nodes, and an OSD on an LV on an Open CAS device. Also the services
# of tests/cephadm.sh on a CPU without AVX2 (rgw with S3, NFS and iSCSI from the other node, dashboard REST API,
# rbd-mirror, cephfs-mirror, ceph-exporter), checked again after the reboot.
#
# Slow (about 42 to 52 minutes, 2 GB image), so it is a package run by .github/workflows/vm-tests.yml, not a check.
{
  pkgs,
  self,
  nixos-cloudinit,
  opencas-nix,
  # Run the pinned upstream release instead of our image. It needs AVX2, so the CPU is not masked, and the
  # cephadm of this repo (Ceph 20) is not the image's; best effort, not run in CI.
  upstream ? false,
  # Which of the flake's Ceph tracks to run: tentacle or umbrella.
  track ? "tentacle",
}:

let
  inherit (pkgs) lib;

  common = import ./common.nix { inherit pkgs; };
  inherit (common) imageInfo upstreamImage;

  packages = self.packages.x86_64-linux;
  cephPkg = packages."ceph-${track}";
  ours = packages."ceph-image-${track}";
  cephadm = packages."cephadm-${track}";

  imageVersion = if upstream then lib.removePrefix "v" imageInfo.tag else cephPkg.version;
  # Ceph 20 (Tentacle) and later create AES256KRB5 keys by default (seen on 20.2.4: the key starts with "Ag")
  # and the mons only allow that cipher, which the kernel client cannot use (see kernel_key). Older releases do not need the workaround.
  aesWorkaround = lib.versionAtLeast imageVersion "20";

  # load the image into the VM's podman, and the name:tag it carries
  loadImage =
    if upstream then
      "podman load -i ${upstreamImage}"
    else if track == "tentacle" then
      "set -o pipefail; ${ours} | podman load"
    else
      "podman load -i ${common.imageTar ours}";
  imageSource =
    if upstream then "${imageInfo.image}:${imageInfo.tag}" else "localhost/ceph-nix:${imageVersion}";
  timeoutHours = if track == "tentacle" then 4 else 8;
  cpu = if upstream then "host" else common.maskedCpu;

  registry = "node1:5000";
  image = "${registry}/ceph/ceph:test";

  keys = import "${pkgs.path}/nixos/tests/ssh-keys.nix" pkgs;

  # Writes and reads a file through libcephfs inside the cephadm shell container.
  fsioScript = pkgs.writeText "fsio.py" ''
    import glob
    import hashlib
    import sys

    import cephfs

    keyring = (glob.glob("/etc/ceph/ceph.keyring") + glob.glob("/etc/ceph/ceph.client.admin.keyring"))[0]
    fs = cephfs.LibCephFS(conffile="/etc/ceph/ceph.conf", conf={"keyring": keyring})
    fs.mount()
    if sys.argv[1] == "write":
        data = open("/etc/ceph/ceph.conf", "rb").read() * 200
        fd = fs.open("/ufile", "w", 0o644)
        fs.write(fd, data, 0)
        fs.close(fd)
    else:
        size = fs.stat("/ufile").st_size
        fd = fs.open("/ufile", "r")
        data = fs.read(fd, 0, size)
        fs.close(fd)
    print(hashlib.md5(data).hexdigest())
    fs.unmount()
  '';

  # S3 client for the VM (boto3 is not in the image's python): create bucket, put and get, or just get.
  s3py = pkgs.python3.withPackages (ps: [ ps.boto3 ]);
  s3check = pkgs.writeScriptBin "s3check" ''
    #!${s3py}/bin/python3
    import hashlib
    import sys

    import boto3
    from botocore.config import Config

    url, op = sys.argv[1], sys.argv[2]
    # newer botocore adds checksum trailers by default; only send them where required
    cfg = Config(request_checksum_calculation="when_required", response_checksum_validation="when_required")
    s3 = boto3.client("s3", endpoint_url=url, aws_access_key_id="AKIATEST", aws_secret_access_key="SECRETTEST",
                      region_name="us-east-1", config=cfg)
    body = b"hello rgw " * 100000
    if op == "put":
        s3.create_bucket(Bucket="testbucket")
        s3.put_object(Bucket="testbucket", Key="k", Body=body)
    data = s3.get_object(Bucket="testbucket", Key="k")["Body"].read()
    assert data == body, len(data)
    print(hashlib.md5(data).hexdigest())
  '';

  # iSCSI initiator name of node1 (the client); node2 hosts the gateway
  initiator = "iqn.2004-10.org.nixos:node1";

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

  disk = serial: size: {
    inherit size;
    driveConfig.deviceExtraOpts.serial = serial;
  };

  host = {
    imports = [ self.nixosModules.ceph-host ];
    services.ceph-host = {
      enable = true;
      inherit image;
      cephadmPackage = cephadm.host;
      orchestratorKeys = [ keys.snakeOilPublicKey ];
    };
    virtualisation.containers.registries.insecure = [ registry ];
    # Test VMs ship without switch-to-configuration.
    system.switch.enable = true;
    virtualisation = {
      cores = 2;
      memorySize = 5120;
      diskSize = 24576; # the image is loaded, pushed to the registry and pulled
      qemu.options = lib.mkAfter [ "-cpu ${cpu}" ];
    };
  };
in
pkgs.testers.runNixOSTest {
  name = "ceph-host";
  # the Umbrella image is larger and the build VM slower than a CI runner: it took 2 h to get to the first I/O
  globalTimeout = timeoutHours * 3600;
  meta.timeout = timeoutHours * 3600;
  skipTypeCheck = true;
  node.pkgsReadOnly = false; # the opencas module adds its overlay

  nodes = {
    node1 = {
      imports = [
        (base "node1")
        host
      ];
      # mounts cephfs and maps rbd images
      services.ceph-host.clientKernelModules = true;
      # S3 and iSCSI client (the rgw and the iSCSI gateway run on node2), and Ganesha's port (NFS runs on node1)
      environment.systemPackages = [
        s3check
        pkgs.curl
      ];
      services.openiscsi = {
        enable = true;
        name = initiator;
      };
      boot.kernelModules = [ "iscsi_tcp" ];
      networking.firewall.allowedTCPPorts = [ 2049 ];
      virtualisation.emptyDiskImages = [
        (disk "N1OSD1" 8192)
        (disk "N1OSD2" 8192)
        (disk "N1OSD3" 8192)
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
        host
        opencas-nix.nixosModules.opencas
      ];
      virtualisation.emptyDiskImages = [
        (disk "N2OSD1" 8192)
        (disk "N2OSD2" 8192)
        (disk "CASCACHE" 2048)
        (disk "CASCORE" 8192)
      ];
      services.opencas = {
        enable = true;
        initializeBlankCaches = true;
        settleTimeout = 120;
        caches."1" = {
          device = "/dev/disk/by-id/virtio-CASCACHE";
          mode = "wb";
          cores = [ "/dev/disk/by-id/virtio-CASCORE" ];
        };
      };
      # NFS client (Ganesha runs on node1); the kernel modules and ports are for the iSCSI gateway and the rgw
      boot.supportedFilesystems = [ "nfs" ];
      boot.kernelModules = [
        "target_core_user"
        "iscsi_target_mod"
      ];
      networking.firewall.allowedTCPPorts = [
        3260 # iSCSI
        5001 # rbd-target-api
        8080 # rgw
      ];
      environment.systemPackages = [ pkgs.curl ];
      # rgw, iSCSI gateway (with tcmu-runner), rbd-mirror and cephfs-mirror run here besides three OSDs
      virtualisation.memorySize = lib.mkForce 6144;
      services.chrony.servers = [ "node1" ];
      services.chrony.extraConfig = "makestep 0.1 -1";
    };
  };

  testScript =
    { nodes, ... }:
    ''
      import json
      import re
      import time

      ip1 = "${nodes.node1.networking.primaryIPAddress}"
      ip2 = "${nodes.node2.networking.primaryIPAddress}"
      hosts = [node1, node2]
      AES_WORKAROUND = ${if aesWorkaround then "True" else "False"}


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


      def quiet(cmd, timeout=600):
          # stdout only: cephadm shell chatters on stderr
          return node1.succeed(f"cephadm shell -- {cmd} </dev/null 2>/dev/null", timeout=timeout).strip()


      def ceph_status():
          rc, out = node1.execute("cephadm shell -- ceph -s -f json </dev/null 2>/dev/null", timeout=600)
          return json.loads(out.strip().splitlines()[-1]) if rc == 0 else None


      def diagnostics():
          for c in ["health detail", "orch ps", "orch device ls", "osd tree", "log last 100 cephadm"]:
              run(node1, f"cephadm shell -- ceph {c}", 600)
          for m in hosts:
              run(m, "systemctl list-units 'ceph*' --all --no-pager")
              run(m, "journalctl -u 'ceph*' --no-pager -n 150")


      def jsonq(cmd):
          out = quiet(cmd)
          try:
              return json.loads(out)
          except ValueError:
              return json.loads(out.splitlines()[-1])


      def wait_until(what, fn, timeout=300, interval=10):
          deadline = time.time() + timeout
          while True:
              try:
                  if fn():
                      return
              except Exception as e:
                  print(f"{what}: {e}")
              if time.time() > deadline:
                  raise Exception(f"timeout waiting for {what}")
              time.sleep(interval)


      # Ceph 21.2.0 registers Ganesha in the service map as nfs-ganesha/nfs.<rank>, which cephadm's stray check never
      # matches, so after every mgr start it raises CEPHADM_STRAY_DAEMON for it (see known_stray in tests/lib.sh).
      KNOWN_STRAY = re.compile(r"^stray daemon nfs-ganesha[.]nfs[.][0-9]+ on host ")


      def only_known_stray():
          for name, c in jsonq("ceph health detail -f json").get("checks", {}).items():
              if c.get("muted"):
                  continue
              msgs = [d["message"] for d in c.get("detail", [])]
              if name != "CEPHADM_STRAY_DAEMON" or not msgs or not all(KNOWN_STRAY.match(m) for m in msgs):
                  return False
          return True


      def wait_healthy(osds, timeout=2400, fatal=True):
          start = time.time()
          last = None
          while time.time() - start < timeout:
              s = ceph_status()
              if s:
                  health = s["health"]["status"]
                  om = s["osdmap"]
                  summary = (health, om["num_osds"], om["num_up_osds"], om["num_in_osds"],
                             sorted(s["health"].get("checks", {}).keys()), s["pgmap"].get("pgs_by_state", []))
                  if summary != last:
                      print(f"[{int(time.time() - start)}s] {summary}")
                      last = summary
                  if om["num_up_osds"] == osds and om["num_in_osds"] == osds and (
                      health == "HEALTH_OK" or (health == "HEALTH_WARN" and only_known_stray())
                  ):
                      return True
              time.sleep(20)
          if fatal:
              diagnostics()
              raise Exception(f"cluster not HEALTH_OK with {osds} OSDs after {timeout}s")
          return False


      def osds_per_host():
          tree = json.loads(quiet("ceph osd tree -f json").splitlines()[-1])
          return {n["name"]: len(n.get("children", [])) for n in tree["nodes"] if n["type"] == "host"}


      def dev(m, serial):
          return m.succeed(f"readlink -f /dev/disk/by-id/virtio-{serial}").strip()


      def invocations(m):
          units = m.succeed(
              "systemctl list-units 'ceph-*@*.service' --plain --no-legend --state=active | awk '{print $1}'"
          ).split()
          assert units, "no active ceph daemon units"
          return {u: m.succeed(f"systemctl show -p InvocationID --value {u}").strip() for u in units}


      def switch(m):
          before = invocations(m)
          rc, out = run(m, "/run/current-system/bin/switch-to-configuration test", 900)
          # rc 4: only the root *user* manager failed to reload (the orchestrator's ssh sessions keep one
          # alive); unrelated to the system units checked here.
          assert rc == 0 or (rc == 4 and "user activation for root failed" in out), rc
          time.sleep(30)
          after = invocations(m)
          restarted = sorted(u for u in before if before[u] != after.get(u))
          gone = sorted(u for u in before if u not in after)
          print(f"[{m.name}] switch: {len(before)} daemons, restarted={restarted}, gone={gone}")
          assert not restarted and not gone, (restarted, gone)
          ok(m, "findmnt /etc/systemd/system && ls /etc/systemd/system | grep -E '^ceph'")


      # Userspace clients inside the cephadm shell container: the baseline I/O check.
      fsio = "cephadm shell -m /var/tmp:/hostvar -- python3 /hostvar/fsio.py"


      def rbd_user_write():
          # not ceph.conf: each `cephadm shell` generates it, and it changes while the second mon is deployed
          ok(node1, "cephadm shell -- rbd import /etc/os-release rbd/uimg")
          return quiet("md5sum /etc/os-release").split()[0]


      def rbd_user_read():
          return quiet("bash -c 'rbd export rbd/uimg - | md5sum'").split()[0]


      def cephfs_user(op):
          return node1.succeed(f"{fsio} {op} </dev/null 2>/dev/null").strip()


      # Kernel clients. On Ceph 20 and later (AES_WORKAROUND) the default AES256KRB5 keys are unusable for the kernel
      # client: this enables the legacy `aes` cipher cluster-wide, creates an aes key for the client and mutes the
      # mon's warning about it. Older releases get a plain key.
      def kernel_key():
          if AES_WORKAROUND:
              ceph("mon set auth_allowed_ciphers aes,aes256k")
          key_type = "--key_type aes" if AES_WORKAROUND else ""
          # the mons take a moment to apply the new cipher list
          for attempt in range(12):
              rc, out = node1.execute(
                  "cephadm shell -- ceph auth get-or-create-key client.kern mon 'allow *' osd 'allow *' "
                  f"mds 'allow *' {key_type} </dev/null 2>/dev/null", timeout=600)
              if rc == 0:
                  break
              time.sleep(10)
          key = out.strip()
          assert key.startswith("AQ"), key
          if AES_WORKAROUND:
              for code in ["AUTH_INSECURE_KEYS_ALLOWED", "AUTH_INSECURE_KEYS_CREATABLE", "AUTH_INSECURE_CLIENT_KEY_TYPE"]:
                  ceph(f"health mute {code} --sticky")
          return key


      def map_rbd(key):
          rc, _ = run(node1, f"echo '{ip1}:6789 name=kern,secret={key} rbd test' > /sys/bus/rbd/add_single_major")
          if rc != 0:
              run(node1, "dmesg | grep -iE 'libceph|rbd' | tail -40")
              run(node1, "cephadm shell -- ceph auth get client.kern")
              raise Exception("rbd map failed")
          node1.succeed("udevadm settle; test -b /dev/rbd0")


      def mount_cephfs(key):
          node1.succeed("mkdir -p /mnt/cephfs")
          rc, _ = run(node1, f"mount -t ceph {ip1}:6789:/ /mnt/cephfs -o name=kern,secret={key}")
          if rc != 0:
              run(node1, "dmesg | grep -iE 'libceph|ceph:' | tail -40")
              raise Exception("cephfs mount failed")


      def unmount_clients():
          run(node1, "umount /mnt/cephfs; echo 0 > /sys/bus/rbd/remove_single_major")


      # Services of tests/cephadm.sh. Placement: Ganesha on node1 (client: node2), rgw and the iSCSI gateway on
      # node2 (clients: node1), so the traffic crosses the network and the memory is spread.
      RGW_URL = f"http://{ip2}:8080"
      NFS_PSEUDO = "/cephfs"
      ISCSI_IQN = "iqn.2001-07.com.ceph:test"
      INITIATOR = "${initiator}"
      ISCSI_API = "http://admin:admin@127.0.0.1:5001/api"


      def running(dtype):
          try:
              ps = jsonq(f"ceph orch ps --daemon-type {dtype} -f json")
          except ValueError:  # "No daemons reported"
              return []
          return [d for d in ps if d.get("status_desc") == "running"]


      def wait_running(dtype, timeout=600):
          try:
              wait_until(f"{dtype} running", lambda: running(dtype), timeout)
          except Exception:
              run(node1, f"cephadm shell -- ceph orch ps --daemon-type {dtype}")
              raise


      def daemons_running():
          for t in ["rgw", "nfs", "iscsi", "rbd-mirror", "cephfs-mirror", "ceph-exporter"]:
              wait_running(t)


      def s3(op):
          return node1.succeed(f"s3check {RGW_URL} {op}").strip()


      def nfs_mount():
          node2.succeed("mkdir -p /mnt/nfs")
          node2.succeed(f"timeout 60 mount -t nfs -o nfsvers=4.1,proto=tcp,retry=0 {ip1}:{NFS_PSEUDO} /mnt/nfs")


      def nfs_check(write):
          # Ganesha picks a new export up through its RADOS watch and sits in its grace period after a start
          wait_until("nfs mount", lambda: nfs_mount() or True, 300)
          if write:
              node2.succeed("dd if=/dev/urandom of=/mnt/nfs/nfsfile bs=1M count=32 conv=fsync status=none")
              node2.succeed("md5sum < /mnt/nfs/nfsfile > /var/tmp/nfs.md5")
              node2.succeed("umount /mnt/nfs")
              nfs_mount()
          out = node2.succeed("md5sum < /mnt/nfs/nfsfile")
          assert out == node2.succeed("cat /var/tmp/nfs.md5"), out
          node2.succeed("umount /mnt/nfs")


      def iscsi_api(method, path, *data):
          # the REST API answers with a JSON message and an HTTP status; show both, fail on 4xx/5xx
          form = " ".join(f"-d {d}" for d in data)
          rc, out = run(node2, f"curl -s -w '\\n%{{http_code}}' -X {method} {form} {ISCSI_API}/{path}")
          assert rc == 0 and int(out.strip().splitlines()[-1]) < 400, f"{method} /api/{path}"


      def iscsi_login():
          ok(node1, f"iscsiadm -m node -T {ISCSI_IQN} -p {ip2}:3260 --login", 300)
          for attempt in range(30):
              dev = node1.succeed("lsblk -dn -o NAME,TRAN | awk '$2 == \"iscsi\" {print \"/dev/\" $1}' | head -n1").strip()
              if dev:
                  return dev
              time.sleep(2)
          run(node1, "lsblk -o NAME,TRAN,SIZE,TYPE; iscsiadm -m session -P3; dmesg | tail -n 40")
          raise Exception("no iscsi disk appeared")


      def iscsi_logout():
          ok(node1, f"iscsiadm -m node -T {ISCSI_IQN} -p {ip2}:3260 --logout")


      def iscsi_verify():
          dev = iscsi_login()
          node1.succeed(f"mkdir -p /mnt/iscsi && mount {dev} /mnt/iscsi")
          out = node1.succeed("md5sum < /mnt/iscsi/file")
          assert out == node1.succeed("cat /var/tmp/iscsi.md5"), out
          node1.succeed("umount /mnt/iscsi")
          iscsi_logout()


      def iscsi_setup():
          ceph("osd pool create iscsi 1")
          ok(node1, "cephadm shell -- rbd pool init iscsi")
          node1.succeed(
              "printf '%s\\n' 'service_type: iscsi' 'service_id: gw' 'placement:' '  hosts: [node2]' 'spec:' "
              "'  pool: iscsi' '  api_user: admin' '  api_password: admin' '  api_secure: false' "
              f"'  api_port: 5001' '  trusted_ip_list: \"127.0.0.1,{ip1},{ip2}\"' > /var/tmp/iscsi.yaml"
          )
          ok(node1, "cephadm shell -m /var/tmp:/hostvar -- ceph orch apply -i /hostvar/iscsi.yaml")
          wait_running("iscsi")
          wait_until("gateway API", lambda: node2.succeed(f"curl -sf {ISCSI_API}/sysinfo/ip_addresses"), 180)
          # the gateway is named by the API process's own FQDN
          gw = json.loads(node2.succeed(f"curl -sf {ISCSI_API}/sysinfo/hostname"))["data"]
          iscsi_api("PUT", f"target/{ISCSI_IQN}")
          iscsi_api("PUT", f"gateway/{ISCSI_IQN}/{gw}", f"ip_address={ip2}", "skipchecks=true")
          iscsi_api("PUT", "disk/iscsi/img", "mode=create", "size=1G")
          iscsi_api("PUT", f"targetlun/{ISCSI_IQN}", "disk=iscsi/img")
          iscsi_api("PUT", f"client/{ISCSI_IQN}/{INITIATOR}")
          iscsi_api("PUT", f"clientlun/{ISCSI_IQN}/{INITIATOR}", "disk=iscsi/img")
          iscsi_api("PUT", f"clientauth/{ISCSI_IQN}/{INITIATOR}", "username=testuser12", "password=testpass1234")


      def iscsi_io():
          ok(node1, f"iscsiadm -m discovery -t sendtargets -p {ip2}:3260")
          for k, v in [("authmethod", "CHAP"), ("username", "testuser12"), ("password", "testpass1234")]:
              ok(node1, f"iscsiadm -m node -T {ISCSI_IQN} -p {ip2}:3260 -o update -n node.session.auth.{k} -v {v}")
          dev = iscsi_login()
          node1.succeed(f"mkfs.ext4 -q {dev} && mkdir -p /mnt/iscsi && mount {dev} /mnt/iscsi")
          node1.succeed("dd if=/dev/urandom of=/mnt/iscsi/file bs=1M count=16 conv=fsync status=none")
          node1.succeed("md5sum < /mnt/iscsi/file > /var/tmp/iscsi.md5")
          node1.succeed("umount /mnt/iscsi")
          iscsi_logout()
          # a fresh login reads it back; the data went through tcmu-runner's rbd handler into the pool
          iscsi_verify()
          assert jsonq("rbd du iscsi/img --format json")["images"][0]["used_size"] > 0


      def dashboard_health():
          url = jsonq("ceph mgr services")["dashboard"]
          hdr = "-H 'Accept: application/vnd.ceph.api.v1.0+json' -H 'Content-Type: application/json'"
          body = json.dumps({"username": "apiuser", "password": "Dash-pass-1"})
          token = json.loads(node1.succeed(f"curl -sk --max-time 30 -X POST {hdr} -d '{body}' {url}api/auth"))["token"]
          full = json.loads(node1.succeed(
              f"curl -sk --max-time 60 {hdr} -H 'Authorization: Bearer {token}' {url}api/health/full"))
          print(f"dashboard health/full: {full['health']['status']}")
          assert len(full["osd_map"]["osds"]) == 6, full["osd_map"]


      def exporters():
          for m in hosts:
              out = m.succeed("curl -sf --max-time 20 http://127.0.0.1:9926/metrics")
              assert "\nceph_" in "\n" + out, out[:300]



      ec_md5 = lambda: quiet("bash -c 'rados -p ecpool get obj - | md5sum'")

      for m in hosts:
          m.start()
      for m in hosts:
          m.wait_for_unit("multi-user.target")
          m.wait_for_unit("sshd.service")
      node1.copy_from_host("${fsioScript}", "/var/tmp/fsio.py")

      ${lib.optionalString (!upstream) ''
        # first: the guests are v2-only, so everything below runs without AVX2
        for m in hosts:
            m.succeed("test $(grep -c avx2 /proc/cpuinfo) = 0")
      ''}

      try:
          with subtest("host facts"):
              for m in hosts:
                  ok(m, "findmnt /etc/systemd/system")
                  ok(m, "touch /etc/systemd/system/.probe && rm /etc/systemd/system/.probe")
                  ok(m, "test -x /bin/bash && test -x /bin/rm && test -x /bin/ls && test -x /usr/bin/python3")
                  ok(m, "test -x /usr/sbin/lvs && test -x /usr/sbin/vgcreate")
                  ok(m, "grep -qx 'PATH=/run/wrappers/bin:/run/current-system/sw/bin' /etc/environment")
                  ok(m, "test -d /etc/logrotate.d && systemctl is-active chronyd")
                  ok(m, "systemd-run --wait --pipe -p EnvironmentFile=-/etc/environment /bin/bash -c 'command -v bash'")
                  ok(m, "grep -i '^PermitRootLogin prohibit-password' /etc/ssh/sshd_config")
                  ok(m, "cat /etc/ceph-nix/image")
              ok(node1, "lsmod | grep -E '^(rbd|ceph) '")
              node2.fail("lsmod | grep -E '^(rbd|ceph) '")

          with subtest("orchestrator key reaches root's authorized_keys"):
              node1.succeed("install -d -m 700 /root/.ssh")
              node1.copy_from_host("${keys.snakeOilPrivateKey}", "/root/.ssh/id_ed25519")
              node1.succeed("chmod 600 /root/.ssh/id_ed25519")
              for target in ["node1", "node2"]:
                  ok(node1, f"ssh -o StrictHostKeyChecking=no -o BatchMode=yes root@{target} "
                     "'for c in podman python3 lvcreate chronyc systemctl sysctl; do command -v $c || echo MISSING $c; done'")
                  ok(node1, f"ssh -o BatchMode=yes root@{target} cephadm check-host")

          with subtest("registry with the image"):
              node1.wait_for_unit("docker-registry.service")
              node1.wait_for_open_port(5000)
              ok(node1, "${loadImage}", 3600)
              ok(node1, "podman tag ${imageSource} ${image}")
              ok(node1, "podman push --tls-verify=false ${image}", 3600)
              # Re-pull so the local RepoDigest is the registry's: cephadm pins that digest for other hosts.
              ok(node1, "podman rmi ${imageSource} ${image} && podman pull ${image}", 1800)

          with subtest("bootstrap"):
              ok(node1, f"cephadm --image $(cat /etc/ceph-nix/image) bootstrap --mon-ip {ip1} --single-host-defaults "
                 "--skip-monitoring-stack --initial-dashboard-password test-pass --dashboard-password-noupdate",
                 3600)
              ceph("-s")
              ceph("config set osd osd_memory_target 939524096")
              # The CI VMs have slow disks and links; these warnings come and go and say nothing about the host.
              for code in ["BLUESTORE_SLOW_OP_ALERT", "OSD_SLOW_PING_TIME_BACK", "OSD_SLOW_PING_TIME_FRONT"]:
                  ceph(f"health mute {code} --sticky")

          with subtest("host add and OSDs on both hosts"):
              cpub = node1.succeed("cat /etc/ceph/ceph.pub").strip()
              node2.succeed(f"mkdir -p /root/.ssh && echo '{cpub}' >> /root/.ssh/authorized_keys")
              ceph(f"orch host add node2 {ip2}")
              # Explicit devices: the cache disk of node2 carries no signature and would be taken by
              # --all-available-devices.
              for serial in ["N1OSD1", "N1OSD2", "N1OSD3"]:
                  ceph(f"orch daemon add osd node1:{dev(node1, serial)}")
              for serial in ["N2OSD1", "N2OSD2"]:
                  ceph(f"orch daemon add osd node2:{dev(node2, serial)}")
              wait_healthy(5)
              per_host = osds_per_host()
              print(f"RESULT OSDs per host: {per_host}")
              assert per_host == {"node1": 3, "node2": 2}, per_host
              ceph("orch ps")

          with subtest("rbd I/O (userspace)"):
              ceph("osd pool create rbd 16")
              ok(node1, "cephadm shell -- rbd pool init rbd")
              ok(node1, "cephadm shell -- rbd create rbd/test --size 128M --image-feature layering")
              rbd_md5 = rbd_user_write()
              assert rbd_user_read() == rbd_md5

          with subtest("cephfs I/O (userspace)"):
              ceph("fs volume create cephfs --placement=1")
              deadline = time.time() + 600
              while "up:active" not in quiet("ceph mds stat"):
                  assert time.time() < deadline, "no active mds"
                  time.sleep(10)
              fs_md5 = cephfs_user("write")
              assert cephfs_user("read") == fs_md5

          with subtest("rbd and cephfs I/O from node1 through the kernel clients"):
              key = kernel_key()
              map_rbd(key)
              node1.succeed("dd if=/dev/urandom of=/var/tmp/rbd.ref bs=1M count=32")
              node1.succeed("dd if=/var/tmp/rbd.ref of=/dev/rbd0 bs=1M oflag=direct conv=fsync")
              node1.succeed("md5sum < /var/tmp/rbd.ref > /var/tmp/rbd.md5")
              out = node1.succeed("head -c 33554432 /dev/rbd0 | md5sum")
              assert out == node1.succeed("cat /var/tmp/rbd.md5"), out
              mount_cephfs(key)
              node1.succeed("dd if=/dev/urandom of=/mnt/cephfs/file bs=1M count=16 conv=fsync")
              node1.succeed("md5sum < /mnt/cephfs/file > /var/tmp/cephfs.md5")
              node1.succeed("echo 3 > /proc/sys/vm/drop_caches")
              out = node1.succeed("md5sum < /mnt/cephfs/file")
              assert out == node1.succeed("cat /var/tmp/cephfs.md5"), out

          with subtest("erasure-coded pool (k=2, m=1, failure domain osd)"):
              ceph("osd erasure-code-profile set ec21 k=2 m=1 crush-failure-domain=osd")
              ceph("osd pool create ecpool 16 16 erasure ec21")
              ceph("osd pool application enable ecpool rgw")
              ok(node1, "cephadm shell -- rados -p ecpool put obj /etc/os-release")
              ec_expect = quiet("md5sum /etc/os-release").split()[0]
              got = ec_md5().split()[0]
              assert got == ec_expect, (got, ec_expect)

          with subtest("OSD on an LV on an Open CAS device"):
              node2.succeed("casadm -L -o csv | grep -E '^core,1,.*Active'")
              node2.succeed("pvcreate /dev/cas1-1 && vgcreate vgcas /dev/cas1-1 && lvcreate -l 100%FREE -n osd vgcas")
              try:
                  run(node1, "cephadm shell -- ceph orch daemon add osd node2:/dev/vgcas/osd", 900)
                  assert wait_healthy(6, timeout=420, fatal=False), "OSD on the cas-backed LV did not come up"
              except Exception:
                  run(node1, "cephadm shell -- ceph log last 50 cephadm")
                  raise

          with subtest("rgw: S3 put and get from the other node"):
              ceph("orch apply rgw test --placement='1 node2' --port=8080")
              wait_running("rgw")
              wait_until("rgw answering", lambda: node1.succeed(f"curl -sf {RGW_URL}/"), 180)
              ok(node1, "cephadm shell -- radosgw-admin user create --uid=t --display-name=t "
                 "--access-key=AKIATEST --secret=SECRETTEST")
              s3_md5 = s3("put")
              assert s3("get") == s3_md5

          with subtest("nfs: Ganesha on node1, kernel mount from node2"):
              run(node1, "cephadm shell -- ceph mgr module enable nfs")
              ceph("nfs cluster create nfs1 '1 node1'")
              wait_running("nfs")
              assert {d["hostname"] for d in running("nfs")} == {"node1"}
              ceph(f"nfs export create cephfs --cluster-id nfs1 --pseudo-path {NFS_PSEUDO} --fsname cephfs")
              try:
                  nfs_check(True)
              except Exception:
                  # if Ganesha did not load the new export live, restart it
                  ceph("orch restart nfs.nfs1")
                  time.sleep(20)
                  wait_running("nfs")
                  nfs_check(True)

          with subtest("iscsi: gateway on node2, iscsiadm login and I/O from node1"):
              iscsi_setup()
              iscsi_io()

          with subtest("dashboard REST API"):
              node1.succeed("printf %s Dash-pass-1 > /var/tmp/dashpw")
              ok(node1, "cephadm shell -m /var/tmp:/hostvar -- ceph dashboard ac-user-create apiuser "
                 "-i /hostvar/dashpw administrator")
              wait_until("dashboard health", lambda: dashboard_health() or True, 300)

          with subtest("rbd-mirror, cephfs-mirror and ceph-exporter"):
              ceph("orch apply rbd-mirror --placement='1 node2'")
              ceph("orch apply cephfs-mirror --placement='1 node2'")
              ceph("orch apply ceph-exporter")
              daemons_running()
              wait_until("ceph-exporter metrics", lambda: exporters() or True, 120)

          with subtest("health with the services"):
              wait_healthy(6)
              ceph("orch ps")

          with subtest("switch-to-configuration restarts no daemon"):
              for m in [node2, node1]:
                  switch(m)
              wait_healthy(6)

          with subtest("reboot both nodes"):
              unmount_clients()
              node2.shutdown()
              node1.shutdown()
              node1.start()
              node2.start()
              for m in hosts:
                  m.wait_for_unit("multi-user.target")
              node2.succeed("casadm -L -o csv | grep -E '^core,1,.*Active'")
              wait_healthy(6)
              for m in hosts:
                  run(m, "systemctl list-units --failed --no-pager")

          with subtest("data survived the reboot"):
              assert rbd_user_read() == rbd_md5
              assert cephfs_user("read") == fs_md5
              assert ec_md5().split()[0] == ec_expect
              key = quiet("ceph auth get-key client.kern")
              map_rbd(key)
              out = node1.succeed("head -c 33554432 /dev/rbd0 | md5sum")
              assert out == node1.succeed("cat /var/tmp/rbd.md5"), out
              mount_cephfs(key)
              out = node1.succeed("md5sum < /mnt/cephfs/file")
              assert out == node1.succeed("cat /var/tmp/cephfs.md5"), out
              unmount_clients()

          with subtest("services survived the reboot"):
              daemons_running()
              wait_until("s3 get", lambda: s3("get") == s3_md5, 300)
              nfs_check(False)
              iscsi_verify()
              wait_until("dashboard health", lambda: dashboard_health() or True, 300)
              wait_until("ceph-exporter metrics", lambda: exporters() or True, 120)
              wait_healthy(6)

          with subtest("switch-to-configuration after the reboot"):
              for m in [node2, node1]:
                  switch(m)
              wait_healthy(6)
      except Exception:
          diagnostics()
          raise
    '';
}
