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

    # 21.x installs the Cython bindings with `python -m pip install --no-build-isolation --no-deps`
    # (offline); 20.x used setup.py. The env is a callPackage of python-env.nix, so extend its withPackages.
    ceph-python-env = prev.ceph-python-env.override {
      ceph-python = final.ceph-python // {
        withPackages = f: final.ceph-python.withPackages (ps: f ps ++ [ ps.pip ]);
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

    # CMake's FindProtobuf module defines some protobuf:: targets, then gRPC's config loads protobuf's
    # own config and fails on the half-defined export set; use protobuf's config throughout, as the
    # comment above this call in src/CMakeLists.txt intends.
    postPatch = (old.postPatch or "") + ''
      substituteInPlace src/CMakeLists.txt         --replace-fail "find_package(Protobuf REQUIRED)" "find_package(Protobuf CONFIG REQUIRED)"
    '';

    cmakeFlags = old.cmakeFlags ++ [
      # 21.x clones Catch2 (unit tests only) with CPM at configure time; no network in the sandbox.
      (lib.cmakeBool "WITH_CATCH2" false)
      # Never download at configure time: a dependency that would be fetched is skipped and then
      # shows up as a configure or compile error instead of a network error.
      (lib.cmakeBool "FETCHCONTENT_FULLY_DISCONNECTED" true)
    ];
  })
