# Upstream bug reports (drafts, not filed)

Four problems found while testing this image. They are not packaging bugs: upstream's own images behave the same,
which the control legs in CI show. Each draft says what the repo's code, comments and tests establish; where that is
thin, the draft says so instead of guessing. Check each against current upstream before filing.

## 1. ceph-csi: e2e `setClusterName` does not wait for the rollout it causes

- Component: ceph-csi, `e2e/operator.go` (`OperatorDeployment.setClusterName`), operator-deployment mode.
- Symptom: the first RBD PVC after the cluster name is set sometimes fails the e2e check that the journal omap object
  count is back to its previous value. The patch of the `OperatorConfig` makes the operator roll out the CSI plugin
  deployment and daemonset; a `CreateVolume` that reaches a controller plugin pod being replaced leaves its journal
  object behind (leaked).
- Reproduction: run the acceptance e2e (`--operator-deployment`, RBD) against a Rook cluster; intermittent, seen in
  our CI (`tests/e2e.sh`). `setEnableFencing` in the same file already waits for the rollout; `setClusterName` returns
  right after the `kubectl patch`.
- Suggested fix: do what `setEnableFencing` does: read the deployment generation before patching and wait for the
  generation change and the rollout afterwards. `tests/ceph-csi-e2e-setclustername.patch` does that by moving the wait
  into a shared `waitForRollout(oldGeneration)` helper; it applies to the release tags we test.
- Thin facts: we have not shown why a `CreateVolume` interrupted by a pod replacement leaves the journal object (the
  driver's undo path may be worth a look; if it is a driver bug, the e2e wait only hides it). We only know the
  omap-count failure disappears with the wait.

## 2. Ceph mgr: `ceph orch device light on|off` prints `None` when the blink command fails

- Component: mgr, cephadm orchestrator module (`blink_device_light`, `mgr/cephadm/blink_device_light_cmd`) and the
  `ceph orch device light` / `ceph device light` command.
- Symptom: the command prints the blink command's output on success (`Set ident light ...`). When the command exits
  non-zero or raises, it prints `None`; the reason is only in the mgr log (`ceph log last cephadm`). The dashboard's
  identify button is affected the same way.
- Reproduction (from `tests/cephadm.sh`, `nix/pkgs/blink/device-light`): set `blink_device_light_cmd` to a command that
  fails for the device, e.g. our wrapper given a bare kernel name `sda` (cephadm renders that for a disk without a
  `/dev/disk/by-path` link) before it accepted those names, or `lsmcli local-disk-ident-led-on` on a SATA disk
  without LED support; run `ceph device light on <devid>`. The same `None` appeared when the command itself ran
  `ceph orch ...`: the mgr runs module commands one at a time, so the nested command waited for cephadm's 895 s
  timeout and the outer one then printed `None`.
- Suggested fix: return the command's error (exit status and stderr) to the CLI instead of `None`; document or avoid
  nested orchestrator calls from `blink_device_light_cmd`.
- Thin facts: the symptom is from running the command; we have not read the mgr code for the exact return path
  (`light_on` or its callers). Confirm where the exception is swallowed before filing.

## 3. nfs-ganesha / cephadm: grace-table node name changes with the Ganesha version, so an upgrade leaves exports in grace

- Component: nfs-ganesha (rados grace backend, `ganesha-rados-grace`), cephadm's nfs service (ganesha.conf template).
- Symptom: after `ceph orch upgrade` from 20.2.4 (Ganesha 5.9) to 21.2.0 (Ganesha 9.16) NFS opens and reads hang and
  health stays OK. `ganesha-rados-grace dump` shows two keys for the one daemon: the old numeric `0` (flags `NE`) and
  the live `node0`. Ganesha 9.x prepends `node` to a numeric `nodeid`, and so does its `ganesha-rados-grace`, which
  therefore cannot name the old key (`remove 0` removes the live `node0`). The 5.9 daemon requests grace under `0`
  when it stops; nobody lifts it, and the new daemon logs nothing about it.
- Reproduction: `tests/upgrade.sh` with `NFS_STALE_GRACE=1` (CI legs `migrate` and `migrate-control`, the latter
  with upstream's images only), or by hand: create an NFS cluster and export on 20.2.4, upgrade to 21.2.0, run
  `ganesha-rados-grace --pool .nfs --ns <cluster> dump`.
- Workaround: the README's NFS grace step (remove the stale omap key with `rados`, then `ganesha-rados-grace start`).
- Suggested fix: Ganesha should treat a numeric `nodeid` the same in the daemon and the tool, or accept the old name
  and migrate the key on start; alternatively cephadm should pass a nodeid that does not change form across releases.
- Thin facts: this repo only tests the cross-version upgrade. Whether a plain redeploy at the same version (new daemon
  suffix, same rank) is affected is not tested; by the cause above it should not be, since the name is derived from the
  rank. The `nodeid` line cephadm writes (`CEPH { register_service = true; nodeid = "<rank>"; }`) is what we saw in
  ganesha.conf (`tests/upgrade.sh` prints it); we have not checked which side should change.

## 4. cephadm: stray-daemon check flags the nfs-ganesha service entry as `CEPHADM_STRAY_DAEMON`

- Component: cephadm mgr module (stray daemon check), nfs service template with `register_service = true`.
- Symptom: on 21.2.0, `ceph health detail` lists `CEPHADM_STRAY_DAEMON` with `stray daemon nfs-ganesha.nfs.<rank> on
  host <host>`, after every mgr start and then every 30 minutes, while the NFS cluster is up. Upstream's
  `quay.io/ceph/ceph:v21.2.0` does the same; Ceph main reverted the template change (ceph/ceph#69042), per the comment
  in `tests/lib.sh`.
- Cause (from our tests): cephadm writes `register_service = true` and `nodeid = "<rank>"` into ganesha.conf, so Ganesha
  9.x registers in the service map as `nfs-ganesha/nfs.<rank>`. The stray check compares service-map names with
  cephadm's daemon names `nfs.<cluster>.<rank>.<gen>.<host>.<suffix>` and never matches them.
- Reproduction: deploy an NFS cluster on a fresh v21.2.0 cluster, `ceph mgr fail`, wait for the orchestrator, then
  `ceph health detail` (`stray_check_now` in `tests/lib.sh`).
- Suggested fix: the revert in ceph/ceph#69042 for the release branch, or teach the stray check to map
  `nfs-ganesha.nfs.<rank>` to the nfs daemon of that rank.
- Thin facts: whether #69042 is backported to a 21.2.x release is not checked here. `tests/lib.sh` tolerates exactly
  this detail and fails when the warning stops appearing, so a fixed release is noticed.
