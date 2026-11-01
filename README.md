# ceph-nix

Ceph built from source with Nix, for hosts without x86-64-v3 (AVX2):

- an OCI image with feature parity to `quay.io/ceph/ceph`, for cephadm and Rook;
- a NixOS module for Ceph hosts managed by cephadm with that image;
- OpenCAS packages and a NixOS module, from [lhns/opencas-nix](https://github.com/lhns/opencas-nix) (an input);
- a NixOS module for the build host and its binary cache.

Work in progress. Decisions are in [`docs/adr/`](docs/adr). The ceph-csi counterpart is
[lhns/ceph-csi-x86-64-v2](https://github.com/lhns/ceph-csi-x86-64-v2).

## Ceph host

`nixosModules.ceph-host` makes a NixOS machine a Ceph host run by cephadm (see
[ADR 0004](docs/adr/0004-ceph-on-nixos-via-cephadm.md)): podman, LVM, chrony, a patched cephadm, a writable
`/etc/systemd/system` overlay, the FHS paths cephadm needs, SSH for the orchestrator and the Ceph firewall ports.
Compose it with your own base (it does not bring networking, a bootloader or users).

```nix
{
  imports = [ ceph-nix.nixosModules.ceph-host ];
  services.ceph-host = {
    enable = true;
    orchestratorKeys = [ "ssh-ed25519 AAAA... cluster" ]; # allowed to log in as root
    image = "ghcr.io/lhns/ceph-nix:...";      # required: pin by digest, same Ceph release as the host's cephadm
    # clientKernelModules = true;           # rbd/ceph kernel modules, for hosts that map or mount
  };
}
```

Bootstrap, on the first host:

```sh
cephadm bootstrap --mon-ip <ip>       # uses the image from services.ceph-host.image ($CEPHADM_IMAGE)
ssh-copy-id -f -i /etc/ceph/ceph.pub root@<other-host>  # or add ceph.pub to its orchestratorKeys
ceph orch host add <other-host> <ip>
ceph orch daemon add osd <host>:/dev/<disk>  # or: ceph orch apply osd --all-available-devices
```

Not supported: `system.etc.overlay.enable`. The VM test is `nix build .#test-ceph-host` (about 30 minutes): cephadm on NixOS with our image on a CPU without
AVX2, with `.#test-ceph-cpu` as negative control (upstream's image cannot start there).

## Disk locate LED

`ceph orch device light on|off <devid>` (and the dashboard's identify button) runs, on the disk's host,
`cephadm shell -- <mgr/cephadm/blink_device_light_cmd>` in a short-lived container of this image. Ceph's default command
is `lsmcli local-disk-ident-led-on`, which most SATA disks do not support. The image ships
`/usr/libexec/ceph-nix/device-light`, which tries `lsmcli` first and, for `ident` on a disk that does not support it,
blinks the drive's activity LED by reading it in bursts (`/usr/libexec/ceph-nix/blink-disk`; read-only). That loop has to
outlive cephadm's container, so it runs as a cephadm-managed container service `container.blink-<dev>` on the host;
`off` removes it. Starting it twice is one blinker. `fault` is native only.

Set the command template once per cluster (new or migrated; the key lives in the mon store, not in the image):

```sh
cephadm shell -- /usr/libexec/ceph-nix/device-light install
# or: ceph config-key set mgr/cephadm/blink_device_light_cmd \
#   "/usr/libexec/ceph-nix/device-light {{ 'on' if on else 'off' }} {{ ident_fault }} '{{ path or dev }}'"
```

The fallback needs a working `ceph` CLI inside `cephadm shell` on that host, i.e. an admin keyring there (hosts with the
`_admin` label have one).

For a disk without a `/dev/disk/by-path` link cephadm passes the bare kernel name (`sda`); `device-light` takes either.
The mgr runs its module commands one at a time, so the fallback's `ceph orch apply`/`rm` cannot complete while the
`device light` command that runs it is still going: `device-light` sends them without waiting, and the blinker starts
(or stops) a few seconds after `device light` returns (`ceph orch ls container`). `ceph device light on` prints the
command's result, or `None` when it failed: the error is then in the mgr log (`ceph log last cephadm`).

## OpenCAS

The Open CAS packages and the `services.opencas` module live in [lhns/opencas-nix](https://github.com/lhns/opencas-nix)
([ADR 0009](docs/adr/0009-opencas-in-its-own-repo.md)), which this flake takes as the input `opencas-nix`.
`nixosModules.opencas` (and `overlays.default`) re-export its module (and overlay), so existing users keep working;
new users can depend on opencas-nix directly. Its README has the options and a usage example.

## Tracks

- Tentacle (20.2.x): nixpkgs' Ceph, so cached; `.#ceph-image-tentacle`.
- Umbrella (21.2.0): nixpkgs' Ceph scope with the source bumped ([`nix/pkgs/ceph`](nix/pkgs/ceph/default.nix)),
  `.#ceph-image` (also `.#ceph-image-umbrella`, `.#ceph-umbrella`, `.#test-ceph-cpu-umbrella`,
  `.#test-ceph-host-umbrella`). A from-source build takes about 1.5 h on a GitHub-hosted runner; CI builds it once per
  derivation and keeps the result in the Actions cache ([ADR 0010](docs/adr/0010-hosted-runners-and-actions-cache.md)).
  CI tests both tracks the same way and the migration from one to the other.

### Migrating 20.2.4 -> 21.2.0

`ceph orch upgrade` works, but NFS exports stay in their grace period afterwards (opens and reads hang; health stays
OK). Upstream's images do the same. Ganesha 5.9 (Tentacle) is in the grace table under cephadm's nodeid `0`,
Ganesha 9.16 (Umbrella) under `node0`: it prepends `node` to a numeric nodeid. The 5.9 daemon requests grace under
`0` when it stops, and no daemon ever lifts it. Once the nfs daemons run 21.2.0, run this in `cephadm shell` for
each NFS cluster (`ceph nfs cluster ls`):

```sh
c=<cluster id>
ganesha-rados-grace --pool .nfs --ns $c dump    # stale: "0  NE"; live: "node0  E"
stale=$(rados -p .nfs -N $c listomapkeys grace | grep -xE '[0-9]+')
for k in $stale; do rados -p .nfs -N $c rmomapkey grace $k; done
for k in $stale; do ganesha-rados-grace --pool .nfs --ns $c start $k; done
ganesha-rados-grace --pool .nfs --ns $c dump    # within a minute: rec=0, no N
```

`rados` removes the old keys because 21.2.0's `ganesha-rados-grace` can't name them: it turns `0` into `node0`, so
`ganesha-rados-grace remove 0` removes the live daemon's key. If you ran that, `ganesha-rados-grace add 0` puts it
back. Removing a key does not end the grace period by itself. `start` sets need-grace on the live `node<k>` keys,
and the daemons lift it themselves, which ends the period. Exports, data and the daemons are not touched, and
nothing is restarted. `tests/upgrade.sh` runs these commands in the `migrate` and `migrate-control` CI legs,
with one client mount kept across the upgrade and a fresh mount after it.

## Releases

Each Ceph release line is published as `ghcr.io/lhns/ceph-nix:v<ceph version>-<n>` (e.g. `v20.2.4-1`) and as a
GitHub release with the same tag, whose notes give the manifest digest, the config digest, the `flake.lock` revisions
of nixpkgs and opencas-nix and the companion versions. A tag is never moved; `<n>` goes up when the image changes
(for example a new nixpkgs revision with a security fix). Pin by digest, as in `services.ceph-host.image`:

```
ghcr.io/lhns/ceph-nix@sha256:<manifest digest from the release notes>
```

[`release.yml`](.github/workflows/release.yml) runs after `ceph.yml` succeeded on `main` and releases that exact
commit if the image differs from the newest `v<ver>-*` ([ADR 0003](docs/adr/0003-releases.md)). It compares the
image config (layer content, env, cmd, labels; without the commit label), not the registry digest. Publishing is off
until the repository variable `PUBLISH` is `true` (Settings, Secrets and variables, Actions, Variables). Without it
the workflow is a dry run: it builds the image and prints "would publish v20.2.4-1, config digest ..., newest
existing: none" to the run's step summary, and pushes nothing. [`bump.yml`](.github/workflows/bump.yml) opens a
weekly `flake.lock` PR and an issue when upstream publishes a newer Ceph release in the tracked series.

## License

The Nix expressions, scripts and docs here are Apache-2.0. Built artifacts contain Ceph (LGPL-2.1/3, parts GPL),
nixpkgs packages under their own licenses; their sources are the pinned upstream sources
in `flake.lock` and the Nix expressions.
