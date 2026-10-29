# ceph-nix

Ceph built from source with Nix, for hosts without x86-64-v3 (AVX2):

- an OCI image with feature parity to `quay.io/ceph/ceph`, for cephadm and Rook;
- a NixOS module for Ceph hosts managed by cephadm with that image;
- OpenCAS packages and a NixOS module, from [lhns/open-cas-linux](https://github.com/lhns/open-cas-linux);
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
    # image = "ghcr.io/lhns/ceph-nix:...";  # default: the pinned upstream release
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

Not supported: `system.etc.overlay.enable`. The VM test is `nix build .#test-ceph-host` (about 30 minutes).

## Builder

`nixosModules.builder` turns a NixOS machine into the CI builder (ephemeral GitHub runners with label `nix-builder`,
KVM, a signed binary cache via harmonia; see [ADR 0007](docs/adr/0007-self-hosted-builder-and-cache.md)).

```nix
{
  inputs.ceph-nix.url = "github:lhns/ceph-nix";
  # in the machine's modules:
  imports = [ ceph-nix.nixosModules.builder ];
  services.ceph-nix-builder = {
    enable = true;
    runner.tokenFile = "/var/lib/secrets/ceph-nix-runner-token";
    cache.signingKeyFile = "/var/lib/secrets/ceph-nix-cache-1.secret";
    cache.openFirewall = true;
  };
}
```

- Runner token: a fine-grained PAT with read/write on the repository's "self-hosted runners" (preferred, since
  ephemeral runners re-register constantly; a registration token expires after an hour). Store it as a single line
  without a newline: `echo -n '<token>' > /var/lib/secrets/ceph-nix-runner-token`.
- Signing key: `nix key generate-secret --key-name ceph-nix-cache-1 > /var/lib/secrets/ceph-nix-cache-1.secret`;
  the public key is `nix key convert-secret-to-public < /var/lib/secrets/ceph-nix-cache-1.secret`.
- Clients: add `extra-substituters = http://<builder>:5000` and
  `extra-trusted-public-keys = ceph-nix-cache-1:<public key>` to `nix.conf`.
- Other options: `runner.count`, `runner.url`, `cache.port`, `gcRoots` (store paths exempt from the weekly GC).

## License

The Nix expressions, scripts and docs here are Apache-2.0. Built artifacts contain Ceph (LGPL-2.1/3, parts GPL),
OpenCAS (BSD-3-Clause) and nixpkgs packages under their own licenses; their sources are the pinned upstream sources
in `flake.lock` and the Nix expressions.
