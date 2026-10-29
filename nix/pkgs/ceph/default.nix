# Ceph Umbrella: nixpkgs' Ceph scope with the source bumped. Build recipe, dependencies and the
# s3select/mgr-interpreter patches are nixpkgs'; both patches are still needed on 21.2.0
# (s3select submodule unchanged since 20.2.4, ceph/ceph#67904 unmerged).
{
  lib,
  ceph,
  fetchurl,
  grpc,
  protobuf,
}:

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
)).ceph.overrideAttrs
  (old: {
    # 21.x builds the NVMe-oF gateway monitor client unconditionally (20.x only on some distros);
    # it runs protoc and grpc_cpp_plugin from these packages' CMake targets.
    buildInputs = old.buildInputs ++ [
      grpc
      protobuf
    ];

    cmakeFlags = old.cmakeFlags ++ [
      # 21.x clones Catch2 (unit tests only) with CPM at configure time; no network in the sandbox.
      (lib.cmakeBool "WITH_CATCH2" false)
      # Never download at configure time: a dependency that would be fetched is skipped and then
      # shows up as a configure or compile error instead of a network error.
      (lib.cmakeBool "FETCHCONTENT_FULLY_DISCONNECTED" true)
    ];
  })
