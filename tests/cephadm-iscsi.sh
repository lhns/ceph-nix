#!/usr/bin/env bash
# iSCSI leg of cephadm.sh (only for images that ship ceph-iscsi and tcmu-runner): deploy the gateway through the
# orchestrator, create a target over the rbd-target-api REST API, log in with iscsiadm, do I/O.
#   cephadm-iscsi.sh MON_IP WORKDIR
# Not exercised on the Tentacle dev image (PENDING_FEATURES=skip).
set -Eeuo pipefail
ip=$1 work=$2
tbx() { sudo podman exec toolbox "$@"; }
wait_for() { # wait_for SECONDS CMD...
	local t=$1 i
	shift
	for ((i = 0; i < t; i += 5)); do
		"$@" >/dev/null 2>&1 && return 0
		sleep 5
	done
	return 1
}
iscsi_running() { [ "$(sudo podman exec toolbox ceph orch ps --daemon-type iscsi -f json | jq '[.[] | select(.status_desc == "running")] | length')" -ge 1 ]; }

tbx ceph osd pool create iscsi 8 >/dev/null
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
  trusted_ip_list: "127.0.0.1,$ip"
YAML
sudo podman cp "$work/iscsi.yaml" toolbox:/tmp/iscsi.yaml
tbx ceph orch apply -i /tmp/iscsi.yaml
wait_for 300 iscsi_running
api="http://admin:admin@127.0.0.1:5000/api"
iqn=iqn.2001-07.com.ceph:test
wait_for 120 curl -sf "$api/sysinfo/ip_addresses"
curl -sf -X PUT "$api/target/$iqn"
curl -sf -X POST "$api/gateway/$iqn/$(hostname)" -d "ip_address=$ip"
curl -sf -X PUT "$api/disk/iscsi/img" -d mode=create -d size=1G
curl -sf -X PUT "$api/targetlun/$iqn" -d disk=iscsi/img
initiator=$(sudo sed -n 's/^InitiatorName=//p' /etc/iscsi/initiatorname.iscsi)
curl -sf -X PUT "$api/client/$iqn/$initiator"
curl -sf -X PUT "$api/clientlun/$iqn/$initiator" -d disk=iscsi/img
sudo iscsiadm -m discovery -t sendtargets -p "$ip:3260"
sudo iscsiadm -m node -T "$iqn" -p "$ip:3260" --login
sleep 5
dev=$(lsblk -dn -o NAME,TRAN | awk '$2 == "iscsi" {print "/dev/" $1}' | head -n1)
sudo mkfs.ext4 -q "$dev"
sudo mkdir -p /mnt/iscsi
sudo mount "$dev" /mnt/iscsi
sudo dd if=/dev/urandom of=/mnt/iscsi/file bs=1M count=16 conv=fsync status=none
sudo umount /mnt/iscsi
sudo iscsiadm -m node -T "$iqn" -p "$ip:3260" --logout
