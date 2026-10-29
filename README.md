# ceph-nix

Ceph built from source with Nix, for hosts without x86-64-v3 (AVX2):

- an OCI image with feature parity to `quay.io/ceph/ceph`, for cephadm and Rook;
- a NixOS module for Ceph hosts managed by cephadm with that image;
- OpenCAS packages and a NixOS module, from [lhns/open-cas-linux](https://github.com/lhns/open-cas-linux);
- a NixOS module for the build host and its binary cache.

Work in progress. Decisions are in [`docs/adr/`](docs/adr). The ceph-csi counterpart is
[lhns/ceph-csi-x86-64-v2](https://github.com/lhns/ceph-csi-x86-64-v2).

## License

The Nix expressions, scripts and docs here are Apache-2.0. Built artifacts contain Ceph (LGPL-2.1/3, parts GPL),
OpenCAS (BSD-3-Clause) and nixpkgs packages under their own licenses; their sources are the pinned upstream sources
in `flake.lock` and the Nix expressions.
