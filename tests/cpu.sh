#!/usr/bin/env bash
# Runs an image's binaries under qemu-user with a restricted CPU model (CPUID and instruction set), ADR 0006.
#   cpu.sh IMAGE CPU pass [SMOKE_BINARY]   every program must run
#   cpu.sh IMAGE CPU fail [SMOKE_BINARY]   every program must be refused by glibc for lacking x86-64-v3, and nothing else
# Needs qemu-x86_64-static. A missing program fails the run. SMOKE_BINARY (tests/smoke.c, nix/pkgs/ceph-smoke.nix) is
# not part of our image: it is bind-mounted read-only and run the same way, and a missing file fails the run. Its
# loader and RUNPATH are store paths of the image's closure. Upstream images get no fourth argument.
set -uo pipefail
image=$1 cpu=$2 expect=$3 smoke=${4:-}
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
	"/usr/bin/tcmu-runner|--help"
	"/usr/bin/lsmcli|--version"
	"/usr/bin/lsmd|--help"
	"/usr/bin/simc_lsmplugin|--help"
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
	"/usr/bin/python3|-c|import rados, rbd, cephfs, numpy, sklearn, cryptography, jinja2, lsm, flask, netifaces, rtslib_fb, configshell_fb, ceph_iscsi_config.settings, gwcli"
)

resolve() { # prints the qemu command line words for a program, empty if the image lacks it
	docker run --rm --entrypoint /bin/sh -v "$here/resolve.sh:/resolve.sh:ro" "$image" /resolve.sh "$1" 2>/dev/null
}

rc=0
mounts=() # extra docker arguments of the next check
strict=0  # 1: the program must exit 0 (a usage message is not enough)

# check PROG ARGS... -- TARGET...   runs TARGET (qemu words) under qemu and applies the expectation to PROG
check() {
	local prog=$1 args=() target out status
	shift
	while [ "$1" != -- ]; do args+=("$1"); shift; done
	shift
	target=("$@")
	out=$(docker run --rm --entrypoint /qemu -e QEMU_CPU="$cpu" -v "$qemu:/qemu:ro" "${mounts[@]}" "$image" -cpu "$cpu" "${target[@]}" "${args[@]}" 2>&1)
	status=$?
	printf '### %s %s  [%s, exit %s]\n%s\n' "$prog" "${args[*]}" "$cpu" "$status" "$(head -c 1500 <<<"$out")"
	case $expect in
	pass)
		# a usage message and exit 1 still proves the program ran; a signal or a CPU refusal does not
		if [ "$status" -ne 0 ] && { [ "$strict" = 1 ] || [ "$status" -ge 126 ] || [ -z "$out" ] || grep -qE 'Illegal instruction|uncaught target signal|CPU does not support|error while loading shared|No such file or directory|Traceback|ModuleNotFoundError' <<<"$out"; }; then
			echo "FAILED: $prog"
			rc=1
		fi
		;;
	fail) { [ "$status" -ne 0 ] && grep -q 'CPU does not support x86-64-v3' <<<"$out"; } || { echo "NOT REFUSED: $prog"; rc=1; } ;;
	esac
}

for entry in "${cmds[@]}"; do
	IFS='|' read -r -a words <<<"$entry"
	prog=${words[0]}
	# shellcheck disable=SC2207
	target=($(resolve "$prog"))
	if [ ${#target[@]} -eq 0 ] || ! docker run --rm --entrypoint /bin/sh "$image" -c "test -e '$prog'" 2>/dev/null; then
		printf '### %s  [%s] MISSING\n' "$prog" "$cpu"
		rc=1
		continue
	fi
	check "$prog" "${words[@]:1}" -- "${target[@]}"
done

if [ -n "$smoke" ]; then
	if [ ! -f "$smoke" ]; then
		printf '### %s  [%s] MISSING\n' "$smoke" "$cpu"
		rc=1
	else
		# it must load the three client libraries and exit 0; unlike the --version runs, exit 1 is its own failure
		mounts=(-v "$(realpath "$smoke"):/ceph-nix-smoke:ro")
		strict=1
		check ceph-nix-smoke -- /ceph-nix-smoke
	fi
fi
echo "RESULT image=$image cpu=$cpu expect=$expect -> $([ $rc -eq 0 ] && echo OK || echo FAILED)"
exit $rc
