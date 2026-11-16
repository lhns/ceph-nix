# 13. Release identity from store paths, not layer bytes

Status: Accepted (2026-11)

## Context

[0003](0003-releases.md) decides "changed" by the image config without the revision label, which includes the layer
diff_ids. The first release after `v20.2.5-1` / `v21.2.0-1` published `-2` of both with nothing changed:

- Umbrella was byte-identical. The release compared our raw config with `skopeo inspect --config`, which prints a
  converted config, so the two never matched.
- Tentacle had the same store paths in every layer but different bytes in two. The ceph and vm-tests workflows had
  both built Ceph from source in parallel, and Ceph does not build bit for bit reproducibly; the next commit restored
  the vm-tests build from the cache.

## Decision

- The identity is the config without the revision label and without `rootfs.diff_ids`. What stays is the store
  paths of each layer (its history comment), env, cmd and labels. Store paths are input-addressed, so equal paths
  mean equal build inputs.
- The published config is read raw (`skopeo inspect --raw --config`).
- Only the ceph workflow saves the Ceph cache entry; vm-tests restores it but does not save its own build.

## Consequences

- A rebuild of the same derivation (a cache eviction, a second build) no longer releases. A change of any input
  still does, through its store path.
- A non-reproducible byte difference inside the same store paths is not released; the published image stays the
  one that was released first.
- When both workflows build cold at once, vm-tests tests its own build of the same derivation, not the released bytes.
- `v20.2.5-2` and `v21.2.0-2` stay: tags are never moved or removed.

## Amendment (2026-11): fakeRootCommands

`fakeRootCommands` (directories, modes, owners) run in the stream script, so a change there alters no store path and
no config: it would not release. The image now carries the sha256 of that string in the label
`ceph-nix.fakeroot-sha256`, which is part of the identity. The image sets no `extraCommands`. Adding the label
changed the identity of the images once; the first release after it publishes `-3` of both tracks.
