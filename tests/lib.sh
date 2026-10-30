# shellcheck shell=bash
# Helpers shared by cephadm.sh and upgrade.sh. Callers set: tool_image (image the toolbox/krbd helpers run from), art, work.

step() { echo "::group::$*"; echo ">>> $*"; }
endstep() { echo "::endgroup::"; }

# Commands in a long-lived container from the image under test (host network, admin keyring).
tbx() { sudo podman exec toolbox "$@"; }
# krbd needs the host's /dev and /sys and udev's events; our rbd from a privileged container does that.
rbdh() {
	sudo podman run --rm --privileged --net=host --pid=host -v /dev:/dev -v /sys:/sys -v /run/udev:/run/udev:ro \n		-v /etc/ceph:/etc/ceph --entrypoint rbd "$tool_image" "$@"
}

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

host_setup() { # host_setup [EXTRA_PACKAGES [EXTRA_MODULES]]
	local m
	export DEBIAN_FRONTEND=noninteractive
	sudo apt-get update -qq
	sudo rm -rf /usr/share/dotnet /opt/ghc /usr/local/lib/android /opt/hostedtoolcache
	sudo apt-get install -y -qq podman lvm2 chrony openssh-server ceph-common nfs-common python3-boto3 zstd jq xfsprogs e2fsprogs curl ${1:-} >/dev/null
	sudo systemctl enable --now chrony ssh
	for m in rbd ceph nfs ${2:-}; do
		sudo modprobe "$m" 2>/dev/null || { sudo apt-get install -y -qq "linux-modules-extra-$(uname -r)" >/dev/null && sudo modprobe "$m"; }
	done
}

registry_setup() {
	# the runner's / is small; put the container storage on the big temporary disk
	sudo mkdir -p /mnt/containers
	printf '[storage]\ndriver = "overlay"\nrunroot = "/run/containers/storage"\ngraphroot = "/mnt/containers"\n' | sudo tee /etc/containers/storage.conf >/dev/null
	grep graphroot /etc/containers/storage.conf
	printf '[[registry]]\nlocation = "localhost:5000"\ninsecure = true\n' | sudo tee /etc/containers/registries.conf.d/99-local.conf >/dev/null
	sudo podman run -d --name registry -p 5000:5000 docker.io/library/registry:2 >/dev/null
}

loop_osds() {
	local i dev
	for i in 1 2 3; do
		sudo truncate -s 12G "/mnt/osd$i.img"
		dev=$(sudo losetup -f --show "/mnt/osd$i.img")
		sudo pvcreate "$dev" >/dev/null
		sudo vgcreate "vg$i" "$dev" >/dev/null
		sudo lvcreate -l 100%FREE -n lv "vg$i" >/dev/null
		tbx ceph orch daemon add osd "$(hostname):/dev/vg$i/lv"
	done
}

# Needs ip, key (client.admin) and /mnt/cephfs made rshared by the caller.
mount_cephfs() {
	sudo podman run --rm --privileged --net=host -v /etc/ceph:/etc/ceph -v /mnt/cephfs:/mnt/cephfs:rshared --entrypoint mount \n		"$tool_image" -t ceph "$ip:6789:/" /mnt/cephfs -o "name=admin,secret=$key,mds_namespace=cephfs"
}

# Needs art and work.
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
		"ceph fs status" "ceph osd pool ls detail" "ceph orch ls container"; do
		# shellcheck disable=SC2086
		tbx $c >"$art/$(tr ' ' _ <<<"$c").txt" 2>&1
	done
	sudo journalctl --no-pager -u 'ceph*' >"$art/journal-ceph.txt" 2>&1
	sudo journalctl --no-pager -k | grep -iE 'rbd|ceph|libceph|nfs' >"$art/dmesg.txt" 2>&1
	sudo cp /var/log/ceph/cephadm.log "$art/" 2>/dev/null
	sudo chmod -R a+r "$art"
	echo "::endgroup::"
}
