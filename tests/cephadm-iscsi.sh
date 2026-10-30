#!/usr/bin/env bash
# iSCSI leg of cephadm.sh: deploy the gateway through the orchestrator, create a target, a disk and a CHAP-protected
# initiator over the rbd-target-api REST API, log in with iscsiadm from the host, do I/O, and read it back after a
# fresh login.
#   cephadm-iscsi.sh MON_IP WORKDIR
# Needs the host kernel's target_core_user, iscsi_target_mod and iscsi_tcp modules and open-iscsi (cephadm.sh does both).
set -Eeuo pipefail
ip=$1 work=$2
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib.sh
. "$here/lib.sh"
# the REST API answers a PUT with a JSON message and an HTTP status; show both, fail on 4xx/5xx
api() { # api METHOD PATH [curl args]
	local m=$1 p=$2 code
	shift 2
	code=$(curl -s -o /dev/stderr -w '%{http_code}' -X "$m" "$@" "$api/$p" 2>"$work/api.body") || true
	echo "$m /api/$p -> $code $(cat "$work/api.body")"
	[ "$code" -lt 400 ]
}

tbx ceph osd pool create iscsi 1 >/dev/null
tbx rbd pool init iscsi
cat >"$work/iscsi.yaml" <<YAML
service_type: iscsi
service_id: gw
placement:
  count: 1
spec:
  pool: iscsi
  api_user: admin
  api_password: admin
  api_secure: false
  api_port: 5001 # 5000 is the test registry
  trusted_ip_list: "127.0.0.1,$ip"
YAML
sudo podman cp "$work/iscsi.yaml" toolbox:/tmp/iscsi.yaml
tbx ceph orch apply -i /tmp/iscsi.yaml
wait_for 300 "iscsi running" daemon_running iscsi || { tbx ceph orch ps --daemon-type iscsi; false; }
api="http://admin:admin@127.0.0.1:5001/api"
iqn=iqn.2001-07.com.ceph:test
wait_for 120 "gateway API" curl -sf "$api/sysinfo/ip_addresses" || { sudo podman ps -a; false; }
# the gateway is named by the API process's own FQDN
gw=$(curl -sf "$api/sysinfo/hostname" | jq -r .data)
echo "gateway name: $gw"
api PUT "target/$iqn"
api PUT "gateway/$iqn/$gw" -d "ip_address=$ip" -d skipchecks=true
api PUT "disk/iscsi/img" -d mode=create -d size=1G
api PUT "targetlun/$iqn" -d disk=iscsi/img
initiator=iqn.1993-08.org.debian:01:cephnixci
echo "InitiatorName=$initiator" | sudo tee /etc/iscsi/initiatorname.iscsi >/dev/null
sudo systemctl restart iscsid
api PUT "client/$iqn/$initiator"
api PUT "clientlun/$iqn/$initiator" -d disk=iscsi/img
api PUT "clientauth/$iqn/$initiator" -d username=testuser12 -d password=testpass1234
sudo iscsiadm -m discovery -t sendtargets -p "$ip:3260"
sudo iscsiadm -m node
for kv in authmethod=CHAP username=testuser12 password=testpass1234; do
	sudo iscsiadm -m node -T "$iqn" -p "$ip:3260" -o update -n "node.session.auth.${kv%%=*}" -v "${kv#*=}"
done
login() {
	sudo iscsiadm -m node -T "$iqn" -p "$ip:3260" --login >&2
	local i dev
	for i in $(seq 30); do
		dev=$(lsblk -dn -o NAME,TRAN | awk '$2 == "iscsi" {print "/dev/" $1}' | head -n1)
		[ -n "$dev" ] && { echo "$dev"; return; }
		sleep 2
	done
	echo "no iscsi disk appeared" >&2
	lsblk -o NAME,TRAN,SIZE,TYPE >&2
	sudo iscsiadm -m session -P3 >&2 || true
	sudo dmesg | tail -n 40 >&2
	return 1
}
dev=$(login | tail -n1)
sudo mkfs.ext4 -q "$dev"
sudo mkdir -p /mnt/iscsi
sudo mount "$dev" /mnt/iscsi
sudo dd if=/dev/urandom of=/mnt/iscsi/file bs=1M count=16 conv=fsync status=none
sudo sha256sum /mnt/iscsi/file >"$work/iscsi.sum"
sudo umount /mnt/iscsi
sudo iscsiadm -m node -T "$iqn" -p "$ip:3260" --logout
dev=$(login | tail -n1)
sudo mount "$dev" /mnt/iscsi
sudo sha256sum -c "$work/iscsi.sum"
sudo umount /mnt/iscsi
sudo iscsiadm -m node -T "$iqn" -p "$ip:3260" --logout
# the data went through tcmu-runner's rbd handler into the pool
[ "$(tbx rbd du iscsi/img --format json | jq '.images[0].used_size')" -gt 0 ]
