# Image packages, merged into the flake's packages: one set per Ceph track (`-tentacle`, `-umbrella`).
# `ceph-image` is the Umbrella image. It is built on the self-hosted builder only (a from-source Ceph build takes
# hours, ADR 0007); no check depends on it.
{ pkgs, self }:
let
  mkCephImage = import ./ceph.nix { inherit pkgs; };
  rev = self.rev or self.dirtyRev or "dirty";

  # Everything that depends on the Ceph build, for one track. Companion versions are pinned to what upstream's image
  # of that release ships (ADR 0008); ganeshaVersion is the one that differs between tracks.
  mkTrack =
    {
      ceph,
      cephRef,
      ganeshaVersion,
    }:
    let
      python = ceph.pythonEnv.python;
      cephadm = pkgs.callPackage ../pkgs/cephadm.nix { inherit ceph; };
      smoke = pkgs.callPackage ../pkgs/ceph-smoke.nix { inherit ceph; };
      nfs-ganesha = import ../pkgs/nfs-ganesha.nix {
        inherit pkgs ceph;
        version = ganeshaVersion;
      };

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
      inherit
        cephadm
        smoke
        ledmon
        libstoragemgmt
        tcmu-runner
        ceph-iscsi
        nfs-ganesha
        ;
      image = mkCephImage {
        inherit
          ceph
          cephadm
          smoke
          libstoragemgmt
          rev
          cephRef
          ;
        ganesha = nfs-ganesha;
        tcmuRunner = tcmu-runner;
        version = ceph.version;
        extraPackages = [ ceph-iscsi ];
        # the cephadm orchestrator needs asyncssh; nixpkgs' mgr env lacks it
        extraPython = with python.pkgs; [
          asyncssh
          python3-saml # dashboard SAML SSO; upstream's el9/el10 image has it
          ceph-iscsi
        ];
      };
    };

  # the attributes of a track under its suffix
  named =
    suffix: t:
    {
      "cephadm-${suffix}" = t.cephadm;
      "ceph-smoke-${suffix}" = t.smoke;
      "ledmon-${suffix}" = t.ledmon;
      "libstoragemgmt-${suffix}" = t.libstoragemgmt;
      "tcmu-runner-${suffix}" = t.tcmu-runner;
      "ceph-iscsi-${suffix}" = t.ceph-iscsi;
      "nfs-ganesha-${suffix}" = t.nfs-ganesha;
      "ceph-image-${suffix}" = t.image;
    };

  # nixpkgs' cached Ceph: the Tentacle dev track.
  tentacle = mkTrack {
    ceph = pkgs.ceph;
    cephRef = "tentacle";
    ganeshaVersion = "5.9";
  };

  # nixpkgs' Ceph scope bumped to 21.2.0 (nix/pkgs/ceph): not in any cache.
  ceph-umbrella = pkgs.callPackage ../pkgs/ceph { };
  umbrella = mkTrack {
    ceph = ceph-umbrella;
    cephRef = "umbrella"; # upstream's CEPH_REF for 21.x
    ganeshaVersion = "9.16";
  };
in
named "tentacle" tentacle
// named "umbrella" umbrella
// {
  inherit ceph-umbrella;
  ceph-image = umbrella.image;
}
