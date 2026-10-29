#!/usr/bin/env bash
# Migration test: a cephadm cluster on FROM_IMAGE is upgraded in place to our image with `ceph orch upgrade`
# and must come out healthy with its data, config and mgr modules intact. This is the path a production
# cephadm cluster on upstream quay.io/ceph/ceph takes when it moves to our image.
#   upgrade.sh FROM_IMAGE TO_IMAGE_TARBALL
#     FROM_IMAGE        registry reference (e.g. the upstream image, pinned by digest) or a docker-archive
#                       tarball (e.g. our previous release); cephadm, bootstrap and the toolbox come from it
#     TO_IMAGE_TARBALL  docker-archive tarball, optionally zstd-compressed
# Env: ROLLBACK_IMAGE   image for the informational rollback after the gating checks (default FROM_IMAGE when it is
#                       a reference; empty = skip). Only meaningful at the same version: a downgrade is refused.
#      UPGRADE_TIMEOUT  seconds to wait for each upgrade (default 3000)
#      ARTIFACT_DIR     where logs go (default ./upgrade-logs); before/ and after/ hold the compared state
# Health: strictly HEALTH_OK before the upgrade. Afterwards only ALLOWED_WARNINGS (default: the two
# AUTH_INSECURE_KEYS_* checks cephadm's Tentacle upgrade leaves behind after rotating daemon keys; the admin clears
# them once old-style keys are gone). Transient UPGRADE_NO_STANDBY_MGR is only logged.
# Mgr modules: no module may be unable to run after the upgrade that could run before.
set -Eeuo pipefail
from=$1
tarball=$(realpath "$2")
here=$(cd "$(dirname "$0")" && pwd)
art=${ARTIFACT_DIR:-$PWD/upgrade-logs}
limit=${UPGRADE_TIMEOUT:-3000}
allowed=${ALLOWED_WARNINGS-AUTH_INSECURE_KEYS_ALLOWED AUTH_INSECURE_KEYS_CREATABLE}
work=$(sudo mktemp -d /mnt/upgrade-test.XXXX)
sudo chown "$USER" "$work"
mkdir -p "$art/before" "$art/after"
reg=localhost:5000
to_image=$reg/ceph-nix:upgrade
tool_image=
# shellcheck source=lib.sh
. "$here/lib.sh"
# a hung command (kernel mounts can sit in D state) must leave evidence: process states and kernel log every 5 minutes
( while sleep 300; do
	echo "::group::watchdog $(date +%T)"
	ps -eo pid,stat,wchan:32,etime,cmd | awk 'NR == 1 || $2 ~ /^D/ || /mount|umount|rbd|podman exec/' | cut -c1-200
	sudo dmesg | tail -n 30
	echo "::endgroup::"
done ) &
watchdog=$!
trap 'rc=$?; kill $watchdog 2>/dev/null; [ $rc -eq 0 ] || collect; exit $rc' EXIT

summary() { echo "$*" | tee -a "${GITHUB_STEP_SUMMARY:-/dev/null}"; }
new_toolbox() { # new_toolbox IMAGE: admin container from that image
	sudo podman rm -f toolbox >/dev/null 2>&1 || true
	tool_image=$1
	sudo podman run -d --name toolbox --net=host --privileged -v /etc/ceph:/etc/ceph --entrypoint sleep "$tool_image" infinity >/dev/null
}
# put_files DIR LISTFILE: random files written through the mount, with their md5s
put_files() {
	sudo mkdir -p "$1/sub"
	sudo dd if=/dev/urandom of="$1/big" bs=1M count=48 conv=fsync status=none
	sudo dd if=/dev/urandom of="$1/sub/small" bs=4k count=3 conv=fsync status=none
	echo "hello $RANDOM" | sudo tee "$1/sub/text" >/dev/null
	(cd "$1" && sudo md5sum big sub/small sub/text) >"$2"
}
check_files() { (cd "$1" && sudo md5sum -c "$2"); }
# soft and KILL: a mount against a dead server must not hang the job (D state)
mount_nfs() { sudo timeout -s KILL 30 mount -t nfs -o nfsvers=4.1,proto=tcp,retry=0,soft,timeo=100,retrans=2 "$ip:/cephfs" /mnt/nfs; }
# mounts and mapped devices, so the same checks run before and after
rbd_mount() { rbd_dev=$(rbdh map rbd/test); sudo mkdir -p /mnt/rbd; sudo mount "$rbd_dev" /mnt/rbd; }
rbd_umount() { sudo umount /mnt/rbd; rbdh unmap "$rbd_dev"; }
orch_ps() { tbx ceph orch ps --refresh -f json; }
snapshot() { # snapshot DIR: the state that must survive
	tbx ceph versions -f json >"$1/versions.json"
	orch_ps >"$1/orch-ps.json"
	tbx ceph config dump -f json >"$1/config.json"
	tbx ceph mgr module ls -f json >"$1/modules.json"
	sudo find "/var/lib/ceph/$fsid" -printf '%U:%G %P\n' 2>/dev/null | sort -k2 >"$1/owners.txt" || true
	sudo ls "/var/lib/ceph/$fsid" | grep '^cephadm\.' >"$1/cephadm-binaries.txt" || true
}
# upgrade_wait LABEL: poll `ceph orch upgrade status` until it finishes; 1 on error state or timeout
upgrade_wait() {
	local label=$1 t0=$SECONDS st health bad
	while ((SECONDS - t0 < limit)); do
		sleep 20
		if ! st=$(timeout 90 sudo podman exec toolbox ceph orch upgrade status -f json 2>/dev/null); then
			echo "[$label +$((SECONDS - t0))s] upgrade status unavailable (mgr restarting?)"
			continue
		fi
		# once finished, cephadm answers in plain text rather than JSON
		if grep -q 'no upgrades in progress' <<<"$st"; then
			echo "[$label +$((SECONDS - t0))s] $st"
			upgrade_secs=$((SECONDS - t0))
			return 0
		fi
		if ! jq -e . <<<"$st" >/dev/null 2>&1; then
			echo "[$label +$((SECONDS - t0))s] unparseable upgrade status: $st"
			continue
		fi
		health=$(timeout 90 sudo podman exec toolbox ceph health detail -f json 2>/dev/null | jq -r '.checks // {} | keys | join(",")' || true)
		echo "[$label +$((SECONDS - t0))s] $(jq -c '{in_progress, progress, message, is_paused}' <<<"$st") health=[$health]"
		bad=$(tr ',' '\n' <<<"$health" | grep '^UPGRADE_' | grep -vx UPGRADE_NO_STANDBY_MGR || true)
		if [ -n "$bad" ] || [ "$(jq .is_paused <<<"$st")" = true ]; then
			echo "upgrade error state: $bad"
			timeout 90 sudo podman exec toolbox ceph health detail || true
			return 1
		fi
		if [ "$(jq .in_progress <<<"$st")" = false ]; then
			upgrade_secs=$((SECONDS - t0))
			return 0
		fi
	done
	echo "upgrade timed out after ${limit}s"
	return 1
}
# no health check outside $allowed
health_ok_allowed() {
	local n
	n=$(sudo podman exec toolbox ceph health detail -f json | jq --arg a "$allowed" '[.checks // {} | keys[] | select(. as $k | ($a | split(" ") | index($k)) == null)] | length') || return 1
	[ "$n" = 0 ]
}
settle() { # settle SECONDS [health_fn]: 3 OSDs up and healthy
	wait_for 600 "3 OSDs up" osds_up
	wait_for "${1:-900}" "healthy (${2:-health_ok})" "${2:-health_ok}" || { tbx ceph health detail; return 1; }
}

step "host packages, registry"
host_setup
registry_setup
endstep

step "images: FROM $from, TO $tarball"
if [ -f "$from" ]; then
	from_image=$reg/ceph-from:test
	loaded=$(zstd -dcf "$from" | sudo podman load | sed -n 's/^Loaded image: //p' | head -n1)
	sudo podman tag "$loaded" "$from_image"
	sudo podman push --tls-verify=false "$from_image"
	rollback=${ROLLBACK_IMAGE-}
else
	from_image=$from
	sudo podman pull -q "$from_image"
	rollback=${ROLLBACK_IMAGE-$from_image}
fi
loaded=$(zstd -dcf "$tarball" | sudo podman load | sed -n 's/^Loaded image: //p' | head -n1)
sudo podman tag "$loaded" "$to_image"
sudo podman push --tls-verify=false "$to_image"
# the hosts must pull it from the registry like any user's would
sudo podman rmi "$loaded" "$to_image" >/dev/null
# the cephadm the starting image ships, as a user would have it
sudo podman run --rm --entrypoint cat "$from_image" /usr/sbin/cephadm >"$work/cephadm"
chmod +x "$work/cephadm"
sudo "$work/cephadm" version
# versions we expect after: what our image reports as `ceph --version`
sudo podman pull -q "$to_image" >/dev/null
want_version=$(sudo podman run --rm --entrypoint ceph "$to_image" --version | sed -E 's/^(ceph version [^ ]+ \([0-9a-f]+\)).*/\1/')
want_cephadm=$(sudo podman run --rm --entrypoint cat "$to_image" /usr/sbin/cephadm | sha256sum | cut -d' ' -f1)
want_id=$(sudo podman image inspect --format '{{.Id}}' "$to_image")
echo "target: $want_version, image id $want_id, cephadm sha256 $want_cephadm"
endstep

step "bootstrap on $from_image"
ip=$(hostname -I | awk '{print $1}')
sudo "$work/cephadm" --image "$from_image" bootstrap --mon-ip "$ip" --single-host-defaults --skip-monitoring-stack \
	--initial-dashboard-user admin --initial-dashboard-password 'Admin-pass-1' --dashboard-password-noupdate \
	--allow-fqdn-hostname --no-cleanup-on-failure
new_toolbox "$from_image"
fsid=$(tbx ceph fsid)
tbx ceph versions
loop_osds
settle 600
tbx ceph -s
endstep

step "seed data"
# erasure-coded pool
tbx ceph osd erasure-code-profile set ec21 k=2 m=1 crush-failure-domain=osd
tbx ceph osd pool create ecpool 8 8 erasure ec21 >/dev/null
tbx ceph osd pool application enable ecpool rados
tbx ceph osd pool set ecpool allow_ec_overwrites true
head -c 8M /dev/urandom >"$work/ec.in"
sudo podman cp "$work/ec.in" toolbox:/tmp/ec.in
tbx rados -p ecpool put obj /tmp/ec.in
# rbd + ext4
tbx ceph osd pool create rbd 8 >/dev/null
tbx rbd pool init rbd
tbx rbd create rbd/test --size 1G
rbd_dev=$(rbdh map rbd/test)
sudo mkfs.ext4 -q "$rbd_dev"
sudo mkdir -p /mnt/rbd
sudo mount "$rbd_dev" /mnt/rbd
put_files /mnt/rbd "$work/rbd.md5"
rbd_umount
# cephfs, kernel mount
tbx ceph fs volume create cephfs
wait_for 300 "mds active" mds_active
sudo mkdir -p /mnt/cephfs /mnt/nfs
key=$(tbx ceph auth get-key client.admin)
sudo mount --bind /mnt/cephfs /mnt/cephfs
sudo mount --make-shared /mnt/cephfs
wait_for 180 "cephfs mount" mount_cephfs
put_files /mnt/cephfs/fsdata "$work/cephfs.md5"
sudo umount /mnt/cephfs
# rgw + S3
tbx ceph orch apply rgw test --placement=1 --port=8080
wait_for 300 "rgw running" daemon_running rgw
wait_for 120 "rgw answering" curl -sf "http://$ip:8080/"
tbx radosgw-admin user create --uid=t --display-name=t --access-key=AKIATEST --secret=SECRETTEST >/dev/null
cat >"$work/s3.py" <<'PY'
import hashlib, io, json, os, sys
import boto3

mode, endpoint, path = sys.argv[1:4]
s3 = boto3.client("s3", endpoint_url=endpoint, aws_access_key_id="AKIATEST", aws_secret_access_key="SECRETTEST",
                  region_name="us-east-1")
md5 = lambda b: hashlib.md5(b).hexdigest()
if mode == "put":
    s3.create_bucket(Bucket="upg")
    sums = {}
    for key, size in (("small", 100), ("medium", 1 << 20), ("big-multipart", 20 << 20)):
        body = os.urandom(size)
        s3.upload_fileobj(io.BytesIO(body), "upg", key)  # multipart above 8 MiB
        sums[key] = md5(body)
    json.dump(sums, open(path, "w"))
else:
    for key, want in json.load(open(path)).items():
        got = md5(s3.get_object(Bucket="upg", Key=key)["Body"].read())
        assert got == want, f"{key}: {got} != {want}"
        print("s3 ok", key)
PY
python3 "$work/s3.py" put "http://$ip:8080" "$work/s3.json"
# nfs on cephfs
tbx ceph mgr module enable nfs || true
tbx ceph nfs cluster create nfs1 "1 $(hostname)"
wait_for 300 "nfs running" daemon_running nfs
tbx ceph nfs export create cephfs --cluster-id nfs1 --pseudo-path /cephfs --fsname cephfs
if ! wait_for 30 "nfs live export reload" mount_nfs; then
	echo "NOTE: ganesha did not load the new export live; restarting the nfs service"
	tbx ceph orch restart nfs.nfs1
	sleep 20
	wait_for 300 "nfs running again" daemon_running nfs
	wait_for 120 "nfs mount" mount_nfs
fi
put_files /mnt/nfs/nfsdata "$work/nfs.md5"
sudo umount /mnt/nfs
# config options and mgr modules that must survive the switch
tbx ceph config set osd osd_max_backfills 3
tbx ceph config set mon mon_allow_pool_delete true
tbx ceph config set global mon_max_pg_per_osd 350
tbx ceph config set mgr mgr_stats_period 7
tbx ceph mgr module enable iostat
tbx ceph mgr module enable insights
settle 600
echo "== before"
tbx ceph -s
orch_ps | jq -r '.[] | [.daemon_name, .version, .status_desc, .container_image_name] | @tsv'
snapshot "$art/before"
jq -r '.overall | keys[]' "$art/before/versions.json"
endstep

step "ceph orch upgrade start --image $to_image"
tbx ceph orch upgrade check --image "$to_image" || true
t_start=$SECONDS
tbx ceph orch upgrade start --image "$to_image"
upgrade_wait upgrade || { tbx ceph orch upgrade status || true; tbx ceph log last 200 info cephadm || true; false; }
upgrade_secs=${upgrade_secs:-$((SECONDS - t_start))}
summary "upgrade FROM $from_image to $to_image took ${upgrade_secs}s"
new_toolbox "$to_image"
tbx ceph orch upgrade status
tbx ceph log last 200 info cephadm >"$art/after/cephadm-log.txt" || true
endstep

step "after: health, versions, images"
settle 900 health_ok_allowed
tbx ceph -s
tbx ceph health detail || true
echo "== warnings still present (allowed: ${allowed:-none})"
tbx ceph health detail -f json | jq -r '.checks // {} | keys[]' | tee "$art/after/health-checks.txt"
tbx ceph config dump >"$art/after/config-dump.txt" || true
tbx ceph config ls 2>/dev/null | grep -iE 'insecure|cipher' | tee "$art/after/auth-options.txt" || true
tbx ceph config show "mon.$(hostname)" 2>/dev/null | grep -iE 'insecure|cipher' || true
snapshot "$art/after"
orch_ps | jq -r '.[] | [.daemon_name, .version, .status_desc, .container_image_name] | @tsv'
# every daemon on our image id and name
bad=$(jq -r --arg id "$want_id" '.[] | select(((.container_image_id // "") | ltrimstr("sha256:")) != $id or ((.container_image_name // "") | contains("ceph-nix") | not)) | "\(.daemon_name) \(.container_image_id) \(.container_image_name)"' "$art/after/orch-ps.json")
[ -z "$bad" ] || { echo "daemons not on our image:"; echo "$bad"; exit 1; }
[ "$(jq length "$art/after/orch-ps.json")" -ge 8 ]
# ceph versions: a single version, ours
[ "$(jq '.overall | length' "$art/after/versions.json")" = 1 ]
got_version=$(jq -r '.overall | keys[0]' "$art/after/versions.json" | sed -E 's/^(ceph version [^ ]+ \([0-9a-f]+\)).*/\1/')
[ "$got_version" = "$want_version" ] || { echo "version $got_version != $want_version"; exit 1; }
[ "$(tbx ceph config get mgr container_image | tr -d '\r')" != "$from_image" ]
endstep

step "after: data intact"
PS4='+ [$(date +%T)] '
set -x
tbx rados -p ecpool get obj /tmp/ec.out
sudo podman cp toolbox:/tmp/ec.out "$work/ec.out"
cmp "$work/ec.in" "$work/ec.out"
rbd_mount
check_files /mnt/rbd "$work/rbd.md5"
rbd_umount
key=$(tbx ceph auth get-key client.admin)
wait_for 180 "cephfs mount" mount_cephfs
check_files /mnt/cephfs/fsdata "$work/cephfs.md5"
sudo umount /mnt/cephfs
wait_for 120 "nfs mount" mount_nfs || {
	echo "nfs mount failed after the upgrade; ganesha state:"
	tbx ceph nfs cluster info nfs1 || true
	tbx ceph nfs export ls nfs1 --detailed || true
	tbx ceph orch ps --daemon-type nfs || true
	sudo ss -ltnp | grep -E ':2049' || echo "nothing listens on 2049"
	sudo "$work/cephadm" logs --name "$(tbx ceph orch ps --daemon-type nfs -f json | jq -r '.[0].daemon_name')" 2>&1 | tail -80 || true
	exit 1
}
# a restarted ganesha is in its grace period for a while; reads must come back within a few minutes, never hang
nfs_read() { (cd /mnt/nfs/nfsdata && sudo timeout -s KILL 20 md5sum -c "$work/nfs.md5"); }
nfs_failed=
if ! wait_for 300 "nfs read" nfs_read; then
	nfs_failed=1
	summary "NFS: data unreadable after the upgrade (ganesha $(tbx ceph orch ps --daemon-type nfs -f json | jq -r '.[0].version'))"
	tbx ceph orch ps --daemon-type nfs || true
	tbx rados -p .nfs -N nfs1 ls || true
	tbx ganesha-rados-grace --pool .nfs --ns nfs1 --cephconf /etc/ceph/ceph.conf || true
	sudo timeout 60 "$work/cephadm" logs --name "$(tbx ceph orch ps --daemon-type nfs -f json | jq -r '.[0].daemon_name')" 2>&1 | tail -150 || true
	sudo timeout 20 dmesg | grep -iE 'nfs|rpc' | tail -30 || true
	sudo umount -f -l /mnt/nfs || true
	# informational: does restarting the service bring it back?
	tbx ceph orch restart nfs.nfs1 || true
	sleep 30
	wait_for 300 "nfs running again" daemon_running nfs || true
	if wait_for 120 "nfs remount" mount_nfs && wait_for 300 "nfs read after restart" nfs_read; then
		summary "NFS: readable again after ceph orch restart nfs.nfs1"
	else
		summary "NFS: still unreadable after ceph orch restart nfs.nfs1"
	fi
	sudo umount -f -l /mnt/nfs || true
else
	sudo umount /mnt/nfs
fi
python3 "$work/s3.py" get "http://$ip:8080" "$work/s3.json"
set +x
# and the upgraded cluster takes new writes
tbx ceph osd pool create post 8 >/dev/null
tbx ceph osd pool application enable post rados
tbx rados bench -p post 5 write --no-cleanup
tbx rados bench -p post 3 seq
endstep

step "after: config and mgr modules persisted"
[ "$(tbx ceph config get osd osd_max_backfills)" = 3 ]
[ "$(tbx ceph config get mon mon_allow_pool_delete)" = true ]
[ "$(tbx ceph config get global mon_max_pg_per_osd)" = 350 ]
[ "$(tbx ceph config get mgr mgr_stats_period)" = 7 ]
# every explicitly set option from before is still there with the same value (cephadm's own tuning excluded)
keep='[.[] | select(.name != "container_image" and .name != "osd_memory_target") | [.section, .name, .value]]'
lost=$(jq -n --argjson a "$(jq "$keep" "$art/before/config.json")" --argjson b "$(jq "$keep" "$art/after/config.json")" '$a - $b | .[] | @tsv' -r)
[ -z "$lost" ] || { echo "config entries lost or changed:"; echo "$lost"; exit 1; }
jq -r '.enabled_modules[]' "$art/before/modules.json" | sort >"$work/mods.before"
jq -r '.enabled_modules[]' "$art/after/modules.json" | sort >"$work/mods.after"
missing=$(comm -23 "$work/mods.before" "$work/mods.after")
[ -z "$missing" ] || { echo "mgr modules no longer enabled: $missing"; exit 1; }
grep -qx iostat "$work/mods.after"
grep -qx insights "$work/mods.after"
# no module that could run before may be unable to run now
cannot() { jq -r '.disabled_modules[] | select(.can_run == false) | .name' "$1" | sort; }
cannot "$art/before/modules.json" >"$work/cannot.before"
cannot "$art/after/modules.json" >"$work/cannot.after"
echo "modules that cannot run: before=[$(tr '\n' ' ' <"$work/cannot.before")] after=[$(tr '\n' ' ' <"$work/cannot.after")]"
regress=$(comm -13 "$work/cannot.before" "$work/cannot.after")
[ -z "$regress" ] || { echo "mgr modules that can no longer run: $regress"; exit 1; }
if tbx ceph health detail | grep -E 'MGR_MODULE_(ERROR|DEPENDENCY)'; then exit 1; fi
endstep

step "after: cephadm binary comes from our image, ownership unchanged"
echo "cephadm binaries before: $(tr '\n' ' ' <"$art/before/cephadm-binaries.txt")"
echo "cephadm binaries after:  $(tr '\n' ' ' <"$art/after/cephadm-binaries.txt")"
grep -qx "cephadm.$want_cephadm" "$art/after/cephadm-binaries.txt"
[ "$(sudo sha256sum "/var/lib/ceph/$fsid/cephadm.$want_cephadm" | cut -d' ' -f1)" = "$want_cephadm" ]
sudo "/var/lib/ceph/$fsid/cephadm.$want_cephadm" version
# same owner for every path that was there before; nothing new owned by an id that was not there before
awk 'NR == FNR { o[$2] = $1; next } ($2 in o) && o[$2] != $1 { print "owner changed:", $0, "was", o[$2] }' \
	"$art/before/owners.txt" "$art/after/owners.txt" | tee "$work/owner-diff.txt"
cut -d' ' -f1 "$art/before/owners.txt" | sort -u >"$work/owners.before"
cut -d' ' -f1 "$art/after/owners.txt" | sort -u >"$work/owners.after"
[ ! -s "$work/owner-diff.txt" ] || exit 1
[ -z "$(comm -13 "$work/owners.before" "$work/owners.after")" ] || { echo "new owner ids under /var/lib/ceph/$fsid"; exit 1; }
for d in $(sudo ls "/var/lib/ceph/$fsid" | grep -E '^(mon|mgr|osd|crash)\.'); do
	[ "$(sudo stat -c %u:%g "/var/lib/ceph/$fsid/$d")" = 167:167 ] || { echo "$d not owned by 167:167"; exit 1; }
done
[ -z "$(sudo find "/var/lib/ceph/$fsid"/mon.*/store.db ! -user 167)" ]
endstep

step "after: daemons survive a restart of the mon and osd services"
before_started=$(orch_ps | jq -S 'map(select(.daemon_type == "mon" or .daemon_type == "osd") | {(.daemon_name): .started}) | add')
tbx ceph orch restart mon
osd_svc=$(tbx ceph orch ls --service-type osd -f json | jq -r '.[0].service_name // empty')
if [ -n "$osd_svc" ]; then
	tbx ceph orch restart "$osd_svc"
else
	for i in 0 1 2; do tbx ceph orch daemon restart "osd.$i"; done
fi
restarted() {
	local now
	now=$(orch_ps | jq -S 'map(select(.daemon_type == "mon" or .daemon_type == "osd") | {(.daemon_name): .started}) | add') || return 1
	[ "$now" != "$before_started" ] && jq -e 'all(.[]; .status_desc == "running")' <(orch_ps) >/dev/null &&
		[ "$(jq -n --argjson a "$before_started" --argjson b "$now" '[$b | to_entries[] | select($a[.key] == .value)] | length')" = 0 ]
}
wait_for 600 "mon and osd daemons restarted and running" restarted || { orch_ps | jq -r '.[] | [.daemon_name, .status_desc, .started] | @tsv'; exit 1; }
settle 600 health_ok_allowed
tbx ceph -s
endstep

step "informational: rollback to ${rollback:-<skipped>}"
rollback_info() {
	[ -n "$rollback" ] || { summary "rollback: skipped"; return 0; }
	local t0=$SECONDS id bad
	tbx ceph orch upgrade start --image "$rollback" || { summary "rollback: upgrade start refused"; return 1; }
	upgrade_wait rollback || { summary "rollback: FAILED (error state or timeout)"; return 1; }
	new_toolbox "$from_image"
	id=$(sudo podman image inspect --format '{{.Id}}' "$rollback")
	bad=$(orch_ps | jq -r --arg id "$id" '.[] | select(((.container_image_id // "") | ltrimstr("sha256:")) != $id) | .daemon_name')
	tbx ceph versions
	tbx ceph -s
	if [ -n "$bad" ]; then summary "rollback: finished in $((SECONDS - t0))s but daemons not on $rollback: $bad"; return 1; fi
	summary "rollback to $rollback: OK in $((SECONDS - t0))s, health: $(tbx ceph health detail | head -3 | tr '
' ' ')"
}
rollback_info || summary "rollback result: NOT OK (informational, not gating)"
endstep

[ -z "$nfs_failed" ] || { summary "RESULT upgrade: NFS data unreadable after the upgrade (all other checks passed)"; exit 1; }
summary "RESULT upgrade $from_image -> $to_image OK in ${upgrade_secs}s; warnings after: $(tr '
' ' ' <"$art/after/health-checks.txt")"
