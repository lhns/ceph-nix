# 5. OpenCAS from the fork as a flake input

Status: Superseded by [0009](0009-opencas-in-its-own-repo.md)

## Context

OSD caching uses Open CAS. We need a per-IO-class cache mode, which the fork `lhns/open-cas-linux` implements
(tag `v26.03.3+mode.2`). The fork has no flake, and the kernel module must match the running kernel.

## Decision

Take the fork as a non-flake input (`git+…?ref=refs/tags/<tag>&submodules=1`). Userspace and the kmod (built per
`boot.kernelPackages`, with an assertion on supported kernels) are separate packages. `services.opencas` generates
`opencas.conf` and the IO-class CSV with per-class modes, and sets the host LVM `types = ["cas" 16]`.

## Consequences

- Bumping OpenCAS means bumping the tag; kmod build checks cover the default and latest supported kernels.
- We carry install-path, shebang and udev patching until the mode CSV is upstreamed.
