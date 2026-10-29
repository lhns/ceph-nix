#!/usr/bin/env bash
# ceph-csi's acceptance e2e (the specs labelled "acceptance" in upstream's .github/workflows/e2e-minikube-acceptance.yaml)
# against a Rook cluster running our Ceph image. Adapted from lhns/ceph-csi-x86-64-v2's test/e2e.sh.
#   e2e.sh CEPH_IMAGE [K8S_MINOR]
# CEPH_IMAGE is a docker image on this machine (the loaded image). ceph-csi is upstream at the newest tag that
# lhns/ceph-csi-x86-64-v2 released, with that repo's image deployed under the name upstream's scripts use.
# Needs: docker, go, gh (GH_TOKEN) and sudo; runs minikube.
set -xeEuo pipefail
ceph_image=$1 minor=${2:-1.35}
work=${E2E_DIR:-$PWD/e2e-work}
logdir=/tmp/acceptance-e2e-logs

tag=${CEPH_CSI_TAG:-$(gh release list -R lhns/ceph-csi-x86-64-v2 --limit 1 --json tagName -q '.[0].tagName')}
echo "ceph-csi $tag"
mkdir -p "$work"
[ -d "$work/ceph-csi" ] || git clone --depth 1 --branch "$tag" https://github.com/ceph/ceph-csi "$work/ceph-csi"
cd "$work/ceph-csi"

set -a
# shellcheck disable=SC1091
source build.env
set +a
KUBE_VERSION=$(curl -sfL "https://dl.k8s.io/release/stable-$minor.txt")
export KUBE_VERSION CONTAINER_CMD=docker

# What upstream's scripts deploy is quay.io/cephcsi/cephcsi:<CSI_IMAGE_VERSION>; use the rebuilt image under that name.
ours=ghcr.io/lhns/ceph-csi-x86-64-v2:$tag
docker pull "$ours"
docker tag "$ours" "quay.io/cephcsi/cephcsi:$CSI_IMAGE_VERSION"
# Rook runs this one; minikube gets it with `minikube image load` below. Not a registry name, so nothing pulls it.
export ROOK_CEPH_CLUSTER_IMAGE=localhost/ceph-nix:e2e
docker tag "$ceph_image" "$ROOK_CEPH_CLUSTER_IMAGE"

collect() { # upstream's collect_logs, plus the namespaces it doesn't cover
	local n p
	cd "$work/ceph-csi"
	scripts/github-action-helper.sh collect_logs || true
	mkdir -p "$logdir"
	kubectl describe pvc -A >"$logdir/pvc-describe.txt" 2>&1 || true
	for n in $(kubectl get ns -o name | grep -E 'cephcsi|ceph-csi|rook|k8s-storage' | cut -d/ -f2); do
		kubectl -n "$n" get all,events -o wide >"$logdir/$n-all.txt" 2>&1 || true
		for p in $(kubectl -n "$n" get pods -o name); do
			kubectl -n "$n" logs "$p" --all-containers --prefix >"$logdir/$n-${p#pod/}.log" 2>&1 || true
			kubectl -n "$n" logs "$p" --all-containers --prefix --previous >"$logdir/$n-${p#pod/}.previous.log" 2>&1 || true
		done
	done
}
trap collect ERR

make e2e.test
for i in 1 2 3; do
	scripts/github-action-helper.sh install_minikube_prereqs
	! ls /usr/local/bin/cri-dockerd /usr/local/bin/crictl /opt/cni/bin/bridge /etc/systemd/system/cri-docker.service \
		/etc/systemd/system/cri-docker.socket >/dev/null || break
	sleep 30
done
sudo sysctl fs.protected_regular=0
MEMORY=6144 scripts/minikube.sh up
scripts/github-action-helper.sh prepare_disk
minikube image load "$ROOK_CEPH_CLUSTER_IMAGE"
scripts/minikube.sh cephcsi
scripts/minikube.sh k8s-sidecar

scripts/deploy-ceph-csi-operator.sh deploy
scripts/minikube.sh install-snapshotter
ROOK_DEPLOY_TIMEOUT=600 KUBECTL_RETRY_DELAY=5 scripts/minikube.sh deploy-rook
kubectl -n rook-ceph get cephcluster -o wide
# the cluster must really run our image
kubectl -n rook-ceph get pods -l app=rook-ceph-mon -o jsonpath='{.items[*].spec.containers[*].image}' | grep -q ceph-nix

cd e2e
log=$work/e2e-output.log
../e2e.test -test.v -ginkgo.v --ginkgo.label-filter=acceptance --ginkgo.timeout=40m --deploy-timeout=10 \
	--test-rbd=true --test-cephfs=true --test-nfs=true --test-nvmeof=false \
	--deploy-rbd=false --deploy-cephfs=false --operator-deployment --skip-vault=true 2>&1 | tee "$log"
# a suite that skips every spec passes; fail it instead
grep -o 'Ran [0-9]* of [0-9]* Specs' "$log" | tee -a "${GITHUB_STEP_SUMMARY:-/dev/null}"
! grep -q 'Ran 0 of' "$log"
