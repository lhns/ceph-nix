# Image packages, merged into the flake's packages.
{ pkgs, self }:
let
  mkCephImage = import ./ceph.nix { inherit pkgs; };
  rev = self.rev or self.dirtyRev or "dirty";

  # nixpkgs' cached Ceph: the Tentacle dev track. The Umbrella scope slots into the same mkCephImage.
  ceph = pkgs.ceph;
  cephadm = pkgs.callPackage ../pkgs/cephadm.nix { inherit ceph; };
  smoke = pkgs.callPackage ../pkgs/ceph-smoke.nix { inherit ceph; };
in
{
  cephadm-tentacle = cephadm;
  ceph-smoke-tentacle = smoke;
  ceph-image-tentacle = mkCephImage {
    inherit
      ceph
      cephadm
      smoke
      rev
      ;
    version = ceph.version;
    cephRef = "tentacle";
    # the cephadm orchestrator needs asyncssh; nixpkgs' mgr env lacks it
    extraPython = with ceph.pythonEnv.python.pkgs;
    [
      asyncssh
      python3-saml # dashboard SAML SSO; upstream's el9 image has it
    ];
  };
}
