# 10. GitHub-hosted runners and the Actions cache for Umbrella

Status: Accepted (2026-11)

## Context

ADR 0007 assumed that a from-source Ceph build is beyond GitHub-hosted runners and added a self-hosted builder. A probe
showed otherwise: `.#ceph-umbrella` builds from scratch on `ubuntu-24.04` (4 vCPU, 16 GB) in 1 h 33 min, peaking at
about 7 GB RAM and 9 GB disk, well inside the 6 h job limit. The hosted runners also run the NixOS VM tests (KVM).
A self-hosted runner on a public repo is an attack surface we no longer need.

## Decision

- No self-hosted builder: `nixosModules.builder` and its check are removed; ADR 0007 is superseded.
- Every job that needs Umbrella uses the composite action `.github/actions/ceph-umbrella`. It restores an
  `actions/cache` entry keyed by the hash of the `.#ceph-umbrella` derivation; on a miss it builds Ceph and saves the
  store paths of its closure that cache.nixos.org does not serve, as a file:// Nix binary cache. A hit lets Nix
  substitute Ceph from that directory, so a derivation is built once.
- Tentacle (nixpkgs' cached Ceph) is unchanged.

## Consequences

- A new derivation (nixpkgs bump, patch) costs one cold build of about 1.5 h; jobs that start at the same time and
  miss each build it, and the first to finish saves.
- Entries are evicted after 7 days unused or when the repo's 10 GB cap is reached; a cold build follows.
- A cache is visible only to its own branch and the default branch. Pushes to a branch fill the branch's cache, so
  same-repo PRs run from the push event; a merge starts cold on `main`. Fork PRs cannot write the cache.
- The cache is unsigned and only read back by this repo's runs; the action disables signature checks for that one build.
