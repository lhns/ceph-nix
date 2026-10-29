#!/usr/bin/env bash
# Decision logic of /usr/libexec/ceph-nix/device-light with a fake lsmcli and a fake ceph, inside the image.
#   device-light.sh IMAGE          (docker or podman as $ENGINE, default podman; add sudo yourself)
# supported -> no fallback; not supported -> the blinker service; any other lsmcli error -> failure, no fallback.
set -Eeuo pipefail
image=$1
engine=${ENGINE:-podman}
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"

# lsmcli: behaviour from $FAKE_LSM: ok | nosupport | denied | missing-plugin | badpath
cat >"$tmp/bin/lsmcli" <<'SH'
#!/usr/bin/env bash
echo "lsmcli $*" >>"$CALLS"
case $FAKE_LSM in
ok) exit 0 ;;
nosupport) echo "NO_SUPPORT: Disk LED control is not supported on this disk " >&2; exit 4 ;;
missing-plugin) echo "PLUGIN_NOT_EXIST: no LED plugin " >&2; exit 4 ;;
denied) echo "PERMISSION_DENIED: root needed " >&2; exit 13 ;;
badpath) echo "INVALID_ARGUMENT: disk path is not a block device " >&2; exit 4 ;;
esac
SH
# ceph: records the calls; the blinker service exists once applied and until removed
cat >"$tmp/bin/ceph" <<'SH'
#!/usr/bin/env bash
echo "ceph $*" >>"$CALLS"
case "$*" in
"orch host ls -f json") echo '[{"hostname":"node1"}]' ;;
"orch ls container -f json") [ -e "$STATE" ] && echo '[{"service_name":"container.blink-dev-sdz"}]' || echo '[]' ;;
"orch apply -i "*) cp "${@: -1}" "$SPEC"; chmod a+r "$SPEC"; touch "$STATE" ;;
"orch rm "*) rm -f "$STATE" ;;
esac
SH
chmod +x "$tmp/bin/"*

fails=0
# run NAME FAKE_LSM EXPECT_RC ARGS... ; leaves the calls in $tmp/calls
run() {
	local name=$1 lsm=$2 want=$3 rc=0
	shift 3
	: >"$tmp/calls"
	$engine run --rm -v "$tmp:/t" -e CALLS=/t/calls -e STATE=/t/state -e SPEC=/t/spec -e FAKE_LSM="$lsm" \
		-e CONTAINER_IMAGE=img:1 -e NODE_NAME=node1 -e PATH=/t/bin:/usr/bin \
		--entrypoint /usr/libexec/ceph-nix/device-light "$image" "$@" >"$tmp/out" 2>&1 || rc=$?
	if [ "$rc" != "$want" ]; then
		echo "FAIL $name: exit $rc, want $want"; cat "$tmp/out"; fails=$((fails + 1)); return
	fi
	echo "ok   $name (exit $rc)"
}
has() { grep -q -- "$1" "$tmp/calls"; }
check() { # check DESCRIPTION CONDITION...
	local d=$1
	shift
	"$@" || { echo "FAIL $d"; cat "$tmp/calls" "$tmp/out"; fails=$((fails + 1)); }
}
no_fallback() { ! has '^ceph '; }

rm -f "$tmp/state"
run "supported: on is native" ok 0 on ident /dev/sdz
check "supported: lsmcli on called" has 'lsmcli local-disk-ident-led-on --path /dev/sdz'
check "supported: no ceph calls" no_fallback
run "supported: off is native" ok 0 off ident /dev/sdz
check "supported: no ceph calls on off" no_fallback

run "not supported: on starts the blinker" nosupport 0 on ident /dev/sdz
check "apply called" has 'ceph orch apply -i'
check "spec: service id" grep -q 'service_id: blink-dev-sdz' "$tmp/spec"
check "spec: privileged, this image, the device" bash -c "grep -q 'privileged: true' $tmp/spec && grep -q 'image: img:1' $tmp/spec && grep -q 'BLINK_DEV=/dev/sdz' $tmp/spec && grep -q 'hosts: \[node1\]' $tmp/spec"
check "spec: entrypoint" grep -q 'entrypoint: /usr/libexec/ceph-nix/blink-disk' "$tmp/spec"
run "not supported: on again is one blinker" nosupport 0 on ident /dev/sdz
check "no second apply" bash -c "! grep -q 'orch apply' $tmp/calls"
run "not supported: off removes it" nosupport 0 off ident /dev/sdz
check "rm called" has 'ceph orch rm container.blink-dev-sdz'
run "not supported: off without a blinker" nosupport 0 off ident /dev/sdz
check "no rm" bash -c "! grep -q 'orch rm' $tmp/calls"
run "no LED plugin falls back" missing-plugin 0 on ident /dev/sdz
run "cleanup" missing-plugin 0 off ident /dev/sdz

run "fault: not supported has no fallback" nosupport 1 on fault /dev/sdz
check "fault: no ceph calls" no_fallback

run "other error: on fails" denied 13 on ident /dev/sdz
check "other error: no fallback" no_fallback
run "other error (bad path): on fails" badpath 4 on ident /dev/sdz
check "bad path: no fallback" no_fallback
run "other error: off fails" denied 13 off ident /dev/sdz
check "other error off: no fallback" no_fallback
run "usage error" ok 2 on bogus /dev/sdz

[ "$fails" = 0 ] || { echo "$fails failures"; exit 1; }
echo "device-light decision logic OK"
