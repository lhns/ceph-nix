#!/usr/bin/env bash
# Functional test of the image through cephadm, on a throwaway Ubuntu runner (ADR 0006).
#   cephadm.sh IMAGE_TARBALL        docker-archive tarball, optionally zstd-compressed
# Env: SKIP_ISCSI=1           skip the iSCSI gateway leg (images without ceph-iscsi)
#      ARTIFACT_DIR            where logs go on failure (default ./cephadm-logs)
# Allowed health warnings: none, except ALLOWED_WARNINGS (space separated check names) and the known nfs-ganesha
# stray (tests/lib.sh) at the end. HEALTH_OK is required after the OSDs are up.
set -Eeuo pipefail
tarball=$(realpath "$1")
here=$(cd "$(dirname "$0")" && pwd)
art=${ARTIFACT_DIR:-$PWD/cephadm-logs}
work=$(sudo mktemp -d /mnt/cephadm-test.XXXX)
sudo chown "$USER" "$work"
mkdir -p "$art"
tool_image=localhost:5000/ceph:test
# shellcheck source=lib.sh
. "$here/lib.sh"
trap 'rc=$?; [ $rc -eq 0 ] || collect; exit $rc' EXIT

# grep -q on a pipe can SIGPIPE the producer, which pipefail turns into a failure: capture first
exporter_up() { local m; m=$(curl -sf http://127.0.0.1:9926/metrics) && grep -q '^ceph_' <<<"$m"; }
# cephadm sets osd_memory_target for the host (section osd, mask host:<name>) from the host's memory
osd_target() { tbx ceph config dump -f json | jq -r '[.[] | select(.name == "osd_memory_target" and (.mask | startswith("host:")))][0].value // empty'; }
osd_target_set() { [ -n "$(osd_target)" ]; }
osd_target_live() { # the OSD runs with the value cephadm set
	local live
	live=$(tbx ceph tell osd.0 config get osd_memory_target -f json | jq -r .osd_memory_target)
	[ "$live" = "$(osd_target)" ]
}

step "host packages"
host_setup open-iscsi "target_core_user iscsi_target_mod iscsi_tcp"
endstep

step "registry and image"
registry_setup
loaded=$(zstd -dcf "$tarball" | sudo podman load | sed -n 's/^Loaded image: //p' | head -n1)
echo "loaded $loaded"
sudo podman tag "$loaded" "$tool_image"
sudo podman push --tls-verify=false "$tool_image"
# the cephadm shipped in the image, as the orchestrator would use it
sudo podman run --rm --entrypoint cat "$tool_image" /usr/sbin/cephadm >"$work/cephadm"
chmod +x "$work/cephadm"
sudo "$work/cephadm" version
endstep

step "device-light: decision logic with a fake lsmcli"
ENGINE="sudo podman" "$here/device-light.sh" "$tool_image"
endstep

step "bootstrap"
ip=$(hostname -I | awk '{print $1}')
sudo "$work/cephadm" --image "$tool_image" bootstrap --mon-ip "$ip" --single-host-defaults --skip-monitoring-stack \
	--initial-dashboard-user admin --initial-dashboard-password 'Admin-pass-1' --dashboard-password-noupdate \
	--skip-pull --allow-fqdn-hostname --no-cleanup-on-failure
sudo podman run -d --name toolbox --net=host --privileged -v /etc/ceph:/etc/ceph --entrypoint sleep "$tool_image" infinity >/dev/null
tbx ceph -s
tbx ceph versions
endstep

step "OSDs on three loop-backed LVs"
loop_osds
wait_for 300 "3 OSDs up" osds_up
wait_for 600 "HEALTH_OK" health_ok || { tbx ceph health detail; exit 1; }
tbx ceph -s
endstep

# three small OSDs: the pools rgw, cephfs and nfs create (the autoscaler grows them) would trip TOO_MANY_PGS
tbx ceph config set global mon_max_pg_per_osd 1000

step "tcmalloc: heap stats and memory autotuning"
# a build with jemalloc or libc answers "tcmalloc not enabled, can't use heap profiler commands"
heap=$(tbx ceph tell osd.0 heap stats)
echo "$heap"
grep -q 'tcmalloc heap stats' <<<"$heap"
grep -q 'MALLOC:' <<<"$heap"
tbx ceph config set osd osd_memory_target_autotune true
wait_for 600 "cephadm sets osd_memory_target for the host" osd_target_set || { tbx ceph config dump; exit 1; }
tbx ceph config dump | grep osd_memory_target
wait_for 120 "osd.0 runs with that osd_memory_target" osd_target_live || { tbx ceph tell osd.0 config get osd_memory_target; exit 1; }
tbx ceph orch ps --daemon-type osd -f json | jq -c '.[] | {daemon_name, memory_usage, memory_request}' || true
endstep

step "mgr modules: none that cannot run, no MGR_MODULE_ERROR"
tbx ceph mgr module ls -f json >"$work/modules.json"
jq -r '.disabled_modules[] | select(.can_run == false) | "\(.name): \(.error_string)"' "$work/modules.json" | tee "$work/cannot-run.txt"
# modules that cannot run in the upstream image either, each with a reason
unexpected=$(cut -d: -f1 "$work/cannot-run.txt" | grep -vxFf <(sed 's/[[:space:]]*#.*//; /^$/d' "$here/cephadm-cannot-run.txt") || true)
[ -z "$unexpected" ] || { echo "mgr modules that cannot run: $unexpected"; exit 1; }
# not `! cmd`: set -e ignores a negated command
health=$(tbx ceph health detail)
if grep -E 'MGR_MODULE_(ERROR|DEPENDENCY)' <<<"$health"; then echo "mgr module errors in the health"; exit 1; fi
endstep

step "rados bench"
tbx ceph osd pool create bench 8 >/dev/null
tbx ceph osd pool application enable bench rados
tbx rados bench -p bench 10 write --no-cleanup
tbx rados bench -p bench 5 seq
tbx rados -p bench cleanup
tbx ceph config set mon mon_allow_pool_delete true
# the 3-OSD test cluster is close to mon_max_pg_per_osd (TOO_MANY_PGS is a health warning): drop scratch pools
tbx ceph osd pool rm bench bench --yes-i-really-really-mean-it
endstep

step "erasure-coded pool k=2 m=1"
tbx ceph osd erasure-code-profile set ec21 k=2 m=1 crush-failure-domain=osd
tbx ceph osd pool create ecpool 8 8 erasure ec21 >/dev/null
tbx ceph osd pool application enable ecpool rados
tbx ceph osd pool set ecpool allow_ec_overwrites true
head -c 8M /dev/urandom >"$work/ec.in"
sudo podman cp "$work/ec.in" toolbox:/tmp/ec.in
tbx rados -p ecpool put obj /tmp/ec.in
tbx rados -p ecpool get obj /tmp/ec.out
sudo podman cp toolbox:/tmp/ec.out "$work/ec.out"
cmp "$work/ec.in" "$work/ec.out"
tbx ceph osd pool rm ecpool ecpool --yes-i-really-really-mean-it
endstep

step "rbd: krbd map, mkfs.ext4, I/O"
tbx ceph osd pool create rbd 8 >/dev/null
tbx rbd pool init rbd
tbx rbd create rbd/test --size 1G
dev=$(rbdh map rbd/test)
sudo mkfs.ext4 -q "$dev"
sudo mkdir -p /mnt/rbd
sudo mount "$dev" /mnt/rbd
sudo dd if=/dev/urandom of=/mnt/rbd/file bs=1M count=64 conv=fsync status=none
sudo sha256sum /mnt/rbd/file >"$work/rbd.sum"
sudo umount /mnt/rbd
sudo mount "$dev" /mnt/rbd
sudo sha256sum -c "$work/rbd.sum"
sudo umount /mnt/rbd
rbdh unmap "$dev"
endstep

step "cephfs: volume create, kernel mount, I/O"
tbx ceph fs volume create cephfs
wait_for 300 "mds active" mds_active
sudo mkdir -p /mnt/cephfs
# Tentacle's new cephx key type is beyond the host's older mount.ceph, so mount with our image's mount.ceph from a
# container whose mount propagates to the host.
key=$(tbx ceph auth get-key client.admin)
sudo mount --bind /mnt/cephfs /mnt/cephfs
sudo mount --make-shared /mnt/cephfs
wait_for 180 "cephfs mount" mount_cephfs
sudo dd if=/dev/urandom of=/mnt/cephfs/file bs=1M count=64 conv=fsync status=none
sudo sha256sum /mnt/cephfs/file >"$work/cephfs.sum"
sudo umount /mnt/cephfs
mount_cephfs
sudo sha256sum -c "$work/cephfs.sum"
sudo umount /mnt/cephfs
endstep

step "rgw: S3 put/get and a lua script"
tbx ceph orch apply rgw test --placement=1 --port=8080
wait_for 300 "rgw running" daemon_running rgw
wait_for 120 "rgw answering" curl -sf "http://$ip:8080/"
tbx radosgw-admin user create --uid=t --display-name=t --access-key=AKIATEST --secret=SECRETTEST >/dev/null
printf 'RGWDebugLog("lua-hook-ran " .. Request.HTTP.Method)\n' >"$work/hook.lua"
sudo podman cp "$work/hook.lua" toolbox:/tmp/hook.lua
tbx radosgw-admin script put --infile=/tmp/hook.lua --context=preRequest
script=$(tbx radosgw-admin script get --context=preRequest)
grep -q lua-hook-ran <<<"$script"
tbx ceph config set client.rgw debug_rgw 20
python3 - "$ip" <<'PY'
import sys
import boto3

s3 = boto3.client("s3", endpoint_url=f"http://{sys.argv[1]}:8080", aws_access_key_id="AKIATEST",
                  aws_secret_access_key="SECRETTEST", region_name="us-east-1")
s3.create_bucket(Bucket="testbucket")
s3.put_object(Bucket="testbucket", Key="k", Body=b"hello rgw")
assert s3.get_object(Bucket="testbucket", Key="k")["Body"].read() == b"hello rgw"
print("s3 ok")
PY
sleep 5
rgw_log=$(sudo journalctl --no-pager -t radosgw)
grep -q 'Lua INFO: lua-hook-ran' <<<"$rgw_log"
endstep

step "nfs: cluster, export, mount, I/O"
tbx ceph mgr module enable nfs || true
tbx ceph nfs cluster create nfs1 "1 $(hostname)"
wait_for 300 "nfs running" daemon_running nfs
tbx ceph nfs export create cephfs --cluster-id nfs1 --pseudo-path /cephfs --fsname cephfs
sudo mkdir -p /mnt/nfs
mount_nfs() { timeout 30 sudo mount -v -t nfs -o nfsvers=4.1,proto=tcp,retry=0 "$ip:/cephfs" /mnt/nfs 2>&1 | tee -a "$art/nfs-mount.log"; [ "${PIPESTATUS[0]}" = 0 ]; }
# Ganesha picks a new export up through its RADOS watch; if that didn't happen (noted in the log), restart the daemon.
if ! wait_for 30 "nfs live export reload" mount_nfs; then
	echo "NOTE: ganesha did not load the new export live; restarting the nfs service"
	tbx ceph orch restart nfs.nfs1
	sleep 20
	wait_for 300 "nfs running again" daemon_running nfs
fi
wait_for 120 "nfs mount" mount_nfs || { cat "$art/nfs-mount.log"; tbx ceph nfs export ls nfs1 --detailed; tbx ceph nfs cluster info nfs1; false; }
sudo dd if=/dev/urandom of=/mnt/nfs/nfsfile bs=1M count=32 conv=fsync status=none
sudo sha256sum /mnt/nfs/nfsfile >"$work/nfs.sum"
sudo umount /mnt/nfs
mount_nfs
sudo sha256sum -c "$work/nfs.sum"
sudo umount /mnt/nfs
endstep

step "nfs: service map and cephadm's stray check (mgr failover)"
stray_check_now
endstep

step "nfs: RGW export (FSAL_RGW), mount, I/O, seen through S3"
python3 - "$ip" <<'PY'
import sys
import boto3

s3 = boto3.client("s3", endpoint_url=f"http://{sys.argv[1]}:8080", aws_access_key_id="AKIATEST",
                  aws_secret_access_key="SECRETTEST", region_name="us-east-1")
s3.create_bucket(Bucket="nfsbucket")
PY
# the export's user is the bucket's owner (t)
tbx ceph nfs export create rgw --cluster-id nfs1 --pseudo-path /rgw --bucket nfsbucket
sudo mkdir -p /mnt/nfsrgw
mount_nfs_rgw() { timeout 30 sudo mount -v -t nfs -o nfsvers=4.1,proto=tcp,retry=0 "$ip:/rgw" /mnt/nfsrgw 2>&1 | tee -a "$art/nfs-rgw-mount.log"; [ "${PIPESTATUS[0]}" = 0 ]; }
if ! wait_for 30 "nfs live rgw export reload" mount_nfs_rgw; then
	echo "NOTE: ganesha did not load the new export live; restarting the nfs service"
	tbx ceph orch restart nfs.nfs1
	sleep 20
	wait_for 300 "nfs running again" daemon_running nfs
fi
wait_for 120 "nfs rgw mount" mount_nfs_rgw || {
	cat "$art/nfs-rgw-mount.log"
	tbx ceph nfs export ls nfs1 --detailed
	sudo podman logs "$(sudo podman ps -q --filter name=nfs.nfs1 | head -n1)" 2>&1 | tail -n 60 || true
	false
}
head -c 8M /dev/urandom >"$work/nfsrgw.in"
sudo cp "$work/nfsrgw.in" /mnt/nfsrgw/rgwfile
sudo umount /mnt/nfsrgw
want=$(md5sum <"$work/nfsrgw.in" | cut -d' ' -f1)
mount_nfs_rgw
got=$(sudo md5sum /mnt/nfsrgw/rgwfile | cut -d' ' -f1)
sudo umount /mnt/nfsrgw
[ "$got" = "$want" ] || { echo "md5 through NFS: $got, want $want"; exit 1; }
# and the file is an object in the bucket
python3 - "$ip" "$want" <<'PY'
import hashlib
import sys
import boto3

s3 = boto3.client("s3", endpoint_url=f"http://{sys.argv[1]}:8080", aws_access_key_id="AKIATEST",
                  aws_secret_access_key="SECRETTEST", region_name="us-east-1")
body = s3.get_object(Bucket="nfsbucket", Key="rgwfile")["Body"].read()
assert hashlib.md5(body).hexdigest() == sys.argv[2], "S3 object differs from what was written through NFS"
print("nfs-rgw ok")
PY
endstep

# the daemons start; replication between two clusters is not tested
step "rbd-mirror and cephfs-mirror"
tbx ceph orch apply rbd-mirror --placement=1
tbx ceph orch apply cephfs-mirror --placement=1
wait_for 300 "rbd-mirror running" daemon_running rbd-mirror
wait_for 300 "cephfs-mirror running" daemon_running cephfs-mirror
endstep

step "ceph-exporter metrics"
tbx ceph orch apply ceph-exporter
wait_for 60 "exporter" exporter_up
endstep

step "dashboard serves the Angular UI on 8443"
dashboard_ui() {
	local ui js
	ui=$(curl -sk --max-time 10 https://127.0.0.1:8443/) || return 1
	grep -q '<title>Ceph</title>' <<<"$ui" || return 1
	# the Angular app: its root element and a main bundle, which must be served
	js=$(grep -oE 'src="main[^"]*\.js"' <<<"$ui" | head -n1 | sed 's/^src="//; s/"$//')
	grep -q '<cd-root' <<<"$ui" || return 1
	[ -n "$js" ] || return 1
	[ "$(curl -sk --max-time 20 -o /dev/null -w '%{http_code}' "https://127.0.0.1:8443/$js")" = 200 ]
}
wait_for 120 "dashboard UI" dashboard_ui || { curl -sik --max-time 20 https://127.0.0.1:8443/ 2>&1 | head -c 3000; tbx ceph mgr services; false; }
endstep

step "dashboard REST API: auth, health, hosts, OSDs, NVMe-oF module"
printf 'Api-test-pass-1' >"$work/apipw"
sudo podman cp "$work/apipw" toolbox:/tmp/apipw
tbx ceph dashboard ac-user-create apitest -i /tmp/apipw administrator
api() { # api PATH: the body of a 200; the endpoints differ in the API version they accept
	local v code
	for v in 1.0 1.1 1.2 1.3; do
		code=$(curl -sk --max-time 60 -o "$work/api.out" -w '%{http_code}' -H "Accept: application/vnd.ceph.api.v$v+json" \
			-H "Authorization: Bearer $token" "https://127.0.0.1:8443$1")
		[ "$code" != 200 ] || { cat "$work/api.out"; return 0; }
		case $code in 406 | 415) ;; *) break ;; esac
	done
	echo "GET $1 -> $code: $(head -c 600 "$work/api.out")" >&2
	return 1
}
login() {
	token=$(curl -sk --max-time 30 -H 'Accept: application/vnd.ceph.api.v1.0+json' -H 'Content-Type: application/json' \
		-d '{"username":"apitest","password":"Api-test-pass-1"}' https://127.0.0.1:8443/api/auth | jq -er .token)
}
wait_for 120 "dashboard login" login || { curl -sik --max-time 30 -d '{}' -H 'Content-Type: application/json' https://127.0.0.1:8443/api/auth; false; }
api /api/health/full >"$work/api-health.json"
jq -e '(.health.status | test("^HEALTH_")) and (["osd_map", "pools", "mon_status"] - keys == [])' "$work/api-health.json" >/dev/null
api /api/host >"$work/api-host.json"
jq -e --arg h "$(hostname)" 'any(.[]; .hostname == $h)' "$work/api-host.json" >/dev/null || { cat "$work/api-host.json"; exit 1; }
api /api/osd >"$work/api-osd.json"
nosd=$(tbx ceph osd stat -f json | jq .num_osds)
jq -e --argjson n "$nosd" 'length == $n and all(.[]; .up == 1)' "$work/api-osd.json" >/dev/null || { cat "$work/api-osd.json"; exit 1; }
# The NVMe-oF controllers register only if the grpc client imports (grpcio in the mgr env): a missing module leaves
# the routes unregistered (404). No gateway is deployed, so the gateway query itself may fail, but not for that.
api /api/nvmeof/gateway/group >"$work/api-nvmeof-group.json"
code=$(curl -sk --max-time 60 -o "$work/api-nvmeof.out" -w '%{http_code}' -H 'Accept: application/vnd.ceph.api.v1.0+json' \
	-H "Authorization: Bearer $token" https://127.0.0.1:8443/api/nvmeof/gateway)
echo "GET /api/nvmeof/gateway -> $code: $(head -c 600 "$work/api-nvmeof.out")"
[ "$code" != 404 ]
if grep -Eiq 'ImportError|ModuleNotFound|No module named' "$work/api-nvmeof.out"; then
	echo "NVMe-oF dashboard API fails on a missing module"
	exit 1
fi
endstep

step "encrypted OSD (OSD spec encrypted: true) on a fourth loop-backed LV"
sudo truncate -s 12G /mnt/osd4.img
dev=$(sudo losetup -f --show /mnt/osd4.img)
sudo pvcreate "$dev" >/dev/null
sudo vgcreate vg4 "$dev" >/dev/null
sudo lvcreate -l 100%FREE -n lv vg4 >/dev/null
cat >"$work/osd-enc.yaml" <<EOF
service_type: osd
service_id: enc
placement:
  hosts:
    - $(hostname)
spec:
  data_devices:
    paths:
      - /dev/vg4/lv
  encrypted: true
EOF
sudo podman cp "$work/osd-enc.yaml" toolbox:/tmp/osd-enc.yaml
tbx ceph orch apply -i /tmp/osd-enc.yaml
osds_4_up() { [ "$(tbx ceph osd stat -f json | jq .num_up_osds)" = 4 ]; }
wait_for 600 "4 OSDs up" osds_4_up || { tbx ceph orch ls osd; tbx ceph orch ps --daemon-type osd; tbx ceph log last 30 cephadm; false; }
tags=$(sudo lvs --noheadings -o lv_tags /dev/vg4/lv)
echo "lv tags: $tags"
grep -q 'ceph.encrypted=1' <<<"$tags"
eid=$(grep -o 'ceph.osd_id=[0-9]*' <<<"$tags" | cut -d= -f2)
echo "encrypted OSD: osd.$eid"
# the dm-crypt mapping sits on the LV
lsblk -ln -o NAME,TYPE /dev/vg4/lv | tee "$work/lsblk-enc.txt"
grep -qw crypt "$work/lsblk-enc.txt"
tbx ceph osd metadata "$eid" -f json | jq -r '"\(.osd_objectstore) \(.devices) \(.bluestore_bdev_devices)"'
# I/O: the OSD's own write benchmark, and objects of a new pool land on it
tbx ceph tell "osd.$eid" bench 33554432 1048576 | tee "$work/enc-bench.json"
jq -e '.bytes_per_sec > 0' "$work/enc-bench.json" >/dev/null
tbx ceph osd pool create encio 16 >/dev/null
tbx ceph osd pool application enable encio rados
pid=$(tbx ceph osd pool ls detail -f json | jq '.[] | select(.pool_name == "encio") | .pool_id')
head -c 4M /dev/urandom >"$work/enc.in"
sudo podman cp "$work/enc.in" toolbox:/tmp/enc.in
for i in $(seq 1 20); do tbx rados -p encio put "o$i" /tmp/enc.in; done
on_enc() { [ "$(tbx ceph pg ls-by-osd "$eid" -f json | jq --arg p "$pid." '[.pg_stats[] | select(.pgid | startswith($p))] | length')" -gt 0 ]; }
wait_for 120 "encio PGs on osd.$eid" on_enc || { tbx ceph pg ls-by-osd "$eid"; false; }
tbx rados -p encio get o7 /tmp/enc.out
sudo podman cp toolbox:/tmp/enc.out "$work/enc.out"
cmp "$work/enc.in" "$work/enc.out"
tbx ceph osd pool rm encio encio --yes-i-really-really-mean-it
# PGs rebalance onto the new OSD; the cluster must settle with all PGs active+clean and healthy
allowed=${ALLOWED_WARNINGS-}
pgs_clean() { tbx ceph pg stat -f json | jq -e '.pg_summary | .num_pgs == ([.num_pg_by_state[] | select(.name == "active+clean") | .num] | add)'; }
wait_for 900 "all PGs active+clean" pgs_clean || { tbx ceph -s; tbx ceph pg dump_stuck; false; }
wait_for 300 "healthy (allowed: ${allowed:-none})" health_ok_allowed || { tbx ceph health detail; exit 1; }
tbx ceph osd tree
endstep

if [ "${SKIP_ISCSI:-}" != 1 ]; then
	step "iscsi: gateway, target, iscsiadm login, I/O"
	"$here/cephadm-iscsi.sh" "$ip" "$work"
	endstep
else
	echo "SKIP_ISCSI=1: iSCSI not exercised"
fi

step "libstoragemgmt: lsmd and the simulator plugin"
sudo podman run --rm --entrypoint /bin/bash "$tool_image" -c '(lsmd -d >/dev/null 2>&1 &); sleep 2; lsmcli -u sim:// list --type systems | grep -q sim-01'
endstep

step "disk locate LED: lsmcli cannot do it, so cephadm's command ends in a blinker container"
# What the mgr runs on the host is `cephadm shell --fsid FSID -- COMMAND` (blink_device_light); do the same with the
# command its template renders. The loop device has no LED control, so lsmcli refuses and device-light falls back.
fsid=$(tbx ceph fsid)
tbx /usr/libexec/ceph-nix/device-light install
tpl=$(tbx ceph config-key get mgr/cephadm/blink_device_light_cmd)
echo "template: $tpl"
rendered=$(tbx python3 -c 'import sys, jinja2; print(jinja2.Template(sys.argv[1]).render(on=True, ident_fault="ident", dev="sdb", path="/dev/sdb"))' "$tpl")
[ "$rendered" = "/usr/libexec/ceph-nix/device-light on ident '/dev/sdb'" ] || { echo "unexpected rendering: $rendered"; exit 1; }
# a device without a by-path link (the mgr's DeviceLightLoc has path='') renders as the bare kernel name
rendered=$(tbx python3 -c 'import sys, jinja2; print(jinja2.Template(sys.argv[1]).render(on=False, ident_fault="ident", dev="sdb", path=""))' "$tpl")
[ "$rendered" = "/usr/libexec/ceph-nix/device-light off ident 'sdb'" ] || { echo "unexpected rendering: $rendered"; exit 1; }
sudo truncate -s 256M /mnt/blink.img
bdev=$(sudo losetup -f --show /mnt/blink.img)
bname=${bdev#/dev/}
light() { sudo "$work/cephadm" --image "$tool_image" shell --fsid "$fsid" -- /usr/libexec/ceph-nix/device-light "$@" </dev/null; }
# running blinker containers for $bdev (cephadm names them ceph-FSID-container-blink-dev-NAME-HOST)
blinkers() { sudo podman ps -q --filter "name=container-blink-dev-$bname-" | wc -l; }
blinkers_are() { [ "$(blinkers)" = "$1" ]; }
reads() { awk '{print $1}' "/sys/block/$bname/stat"; }
# with nothing to list, ceph prints "No services reported" / "No daemons reported" instead of JSON
count_json() { jq length 2>/dev/null || echo 0; }
services() { tbx ceph orch ls container -f json | count_json; }
blinkers_are 0
light on fault "$bdev" && { echo "fault light must not fall back"; exit 1; }
[ "$(services)" = 0 ]
light on ident "$bdev"
wait_for 180 "blinker running" blinkers_are 1
r1=$(reads); sleep 5; r2=$(reads)
echo "reads of $bdev: $r1 -> $r2"
[ "$r2" -gt "$r1" ]
light on ident "$bdev"
sleep 20
blinkers_are 1
[ "$(services)" = 1 ]
[ "$(tbx ceph orch ps --daemon-type container -f json | count_json)" = 1 ]
light off ident "$bdev"
wait_for 180 "blinker gone" blinkers_are 0
# The listing lags the container: `orch rm` only marks the spec deleted; the serve loop removes the daemon, and purges
# the spec in a later pass, once no daemon is left (serve.py _purge_deleted_services).
services_are() { [ "$(services)" = "$1" ]; }
wait_for 120 "no container service" services_are 0 || { tbx ceph orch ls container; exit 1; }
r1=$(reads); sleep 5; r2=$(reads)
echo "reads of $bdev: $r1 -> $r2"
# blinking reads ~15k/s; stray reads (udev, device scans) are a handful
[ $((r2 - r1)) -lt 1000 ]
light off ident "$bdev"
# the mgr's own dispatch (ssh to the host, rendered template), when a device the mgr knows has a location
devid=$(tbx ceph device ls -f json | jq -r '[.[] | select((.location | length) > 0)][0].devid // empty')
all_blinkers() { sudo podman ps -q --filter name=container-blink-dev- | wc -l; }
some_blinker() { [ "$(all_blinkers)" -ge 1 ]; }
no_blinker() { [ "$(all_blinkers)" = 0 ]; }
dispatch_failed() { # dispatch_failed on|off: the mgr's error, then the same command by hand for device-light's message
	local loc
	echo "::error::the mgr's dispatch of device light $1 failed"
	tbx ceph log last 20 cephadm || true
	loc=$(tbx ceph device ls -f json | jq -c --arg d "$devid" '.[] | select(.devid == $d) | .location[0]')
	echo "location: $loc"
	light "$1" ident "$(jq -r 'if (.path // "") != "" then .path else .dev end' <<<"$loc")" || true
	exit 1
}
if [ -n "$devid" ]; then
	# the orchestrator prints the blink command's result, or None when it raised (the error is only in the mgr log)
	echo "ceph device light on $devid"
	out=$(tbx ceph device light on "$devid")
	echo "$out"
	grep -q 'Set ident light' <<<"$out" || dispatch_failed on
	wait_for 120 "mgr-dispatched blinker" some_blinker || dispatch_failed on
	out=$(tbx ceph device light off "$devid")
	echo "$out"
	grep -q 'Set ident light' <<<"$out" || dispatch_failed off
	wait_for 180 "mgr-dispatched blinker gone" no_blinker || dispatch_failed off
else
	tbx ceph device ls
	echo "no device with a location: the mgr's dispatch cannot be tested"
	exit 1
fi
sudo losetup -d "$bdev"
endstep

step "final health"
allowed=${ALLOWED_WARNINGS-}
wait_for 300 "healthy (allowed: ${allowed:-none})" health_ok_allowed || { tbx ceph health detail; exit 1; }
endstep
echo "RESULT cephadm -> OK"
