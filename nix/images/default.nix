# Image packages, merged into the flake's packages.
{ pkgs, self }:
let
  mkCephImage = import ./ceph.nix { inherit pkgs; };
  rev = self.rev or self.dirtyRev or "dirty";

  # nixpkgs' cached Ceph: the Tentacle dev track. The Umbrella scope slots into the same mkCephImage.
  ceph = pkgs.ceph;
  python = ceph.pythonEnv.python;
  cephadm = pkgs.callPackage ../pkgs/cephadm.nix { inherit ceph; };
  smoke = pkgs.callPackage ../pkgs/ceph-smoke.nix { inherit ceph; };

  # iSCSI gateway and libstoragemgmt: neither is in nixpkgs, upstream's image has both
  ledmon = pkgs.callPackage ../pkgs/ledmon.nix { };
  libstoragemgmt = pkgs.callPackage ../pkgs/libstoragemgmt.nix {
    python3 = python;
    inherit ledmon;
  };
  tcmu-runner = pkgs.callPackage ../pkgs/tcmu-runner.nix { inherit ceph; };
  ceph-iscsi = python.pkgs.callPackage ../pkgs/ceph-iscsi.nix { };
in
{
  cephadm-tentacle = cephadm;
  ceph-smoke-tentacle = smoke;
  ledmon-tentacle = ledmon;
  libstoragemgmt-tentacle = libstoragemgmt;
  tcmu-runner-tentacle = tcmu-runner;
  ceph-iscsi-tentacle = ceph-iscsi;
  ceph-image-tentacle = mkCephImage {
    inherit
      ceph
      cephadm
      smoke
      libstoragemgmt
      rev
      ;
    tcmuRunner = tcmu-runner;
    version = ceph.version;
    cephRef = "tentacle";
    extraPackages = [ ceph-iscsi ];
    # the cephadm orchestrator needs asyncssh; nixpkgs' mgr env lacks it
    extraPython = with python.pkgs; [
      asyncssh
      python3-saml # dashboard SAML SSO; upstream's el9 image has it
      ceph-iscsi
    ];
  };
}
