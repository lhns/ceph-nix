# 4. Run Ceph on NixOS via cephadm with our image

Status: Accepted (2026-10)

## Context

Hosts need the orchestrator (OSD specs, upgrades, services like NFS and iSCSI). NixOS's native `services.ceph`
has no orchestrator, and Rook needs Kubernetes. cephadm expects an FHS host: it writes systemd units to
`/etc/systemd/system`, sysctl to `/etc/sysctl.d`, logrotate to `/etc/logrotate.d`, and reads uid/gid from
`stat /var/lib/ceph` (167:167 in the image). The orchestrator runs `cephadm` from inside the image over SSH.

A spike (lhns/ceph-nix PR #4) ran upstream `quay.io/ceph/ceph:v21.2.0` on two NixOS nodes. On NixOS
`/etc/systemd/system` is a store symlink, also with `system.etc.overlay` (mutable or not), so cephadm's writes
fail with EROFS. A persistent overlay on that directory works: bootstrap, `orch host add`, OSDs, a reboot and a
`switch-to-configuration` all stayed healthy.

## Decision

Use cephadm with our image on NixOS hosts, through `nixosModules.ceph-host` (`services.ceph-host`). The module
does not import `nixos-cloudinit`; consumers compose it with their base.

- **Unit directory.** An activation snippet before `etc` unmounts the overlay and removes the directory so
  setup-etc places its symlink. After `etc`, a copy of this generation's units goes to `/run` as lowerdir, the
  symlink is replaced by a directory, and an overlay is mounted with upper `/var/lib/ceph-nix/systemd-units/upper`.
- **No restarts on switch.** `switch-to-configuration` stops active units whose file is in `/etc/systemd/system`
  but not in the new generation (all Ceph daemons, through `PartOf` the targets). Every cephadm unit carries
  `X-StopOnRemoval=false`. Our cephadm package patches the unit templates and the generated targets. The mgr
  copies cephadm from the image to the hosts it manages, so the patch only fully applies once our image ships
  it; until then a drop-in writer (at activation, and a path unit on the overlay's upper dir) is the backstop.
- **Host bits cephadm and ceph-volume rely on:** `/bin/bash`, `/bin/rm`, `/bin/ls`, `/usr/bin/python3` symlinks;
  a `/usr/sbin` symlink farm with the LVM tools (ceph-volume runs them on the host through `nsenter` and only
  searches `/usr/sbin` and friends); `/etc/environment` with `PATH=/run/wrappers/bin:/run/current-system/sw/bin`
  (units read `EnvironmentFile=-/etc/environment`, and their ExecStop needs `bash`); `/etc/logrotate.d` and
  `services.logrotate` including it; sshd `PermitRootLogin = prohibit-password` and an option for the
  orchestrator's public keys; firewall TCP 3300, 6789, 6800-7300, 8443, 8765, 9283, 9926; podman, lvm2, python3,
  chrony and cephadm.
- No `rbd`/`ceph` kernel modules on mon/mgr/OSD hosts (`clientKernelModules`, default false).
- The module asserts that `system.etc.overlay.enable` is false.

## Consequences

- Whiteouts persist across generations: a unit cephadm removed stays removed, and a unit that a later NixOS
  generation adds under the same name would be hidden.
- `/etc/environment` is host-wide: every unit that reads it gets that PATH.
- Untested: `system.etc.overlay` and the systemd initrd (the module refuses the former).
- Two cephadms: the host's (patched) and the image's (unpatched until our image ships the patch). Keep the
  patched version equal to the image's Ceph release.
- Kernel rbd/cephfs clients (`clientKernelModules`) cannot use Ceph 21's default AES256KRB5 keys (EINVAL on
  mount). They need the legacy cipher: `ceph mon set auth_allowed_ciphers aes,aes256k` and a client key created with
  `--key_type aes`; the mons then warn (`AUTH_INSECURE_*`). The VM test does exactly this. Userspace clients are
  unaffected.
- An LVM volume on an Open CAS device keeps the cache open at shutdown, so `open-cas-shutdown` cannot stop it and
  the cache comes back dirty with its core inactive. Deactivate the VG first (the test adds
  `ExecStartPre=-vgchange -an vgcas` to `open-cas-shutdown`); the opencas module could do this for VGs on cas
  devices.
- Host state (units, keys) lives outside the Nix store and is not declarative.
- The VM test (`packages.x86_64-linux.test-ceph-host`, `vm-tests.yml`) is the regression guard; it runs with the
  upstream image until ours exists.
