#!/usr/bin/env bash
# File-tree parity with the upstream image, ADR 0002 dimension (a).
#   parity.sh UPSTREAM_IMAGE OUR_IMAGE EXPECTED_MAJOR_MINOR      e.g. quay.io/ceph/ceph:v20.2.4 ceph-nix:... 20.2
# Every entry of upstream's /usr/bin, /usr/sbin, /usr/libexec/ceph, /usr/lib64/{ceph,rados-classes,ganesha,tcmu-runner},
# the Ceph libraries /usr/lib64/lib{rados,rbd,cephfs,rgw,radosstriper,cephsqlite}.so* and /usr/share/ceph/mgr must exist
# (resolve) in ours, unless tests/parity-allow.txt allows it. Gaps the Umbrella build closes are in
# tests/parity-pending.txt and only tolerated with PARITY_PENDING_OK=1. Both files: one shell glob per line, then
# "# reason, ADR 0002".
# PARITY_USERLAND=el10 for the Umbrella image (Rocky 10; default el9, CentOS Stream 9), see tests/parity-allow.txt.
# Also the Python the mgr runs on (tests/pydists.py): every distribution installed in upstream's python3, and every
# top-level module no distribution owns, is present in ours ("pydist:<name>" / "pymod:<name>" entries, normalized
# names), same allowlist. And the dashboard's optional gRPC/NVMe-oF client imports, which fails silently otherwise.
# Also the linkage: the DT_NEEDED sonames (versions dropped) of the daemons, ceph-fuse, rbd-nbd and the Ceph libraries
# (tests/elfneeded.py). Sonames upstream links directly and ours does not reach at all are "so:<binary>:<soname>"
# entries, same allowlist; the rest is printed as info.
# Also: `ceph -v` is EXPECTED_MAJOR_MINOR, and every mgr module that imports in upstream's image imports in ours.
set -uo pipefail
export LC_ALL=C # sort and comm must agree
up=$1 ours=$2 expected=$3
here=$(cd "$(dirname "$0")" && pwd)
work=$(mktemp -d)
rc=0
fail() { echo "FAIL: $*"; rc=1; }

run() { local img=$1; shift; docker run --rm --entrypoint /bin/sh -e PYTHONDONTWRITEBYTECODE=1 -i "$img" -c "$@"; }

# --- ceph -v
for img in "$up" "$ours"; do
	v=$(run "$img" 'ceph -v' </dev/null | head -n1)
	echo "$img: $v"
	mm=$(sed -n 's/^ceph version \([0-9]*\.[0-9]*\)\..*/\1/p' <<<"$v")
	[ "$mm" = "$expected" ] || fail "$img: ceph -v is '$mm', expected $expected"
done

# --- file tree
# the mgr tree is compared file by file (module code, dashboard frontend), the rest by directory entry
run "$up" 'for d in /usr/bin /usr/sbin /usr/libexec/ceph /usr/lib64/ceph /usr/lib64/rados-classes /usr/lib64/ganesha /usr/lib64/tcmu-runner; do
	ls -A "$d" 2>/dev/null | sed "s|^|$d/|"; done
	ls -d /usr/lib64/lib{rados,rbd,cephfs,rgw,radosstriper,cephsqlite}.so* 2>/dev/null
	find /usr/share/ceph/mgr \( -type f -o -type l \) ! -path "*/__pycache__/*" ! -name "*.pyc" 2>/dev/null; true' </dev/null | sort -u >"$work/upstream.txt"
echo "upstream entries: $(wc -l <"$work/upstream.txt")"
for d in /usr/lib64/ceph/ /usr/lib64/rados-classes/ /usr/lib64/ganesha/ /usr/lib64/tcmu-runner/ /usr/lib64/lib; do
	echo "  $d*: $(grep -c "^$d" "$work/upstream.txt")"; done
echo "upstream mgr files: $(grep -c "^/usr/share/ceph/mgr/" "$work/upstream.txt"); dashboard frontend files: $(grep -c "^/usr/share/ceph/mgr/dashboard/frontend/" "$work/upstream.txt")"
# upstream's /usr/sbin may be /usr/bin (merged usr): an entry exists if it does in either place
run "$ours" 'while read -r p; do [ -e "$p" ] || echo "$p"; done' <"$work/upstream.txt" | sort -u >"$work/missing.txt"

# --- python distributions and modules (appended to the missing entries, so allow/stale handling is shared)
pyrun() { local img=$1; shift; docker run --rm -e PYTHONDONTWRITEBYTECODE=1 -v "$here/pydists.py:/pydists.py:ro" 	-v "$work/pynames.txt:/pynames.txt:ro" --entrypoint python3 "$img" /pydists.py "$@" </dev/null; }
: >"$work/pynames.txt"
pyrun "$up" enum | sort -u >"$work/pyupstream.txt" || fail "cannot list upstream's python distributions"
echo "upstream python: $(grep -c '^pydist:' "$work/pyupstream.txt") distributions, $(grep -c '^pymod:' "$work/pyupstream.txt") unowned modules"
[ -s "$work/pyupstream.txt" ] || fail "no python distribution found in upstream's image"
cp "$work/pyupstream.txt" "$work/pynames.txt"
pyrun "$ours" missing /pynames.txt | sort -u >"$work/pymissing.txt" || fail "cannot check python distributions in our image"
cat "$work/pymissing.txt" >>"$work/missing.txt"
sort -u -o "$work/missing.txt" "$work/missing.txt"

# --- linkage: DT_NEEDED sonames of the daemons and libraries, in the image's own python3 (no readelf in a Nix image)
elfrun() { docker run --rm -v "$here/elfneeded.py:/elfneeded.py:ro" --entrypoint python3 "$1" /elfneeded.py </dev/null; }
elfrun "$up" | sort -u >"$work/elf-up.txt" || fail "cannot read the linkage of upstream's image"
elfrun "$ours" | sort -u >"$work/elf-ours.txt" || fail "cannot read the linkage of our image"
for k in up ours; do
	grep '^so:' "$work/elf-$k.txt" >"$work/so-$k.txt"
	sed -n 's/^closure:/so:/p' "$work/elf-$k.txt" | sort -u >"$work/closure-$k.txt"
	grep -E '^(absent|error|probe):' "$work/elf-$k.txt" | sed "s/^/$k: /"
done
echo "linkage: $(wc -l <"$work/so-up.txt") upstream direct sonames, $(wc -l <"$work/so-ours.txt") ours"
# upstream links it directly: a gap, unless ours reaches it through a shared library (upstream bundles rocksdb and boost
# statically, ours uses the shared ones, so zlib, lz4 and snappy come in through them)
comm -23 "$work/so-up.txt" "$work/so-ours.txt" >"$work/so-direct.txt"
comm -12 "$work/so-direct.txt" "$work/closure-ours.txt" >"$work/so-transitive.txt"
comm -23 "$work/so-direct.txt" "$work/closure-ours.txt" >"$work/so-missing.txt"
group() { awk -F: '{a[$3]=a[$3]" "$2} END{for(k in a)print "  " k ":" a[k]}' | sort; }
echo "== linkage only in ours (info)"; comm -13 "$work/so-up.txt" "$work/so-ours.txt" | group
echo "== linkage upstream has directly, ours reaches through a shared library (info)"; group <"$work/so-transitive.txt"
cat "$work/so-missing.txt" >>"$work/missing.txt"
sort -u -o "$work/missing.txt" "$work/missing.txt"

# Entries tagged [el9]/[el10] (the upstream image's userland) are not stale-checked for the other one.
userland=${PARITY_USERLAND:-el9}
patterns() { # glob patterns of a list file, checking each has an ADR 0002 reason; $2: file for the patterns of other userlands
	local f=$1 line tag
	while IFS= read -r line; do
		case $line in '' | '#'*) continue ;; esac
		grep -q '#.*ADR 0002' <<<"$line" || fail "$f: entry without '# reason, ADR 0002': $line"
		echo "${line%%#*}" | sed 's/[[:space:]]*$//'
		tag=$(grep -o '#[[:space:]]*\[el[0-9]*\]' <<<"$line" | grep -o 'el[0-9]*')
		if [ -n "$tag" ] && [ "$tag" != "$userland" ] && [ -n "${2:-}" ]; then
			echo "${line%%#*}" | sed 's/[[:space:]]*$//' >>"$2"
		fi
	done <"$f"
}
: >"$work/other.pat"
patterns "$here/parity-allow.txt" "$work/other.pat" >"$work/allow.pat"
patterns "$here/parity-pending.txt" >"$work/pending.pat"

matches() { # lines of $1 matching any glob of $2
	local p path
	while IFS= read -r path; do
		while IFS= read -r p; do
			# shellcheck disable=SC2254
			case $path in $p) echo "$path"; break ;; esac
		done <"$2"
	done <"$1"
}
matches "$work/missing.txt" "$work/allow.pat" | sort -u >"$work/allowed.txt"
comm -23 "$work/missing.txt" "$work/allowed.txt" >"$work/rest.txt"
matches "$work/rest.txt" "$work/pending.pat" | sort -u >"$work/pending.txt"
comm -23 "$work/rest.txt" "$work/pending.txt" >"$work/gaps.txt"

echo "missing in ours: $(wc -l <"$work/missing.txt"); allowed: $(wc -l <"$work/allowed.txt"); pending: $(wc -l <"$work/pending.txt"); gaps: $(wc -l <"$work/gaps.txt")"
if [ -s "$work/gaps.txt" ]; then
	echo "== unexplained gaps"; cat "$work/gaps.txt"
	fail "files missing in our image"
fi
if [ -s "$work/pending.txt" ]; then
	echo "== pending (closed by the Umbrella build)"; cat "$work/pending.txt"
	[ "${PARITY_PENDING_OK:-}" = 1 ] || fail "pending gaps and PARITY_PENDING_OK is not 1"
fi
echo "== allowed"; cat "$work/allowed.txt"
# stale list entries: an allow entry that explains no gap is a failure, a pending one only a notice
for l in allow pending; do
	while IFS= read -r p; do
		used=
		while IFS= read -r path; do
			# shellcheck disable=SC2254
			case $path in $p) used=1; break ;; esac
		done <"$work/missing.txt"
		[ -n "$used" ] && continue
		grep -qxF -- "$p" "$work/other.pat" && continue
		if [ $l = allow ]; then fail "unused allow entry: $p"; else echo "NOTE: unused pending entry: $p"; fi
	done <"$work/$l.pat"
done

# --- mgr modules importable
cat >"$work/mgrimport.py" <<'PY'
import importlib, os, sys, types

class Stub(types.ModuleType):  # ceph_module is built into ceph-mgr; stand in for it
    def __getattr__(self, name):
        if name.startswith("__"):
            raise AttributeError(name)
        cls = type(name, (object,), {})
        setattr(self, name, cls)
        return cls

sys.modules["ceph_module"] = Stub("ceph_module")
mgr = "/usr/share/ceph/mgr"
sys.path.insert(0, mgr)
for name in sorted(os.listdir(mgr)):
    if not os.path.exists(os.path.join(mgr, name, "__init__.py")):
        continue
    try:
        importlib.import_module(name)
        print("OK", name)
    except BaseException as e:
        print("FAIL", name, type(e).__name__, str(e).replace("\n", " ")[:200])
PY
for k in up ours; do
	img=${!k}
	docker run --rm -i -e PYTHONDONTWRITEBYTECODE=1 --entrypoint python3 "$img" - <"$work/mgrimport.py" >"$work/mgr-$k.txt" 2>"$work/mgr-$k.err" || cat "$work/mgr-$k.err"
done
echo "== mgr module imports (upstream | ours)"
join -j2 -a1 -a2 -e '?' -o 0,1.1,2.1 <(sort -k2 "$work/mgr-up.txt") <(sort -k2 "$work/mgr-ours.txt") | sort -u
grep '^FAIL' "$work/mgr-up.txt" | sed 's/^/upstream: /'
grep '^FAIL' "$work/mgr-ours.txt" | sed 's/^/ours:     /'
[ -s "$work/mgr-ours.txt" ] || fail "no mgr module imported in our image"
while read -r _ name _; do
	grep -q "^OK $name\$" "$work/mgr-up.txt" && fail "mgr module $name imports in upstream but not in ours"
done < <(grep '^FAIL' "$work/mgr-ours.txt")
while read -r _ name _; do
	grep -q "^OK $name\$" "$work/mgr-ours.txt" || fail "mgr module $name is missing in ours"
done < <(grep '^OK' "$work/mgr-up.txt")

# --- dashboard NVMe-oF client: its imports sit in try/except ImportError, so a missing grpc or protobuf shows up only as
# a mgr log line and a dashboard without NVMe-oF
cat >"$work/nvmeof.py" <<'PY'
import sys, types

class Stub(types.ModuleType):
    def __getattr__(self, name):
        if name.startswith("__"):
            raise AttributeError(name)
        cls = type(name, (object,), {})
        setattr(self, name, cls)
        return cls

sys.modules["ceph_module"] = Stub("ceph_module")
sys.path.insert(0, "/usr/share/ceph/mgr")
import dashboard.services.nvmeof_client as c
print("grpc" if c.grpc is not None else "no-grpc")
PY
for k in up ours; do
	img=${!k}
	r=$(docker run --rm -i -e PYTHONDONTWRITEBYTECODE=1 --entrypoint python3 "$img" - <"$work/nvmeof.py" 2>&1 | tail -n1)
	echo "dashboard nvmeof_client ($k): $r"
	[ "$r" = grpc ] || fail "dashboard.services.nvmeof_client has no grpc in $k image: $r"
done

echo "RESULT parity -> $([ $rc -eq 0 ] && echo OK || echo FAILED)"
exit $rc
