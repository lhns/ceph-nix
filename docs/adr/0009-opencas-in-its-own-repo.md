# 9. OpenCAS in its own repository

Status: Accepted (2026-10)

## Context

Open CAS is useful without Ceph, and its packaging (the fork's tag, kernel support, the module) changes on its own
schedule. Keeping it here tied its releases and CI to the Ceph image's.

## Decision

The overlay, packages, `services.opencas` module and their tests moved to
[lhns/opencas-nix](https://github.com/lhns/opencas-nix) (its ADR 0001 continues [0005](0005-opencas-from-the-fork.md)).
This flake takes it as the input `opencas-nix` with `inputs.nixpkgs.follows = "nixpkgs"`, and re-exports its module
as `nixosModules.opencas`.

## Consequences

- The Open CAS VM test and kmod builds run in opencas-nix; here only the ceph-host test uses the module.
- Bumping Open CAS means bumping opencas-nix's lock entry here. The Ceph images do not include Open CAS.
- Release notes list the `opencas-nix` revision instead of `open-cas-src`.
