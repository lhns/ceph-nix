# ceph-nix

Ceph built from source with Nix, for hosts without x86-64-v3 (AVX2):

- an OCI image that tracks `quay.io/ceph/ceph` (what is and is not verified: [below](#verified)), for cephadm and Rook;
- a NixOS module for Ceph hosts managed by cephadm with that image;
- OpenCAS packages and a NixOS module, from [lhns/opencas-nix](https://github.com/lhns/opencas-nix) (an input);
- a NixOS module for the build host and its binary cache.

Work in progress. Decisions are in [`docs/adr/`](docs/adr). The ceph-csi counterpart is
[lhns/ceph-csi-x86-64-v2](https://github.com/lhns/ceph-csi-x86-64-v2). Drafted, not yet filed upstream bug reports:
[`docs/upstream-reports.md`](docs/upstream-reports.md).

## Verified

"Verified" means CI runs it on every image change (`ceph.yml`, `vm-tests.yml`), for both tracks unless noted.

- File trees, python distributions and linkage against upstream's image (`tests/parity.sh`), with the allowlist and
  the build deviations of [ADR 0002](docs/adr/0002-parity-with-the-upstream-image.md); tcmalloc heap commands and
  `osd_memory_target` autotuning.
- NixOS VM tests on a CPU without AVX2 (`.#test-ceph-host`): RBD, CephFS, erasure-coded pools, RGW with S3, NFS,
  iSCSI, the dashboard API, the rbd-mirror and cephfs-mirror daemons, the exporter, and a reboot.
- `tests/cephadm.sh`: a cephadm cluster on the image, the functional checks on real mounts.
- Upgrades: upstream v20.2.4 to ours (`upgrade.sh`), ours Tentacle to Umbrella (`migrate`), and the same between
  upstream's images (`migrate-control`) as the reference.
- CPU negative control: upstream's image is refused on an Ivy Bridge CPU model and runs on Haswell; ours runs on both.
- ceph-csi's acceptance e2e on Rook with the image; Trivy: CRITICAL findings with a fix fail the build
  ([ADR 0006](docs/adr/0006-test-strategy.md)).

Not verified:

- Replication through rbd-mirror and cephfs-mirror: only that the daemons run.
- Multi-host failure drills (node loss, network partitions).
- Performance: no benchmarks against upstream's image.
- Real Ivy Bridge hardware: the CPU tests use qemu and masked KVM CPUs.
- The NixOS-host leg of a migration from an unpatched (upstream) cephadm, i.e. the `keepUnits` backstop of the module:
  CI runs the upgrade on a plain Ubuntu host only.
- The negative-control CPU test uses upstream's Umbrella image for both tracks (the known x86-64-v3 image).
- The Trivy scan sees language packages (Python, Go, Rust) but not the Nix-built native libraries: there is no OS
  package database in the image.

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
    cephadmPackage = ceph-nix.packages.x86_64-linux.cephadm-tentacle.host; # required: cephadm-umbrella.host for Umbrella
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

Not supported: `system.etc.overlay.enable`. The VM test is `nix build .#test-ceph-host` (about 42 minutes for Tentacle, 52 for Umbrella with `-umbrella`): cephadm on NixOS with our image on a CPU without
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

- Tentacle (20.2.x): nixpkgs' Ceph scope with our overrides ([`nix/pkgs/ceph`](nix/pkgs/ceph/default.nix)),
  `.#ceph-image-tentacle` (also `.#ceph-tentacle`).
- Umbrella (21.2.0): the same scope with the source bumped, `.#ceph-image` (also `.#ceph-image-umbrella`,
  `.#ceph-umbrella`, `.#test-ceph-cpu-umbrella`, `.#test-ceph-host-umbrella`).

Neither is in cache.nixos.org. A cold from-source build takes about 2 h per track on a GitHub-hosted runner; CI builds each track
once per derivation and keeps the result in the Actions cache
([ADR 0011](docs/adr/0011-both-tracks-built-with-shared-overrides.md)). CI tests both tracks the same way and the
migration from one to the other.

### Upgrading and migrating

A cluster on upstream's `quay.io/ceph/ceph` moves to this image in two `ceph orch upgrade` steps, each tested in CI
(`tests/upgrade.sh`, `migrate`, `migrate-control`). Set `services.ceph-host.image` and `services.ceph-host.cephadmPackage`
(the target track's `cephadm-tentacle.host` or `cephadm-umbrella.host`) to the target release first, and pin images by digest:

1. Upstream v20.2.4 to ours v20.2.4: `ceph orch upgrade start --image ghcr.io/lhns/ceph-nix@sha256:<v20.2.4 digest>`.
   Same version, so only the container changes; wait for `ceph orch upgrade status` to finish and for HEALTH_OK.
2. Ours v20.2.4 to ours v21.2.0: `ceph orch upgrade start --image ghcr.io/lhns/ceph-nix@sha256:<v21.2.0 digest>`,
   then the NFS grace step below for each NFS cluster. Upstream v20.2.4 to upstream v21.2.0 behaves the same way.

Afterwards `ceph versions` shows one version (the old rgw daemon can stay listed for a few minutes) and the
`AUTH_INSECURE_KEYS_*` warnings that cephadm's Tentacle upgrade leaves may remain until the old-style keys are gone.
`CEPHADM_STRAY_DAEMON` naming `nfs-ganesha.nfs.<rank>` is expected on 21.2.0, upstream's image included
(`tests/lib.sh`; [report](docs/upstream-reports.md)).

#### NFS grace step (20.2.4 -> 21.2.0)

`ceph orch upgrade` works, but NFS exports stay in their grace period afterwards (opens and reads hang; health stays
OK). Upstream's images do the same. `tests/upgrade.sh` runs this step on the migration legs (`NFS_STALE_GRACE=1`) and
fails if the stale key is absent, so the step is required today and CI tells us when it becomes obsolete. Ganesha 5.9
(Tentacle) is in the grace table under cephadm's nodeid `0`, Ganesha 9.16 (Umbrella) under `node0`: it prepends `node`
to a numeric nodeid. The 5.9 daemon requests grace under `0` when it stops, and no daemon ever lifts it. Once the nfs
daemons run 21.2.0, run this in `cephadm shell` for each NFS cluster (`ceph nfs cluster ls`):

```sh
c=<cluster id>
ganesha-rados-grace --pool .nfs --ns $c dump    # stale: "0  NE"; live: "node0  E"
keys=$(rados -p .nfs -N $c listomapkeys grace)
stale=$(for k in $keys; do if grep -qx "node$k" <<<"$keys"; then echo "$k"; fi; done)   # "0" next to "node0"
for k in $stale; do rados -p .nfs -N $c rmomapkey grace $k; done
for k in $stale; do ganesha-rados-grace --pool .nfs --ns $c start $k; done
ganesha-rados-grace --pool .nfs --ns $c dump    # within a minute: rec=0, no N
```

`rados` removes the old keys because 21.2.0's `ganesha-rados-grace` can't name them: it turns `0` into `node0`, so
`ganesha-rados-grace remove 0` removes the live daemon's key. If you ran that, `ganesha-rados-grace add 0` puts it
back. Removing a key does not end the grace period by itself. `start` sets need-grace on the live `node<k>` keys,
and the daemons lift it themselves, which ends the period. Exports, data and the daemons are not touched, and
nothing is restarted. The CI legs keep one client mount across the upgrade and make a fresh mount after it.

## Releases

Each Ceph release line is published as `ghcr.io/lhns/ceph-nix:v<ceph version>-<n>` (e.g. `v20.2.4-1`) and as a
GitHub release with the same tag, whose notes give the manifest digest, the config digest, the `flake.lock` revisions
of nixpkgs and opencas-nix and the companion versions. A tag is never moved; `<n>` goes up when the image changes
(for example a new nixpkgs revision with a security fix). Pin by digest, as in `services.ceph-host.image`:

```
ghcr.io/lhns/ceph-nix@sha256:<manifest digest from the release notes>
```

[`release.yml`](.github/workflows/release.yml) runs when `ceph.yml` or `vm-tests.yml` finishes on `main`; the one that
finishes last passes its gate (both green for the commit, which must be main's head) and releases the `image-<track>`
artifacts that `ceph.yml` tested, without rebuilding, if the image differs from the newest `v<ver>-*`
([ADR 0003](docs/adr/0003-releases.md)). The artifacts are kept 7 days: a later release needs `ceph.yml` re-run first.
It compares the image config (layer content, env, cmd, labels; without the commit label), not the registry digest.
Publishing is off until the repository variable `PUBLISH` is `true` (Settings, Secrets and variables, Actions,
Variables). Without it the workflow is a dry run: it prints "would publish v20.2.4-1, config digest ..., newest
existing: none" to the run's step summary, and pushes nothing. [`bump.yml`](.github/workflows/bump.yml) opens a
weekly `flake.lock` PR and an issue when upstream publishes a newer Ceph release in the tracked series.

## License

The Nix expressions, scripts and docs here are Apache-2.0. Built artifacts contain Ceph (LGPL-2.1/3, parts GPL),
nixpkgs packages under their own licenses; their sources are the pinned upstream sources
in `flake.lock` and the Nix expressions.
