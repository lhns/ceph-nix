# Ceph Umbrella: nixpkgs' Ceph scope with the source bumped. Build recipe, dependencies and the
# s3select/mgr-interpreter patches are nixpkgs'; both patches are still needed on 21.2.0
# (s3select submodule unchanged since 20.2.4, ceph/ceph#67904 unmerged).
{ ceph, fetchurl }:

(ceph.overrideScope (
  final: prev: {
    ceph-src = prev.ceph-src.overrideAttrs {
      version = "21.2.0";
      src = fetchurl {
        url = "https://download.ceph.com/tarballs/ceph-21.2.0.tar.gz";
        hash = "sha256-gtPAJgkWG94TDHxBwzxfiztZGFzep355KbveLLxm44U=";
      };
    };

    # 21.x's ceph.deployment.tls_utils (used by the service specs) imports cryptography.
    ceph-python-common = prev.ceph-python-common.overridePythonAttrs (old: {
      dependencies = old.dependencies ++ [ final.ceph-python.pkgs.cryptography ];
    });
  }
)).ceph
