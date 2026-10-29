#!/usr/bin/env bash
# Functional test of the image through cephadm, on a throwaway Ubuntu runner (ADR 0006).
#   cephadm.sh IMAGE_TARBALL        docker-archive tarball, optionally zstd-compressed
# Env: PENDING_FEATURES=skip   skip what only the Umbrella build provides: dashboard UI, iSCSI
#      ARTIFACT_DIR            where logs go on failure (default ./cephadm-logs)
# Allowed health warnings: none. HEALTH_OK is required after the OSDs are up and again at the end.
set -Eeuo pipefail
tarball=$(realpath "$1")
here=$(cd "$(dirname "$0")" && pwd)
art=${ARTIFACT_DIR:-$PWD/cephadm-logs}
pending=${PENDING_FEATURES:-}
work=$(sudo mktemp -d /mnt/cephadm-test.XXXX)
sudo chown "$USER" "$work"
mkdir -p "$art"
local_image=localhost:5000/ceph:test
step() { echo "::group::$*"; echo ">>> $*"; }
endstep() { echo "::endgroup::"; }

# Commands in a long-lived container from the image under test (host network, admin keyring).
tbx() { sudo podman exec toolbox "$@"; }
# krbd needs the host's /dev and /sys and udev's events; our rbd from a privileged container does that.
rbdh() {
	sudo podman run --rm --privileged --net=host --pid=host -v /dev:/dev -v /sys:/sys -v /run/udev:/run/udev:ro 		-v /etc/ceph:/etc/ceph --entrypoint rbd "$local_image" "$@"
}

collect() {
	set +e
	echo "::group::collecting logs into $art"
	sudo podman ps -a >"$art/podman-ps.txt" 2>&1
	if [ -x "$work/cephadm" ]; then
		for n in $(sudo "$work/cephadm" ls 2>/dev/null | jq -r '.[].name' 2>/dev/null); do
			sudo "$work/cephadm" logs --name "$n" >"$art/daemon-$n.log" 2>&1
		done
	fi
	for c in "ceph -s" "ceph health detail" "ceph orch ps" "ceph orch ls" "ceph mgr module ls" "ceph osd tree" "ceph crash ls" \
		"ceph fs status" "ceph osd pool ls detail"; do
		# shellcheck disable=SC2086
		tbx $c >"$art/$(tr ' ' _ <<<"$c").txt" 2>&1
	done
	sudo journalctl --no-pager -u 'ceph*' >"$art/journal-ceph.txt" 2>&1
	sudo journalctl --no-pager -k | grep -iE 'rbd|ceph|libceph|nfs' >"$art/dmesg.txt" 2>&1
	sudo cp /var/log/ceph/cephadm.log "$art/" 2>/dev/null
	sudo chmod -R a+r "$art"
	echo "::endgroup::"
}
trap 'rc=$?; [ $rc -eq 0 ] || collect; exit $rc' EXIT

wait_for() { # wait_for SECONDS DESCRIPTION CMD...
	local t=$1 d=$2 i
	shift 2
	for ((i = 0; i < t; i += 5)); do
		if "$@" >/dev/null 2>&1; then return 0; fi
		sleep 5
	done
	echo "timeout waiting for: $d"
	return 1
}
osds_up() { [ "$(sudo podman exec toolbox ceph osd stat -f json | jq .num_up_osds)" = 3 ]; }
health_ok() { [ "$(sudo podman exec toolbox ceph health)" = HEALTH_OK ]; }
mds_active() { sudo podman exec toolbox ceph fs status cephfs -f json | jq -e '[.mdsmap[] | select(.state == "active")] | length >= 1'; }
daemon_running() { # daemon_running TYPE
	[ "$(sudo podman exec toolbox ceph orch ps --daemon-type "$1" -f json | jq '[.[] | select(.status_desc == "running")] | length')" -ge 1 ]
}
# grep -q on a pipe can SIGPIPE the producer, which pipefail turns into a failure: capture first
exporter_up() { local m; m=$(curl -sf http://127.0.0.1:9926/metrics) && grep -q '^ceph_' <<<"$m"; }

step "host packages"
export DEBIAN_FRONTEND=noninteractive
sudo apt-get update -qq
sudo rm -rf /usr/share/dotnet /opt/ghc /usr/local/lib/android /opt/hostedtoolcache
sudo apt-get install -y -qq podman lvm2 chrony openssh-server ceph-common nfs-common python3-boto3 zstd jq xfsprogs e2fsprogs curl >/dev/null
sudo systemctl enable --now chrony ssh
for m in rbd ceph nfs; do
	sudo modprobe "$m" 2>/dev/null || { sudo apt-get install -y -qq "linux-modules-extra-$(uname -r)" >/dev/null && sudo modprobe "$m"; }
done
endstep

step "registry and image"
# the runner's / is small; put the container storage on the big temporary disk
sudo mkdir -p /mnt/containers
printf '[storage]\ndriver = "overlay"\nrunroot = "/run/containers/storage"\ngraphroot = "/mnt/containers"\n' | sudo tee /etc/containers/storage.conf >/dev/null
grep graphroot /etc/containers/storage.conf
printf '[[registry]]\nlocation = "localhost:5000"\ninsecure = true\n' | sudo tee /etc/containers/registries.conf.d/99-local.conf >/dev/null
sudo podman run -d --name registry -p 5000:5000 docker.io/library/registry:2 >/dev/null
loaded=$(zstd -dcf "$tarball" | sudo podman load | sed -n 's/^Loaded image: //p' | head -n1)
echo "loaded $loaded"
sudo podman tag "$loaded" "$local_image"
sudo podman push --tls-verify=false "$local_image"
# the cephadm shipped in the image, as the orchestrator would use it
sudo podman run --rm --entrypoint cat "$local_image" /usr/sbin/cephadm >"$work/cephadm"
chmod +x "$work/cephadm"
sudo "$work/cephadm" version
endstep

step "bootstrap"
ip=$(hostname -I | awk '{print $1}')
sudo "$work/cephadm" --image "$local_image" bootstrap --mon-ip "$ip" --single-host-defaults --skip-monitoring-stack \
	--initial-dashboard-user admin --initial-dashboard-password 'Admin-pass-1' --dashboard-password-noupdate \
	--skip-pull --allow-fqdn-hostname --no-cleanup-on-failure
sudo podman run -d --name toolbox --net=host --privileged -v /etc/ceph:/etc/ceph --entrypoint sleep "$local_image" infinity >/dev/null
tbx ceph -s
tbx ceph versions
endstep

step "OSDs on three loop-backed LVs"
for i in 1 2 3; do
	sudo truncate -s 12G "/mnt/osd$i.img"
	dev=$(sudo losetup -f --show "/mnt/osd$i.img")
	sudo pvcreate "$dev" >/dev/null
	sudo vgcreate "vg$i" "$dev" >/dev/null
	sudo lvcreate -l 100%FREE -n lv "vg$i" >/dev/null
	tbx ceph orch daemon add osd "$(hostname):/dev/vg$i/lv"
done
wait_for 300 "3 OSDs up" osds_up
wait_for 600 "HEALTH_OK" health_ok || { tbx ceph health detail; exit 1; }
tbx ceph -s
endstep

step "mgr modules: none that cannot run, no MGR_MODULE_ERROR"
tbx ceph mgr module ls -f json >"$work/modules.json"
jq -r '.disabled_modules[] | select(.can_run == false) | "\(.name): \(.error_string)"' "$work/modules.json" | tee "$work/cannot-run.txt"
# modules that cannot run in the upstream image either, each with a reason
unexpected=$(cut -d: -f1 "$work/cannot-run.txt" | grep -vxFf <(sed 's/[[:space:]]*#.*//; /^$/d' "$here/cephadm-cannot-run.txt") || true)
[ -z "$unexpected" ] || { echo "mgr modules that cannot run: $unexpected"; exit 1; }
! tbx ceph health detail | grep -E 'MGR_MODULE_(ERROR|DEPENDENCY)'
endstep

step "rados bench"
tbx ceph osd pool create bench 32 >/dev/null
tbx ceph osd pool application enable bench rados
tbx rados bench -p bench 10 write --no-cleanup
tbx rados bench -p bench 5 seq
tbx rados -p bench cleanup
endstep

step "erasure-coded pool k=2 m=1"
tbx ceph osd erasure-code-profile set ec21 k=2 m=1 crush-failure-domain=osd
tbx ceph osd pool create ecpool 16 16 erasure ec21 >/dev/null
tbx ceph osd pool application enable ecpool rados
tbx ceph osd pool set ecpool allow_ec_overwrites true
head -c 8M /dev/urandom >"$work/ec.in"
sudo podman cp "$work/ec.in" toolbox:/tmp/ec.in
tbx rados -p ecpool put obj /tmp/ec.in
tbx rados -p ecpool get obj /tmp/ec.out
sudo podman cp toolbox:/tmp/ec.out "$work/ec.out"
cmp "$work/ec.in" "$work/ec.out"
endstep

step "rbd: krbd map, mkfs.ext4, I/O"
tbx ceph osd pool create rbd 32 >/dev/null
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
mount_cephfs() {
	sudo podman run --rm --privileged --net=host -v /etc/ceph:/etc/ceph -v /mnt/cephfs:/mnt/cephfs:rshared --entrypoint mount 		"$local_image" -t ceph "$ip:6789:/" /mnt/cephfs -o "name=admin,secret=$key,mds_namespace=cephfs"
}
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
wait_for 120 "nfs mount" mount_nfs || { cat "$art/nfs-mount.log"; tbx ceph nfs export ls nfs1 --detailed; tbx ceph nfs cluster info nfs1; false; }
sudo dd if=/dev/urandom of=/mnt/nfs/nfsfile bs=1M count=32 conv=fsync status=none
sudo sha256sum /mnt/nfs/nfsfile >"$work/nfs.sum"
sudo umount /mnt/nfs
mount_nfs
sudo sha256sum -c "$work/nfs.sum"
sudo umount /mnt/nfs
endstep

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

if [ "$pending" != skip ]; then
	step "dashboard serves the Angular UI on 8443"
	ui=$(curl -sk https://127.0.0.1:8443/)
	grep -qi '<app-root' <<<"$ui"
	endstep

	step "iscsi: gateway, target, iscsiadm login, I/O"
	sudo apt-get install -y -qq open-iscsi >/dev/null
	"$here/cephadm-iscsi.sh" "$ip" "$work"
	endstep
else
	echo "PENDING_FEATURES=skip: dashboard UI and iSCSI not exercised"
fi

step "final health"
wait_for 300 "HEALTH_OK" health_ok || { tbx ceph health detail; exit 1; }
endstep
echo "RESULT cephadm -> OK"
