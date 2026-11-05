# 12. OpenCAS only as a test input

Status: Accepted (2026-11)

## Context

[0009](0009-opencas-in-its-own-repo.md) moved Open CAS to lhns/opencas-nix but kept `nixosModules.opencas` and
`overlays.default` here as re-exports for existing users. The images do not contain Open CAS, so the re-exports
and the opencas-nix revision in the release notes only tied hosts' Open CAS version to ceph-nix's lock.

## Decision

Drop both re-exports and the opencas-nix revision from the release notes. The `opencas-nix` input stays for the
ceph-host VM test, which checks OSDs on a cache device across a reboot, the layout our hosts run.

## Consequences

- Hosts import `opencas-nix.nixosModules.opencas` from their own opencas-nix input (a breaking change for configs
  that used `ceph-nix.nixosModules.opencas`).
- Open CAS and Ceph update independently on hosts; bumping opencas-nix here only changes what the test covers.
