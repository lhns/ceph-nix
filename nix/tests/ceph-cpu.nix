# Negative control for the v2-only claim (ADR 0006): on a guest CPU without AVX2, the upstream image cannot run
# (glibc refuses x86-64-v3) and ours can. The VM test of the cephadm host runs ours on the same CPU.
{ pkgs, self }:
let
  inherit (pkgs) lib;
  common = import ./common.nix { inherit pkgs; };
  inherit (common) imageInfo;
  ours = self.packages.x86_64-linux.ceph-image-tentacle;
  oursRef = "localhost/ceph-nix:${pkgs.ceph.version}";
in
pkgs.testers.runNixOSTest {
  name = "ceph-cpu";
  skipTypeCheck = true;
  nodes.machine = {
    virtualisation.podman.enable = true;
    virtualisation = {
      cores = 2;
      memorySize = 3072;
      diskSize = 16384;
      qemu.options = lib.mkAfter [ "-cpu ${common.maskedCpu}" ];
    };
    system.stateVersion = "26.05";
  };
  testScript = ''
    machine.wait_for_unit("multi-user.target")
    machine.succeed("test $(grep -c avx2 /proc/cpuinfo) = 0")

    machine.succeed("podman load -i ${common.upstreamImage} </dev/null", timeout=1800)
    rc, out = machine.execute("podman run --rm ${imageInfo.image}:${imageInfo.tag} ceph --version </dev/null 2>&1", timeout=600)
    print(f"upstream: rc={rc}\n{out}")
    assert rc != 0 and "x86-64-v3" in out, (rc, out)

    machine.succeed("set -o pipefail; ${ours} | podman load", timeout=3600)
    out = machine.succeed("podman run --rm ${oursRef} ceph --version </dev/null 2>&1", timeout=600)
    print(f"ours: {out}")
    assert "ceph version ${pkgs.ceph.version}" in out, out
  '';
}
