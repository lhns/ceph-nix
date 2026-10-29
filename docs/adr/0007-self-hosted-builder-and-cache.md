# 7. Self-hosted builder and binary cache

Status: Accepted (2026-10)

## Context

The Ceph build is `big-parallel` and far beyond GitHub-hosted runners; NixOS VM tests need KVM and the Nix
features `nixos-test` and `kvm`. The repo is public, so a self-hosted runner is an attack surface.

## Decision

`nixosModules.builder` provides:

- `services.github-runners` (`ephemeral`, label `nix-builder`), running as a user that is not in
  `nix.settings.trusted-users` (asserted), with the features above and access to `/dev/kvm`;
- `services.harmonia`, a signed binary cache, with GC roots for released store paths and a weekly GC.

The builder only builds and runs sandboxed Nix checks; it never bootstraps clusters itself. Self-hosted jobs run
only on `push`, dispatch, schedule and same-repo PRs, never on fork PRs.

## Consequences

- The owner provisions the box, the runner token and the cache signing key (see the README).
- Builder availability gates the Umbrella build; the Tentacle track keeps working on GitHub runners.
- Clients substitute from the cache with its URL and public key.
