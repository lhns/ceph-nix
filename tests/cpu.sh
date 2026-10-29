#!/usr/bin/env bash
# Runs an image's binaries under qemu-user with a restricted CPU model (CPUID and instruction set), ADR 0006.
#   cpu.sh IMAGE CPU pass   every program must run
#   cpu.sh IMAGE CPU fail   every program must be refused by glibc for lacking x86-64-v3, and nothing else
# Needs qemu-x86_64-static. A missing program fails the run; only the smoke binary (ours only) is skipped.
set -uo pipefail
image=$1 cpu=$2 expect=$3
here=$(cd "$(dirname "$0")" && pwd)
qemu=$(command -v qemu-x86_64-static)

# program|args...  (| separates words so a python -c snippet can contain spaces)
cmds=(
	"/usr/bin/ceph|--version"
	"/usr/bin/ceph-mon|--version"
	"/usr/bin/ceph-mgr|--version"
	"/usr/bin/ceph-osd|--version"
	"/usr/bin/ceph-mds|--version"
	"/usr/bin/ceph-exporter|--version"
	"/usr/bin/ceph-immutable-object-cache|--version"
	"/usr/bin/ceph-fuse|--version"
	"/usr/bin/ceph-conf|--version"
	"/usr/bin/ceph-authtool|--version"
	"/usr/bin/ceph-bluestore-tool|--version"
	"/usr/bin/ceph-objectstore-tool|--version"
	"/usr/bin/ceph-kvstore-tool|--version"
	"/usr/bin/crushtool|-h"
	"/usr/bin/monmaptool|--version"
	"/usr/bin/osdmaptool|--version"
	"/usr/bin/radosgw|--version"
	"/usr/bin/radosgw-admin|--version"
	"/usr/bin/rados|--version"
	"/usr/bin/rbd|--version"
	"/usr/bin/rbd-mirror|--version"
	"/usr/bin/rbd-nbd|--version"
	"/usr/bin/cephfs-mirror|--version"
	"/usr/bin/cephfs-top|--help"
	"/usr/bin/cephfs-data-scan|--help"
	"/usr/sbin/ceph-volume|--help"
	"/usr/sbin/cephadm|version"
	"/usr/bin/ganesha.nfsd|-v"
	"/usr/bin/ganesha-rados-grace|--help"
	"/usr/sbin/rpcbind|-h"
	"/usr/bin/dbus-daemon|--version"
	"/usr/bin/lua|-v"
	"/usr/bin/luarocks|--version"
	"/usr/bin/mount|--version"
	"/usr/bin/lsblk|--version"
	"/usr/sbin/blkid|--version"
	"/usr/sbin/lvm|version"
	"/usr/sbin/mkfs.xfs|-V"
	"/usr/sbin/mke2fs|-V"
	"/usr/sbin/sgdisk|--version"
	"/usr/sbin/parted|--version"
	"/usr/sbin/partprobe|--version"
	"/usr/bin/udevadm|--version"
	"/usr/sbin/nvme|version"
	"/usr/sbin/smartctl|--version"
	"/usr/bin/sg_inq|--version"
	"/usr/sbin/cryptsetup|--version"
	"/usr/sbin/modprobe|--version"
	"/usr/bin/ps|--version"
	"/usr/bin/hostname|--version"
	"/usr/bin/ls|--version"
	"/usr/bin/bash|--version"
	"/usr/bin/python3|-c|import rados, rbd, cephfs, numpy, sklearn, cryptography, jinja2"
	"/usr/libexec/ceph-nix/smoke"
)

resolve() { # prints the qemu command line words for a program, empty if the image lacks it
	docker run --rm --entrypoint /bin/sh -v "$here/resolve.sh:/resolve.sh:ro" "$image" /resolve.sh "$1" 2>/dev/null
}

rc=0
for entry in "${cmds[@]}"; do
	IFS='|' read -r -a words <<<"$entry"
	prog=${words[0]}
	args=("${words[@]:1}")
	# shellcheck disable=SC2207
	target=($(resolve "$prog"))
	if [ ${#target[@]} -eq 0 ] || ! docker run --rm --entrypoint /bin/sh "$image" -c "test -e '$prog'" 2>/dev/null; then
		if [ "$prog" = /usr/libexec/ceph-nix/smoke ]; then # only our image carries it
			printf '### %s  [%s] SKIPPED, not in image\n' "$prog" "$cpu"
			continue
		fi
		printf '### %s  [%s] MISSING\n' "$prog" "$cpu"
		rc=1
		continue
	fi
	out=$(docker run --rm --entrypoint /qemu -e QEMU_CPU="$cpu" -v "$qemu:/qemu:ro" "$image" -cpu "$cpu" "${target[@]}" "${args[@]}" 2>&1)
	status=$?
	printf '### %s %s  [%s, exit %s]\n%s\n' "$prog" "${args[*]}" "$cpu" "$status" "$(head -c 1500 <<<"$out")"
	case $expect in
	pass)
		# a usage message and exit 1 still proves the program ran; a signal or a CPU refusal does not
		if [ "$status" -ne 0 ] && { [ "$status" -ge 126 ] || [ -z "$out" ] || grep -qE 'Illegal instruction|uncaught target signal|CPU does not support|error while loading shared|No such file or directory|Traceback|ModuleNotFoundError' <<<"$out"; }; then
			echo "FAILED: $prog"
			rc=1
		fi
		;;
	fail) { [ "$status" -ne 0 ] && grep -q 'CPU does not support x86-64-v3' <<<"$out"; } || { echo "NOT REFUSED: $prog"; rc=1; } ;;
	esac
done
echo "RESULT image=$image cpu=$cpu expect=$expect -> $([ $rc -eq 0 ] && echo OK || echo FAILED)"
exit $rc
