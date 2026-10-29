# 4. Run Ceph on NixOS via cephadm with our image

Status: Proposed — mechanism pending the cephadm-on-NixOS spike

## Context

Hosts need the orchestrator (OSD specs, upgrades, services like NFS and iSCSI). NixOS's native `services.ceph`
has no orchestrator, and Rook needs Kubernetes. cephadm expects an FHS host: it writes systemd units to
`/etc/systemd/system`, sysctl to `/usr/lib/sysctl.d`, logrotate to `/etc/logrotate.d`, and reads uid/gid from
`stat /var/lib/ceph` (167:167 in the image). The orchestrator runs `cephadm` from inside the image over SSH.
cephadm on NixOS is unproven.

## Decision

Use cephadm with our image on NixOS hosts. The `ceph-host` module builds on `nixos-cloudinit`'s base and provides
podman, lvm2, chrony, our cephadm, `rbd`/`ceph` kernel modules, firewall ports, an orchestrator SSH key, and
writable unit, sysctl and logrotate directories. The mechanism for the writable directories (plain NixOS,
`system.etc.overlay` with mutable, or a bind-mounted overlay) is chosen by the spike.

## Consequences

- If no mechanism survives a reboot and `switch-to-configuration`, this ADR is withdrawn and options are reopened.
- Host state (units, keys) lives outside the Nix store and is not declarative.
