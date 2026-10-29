#!/usr/bin/env bash
# File-tree parity with the upstream image, ADR 0002 dimension (a).
#   parity.sh UPSTREAM_IMAGE OUR_IMAGE EXPECTED_MAJOR_MINOR      e.g. quay.io/ceph/ceph:v20.2.4 ceph-nix:... 20.2
# Every entry of upstream's /usr/bin, /usr/sbin, /usr/libexec/ceph, /usr/lib64/ceph and /usr/share/ceph/mgr must exist
# (resolve) in ours, unless tests/parity-allow.txt allows it. Gaps the Umbrella build closes are in
# tests/parity-pending.txt and only tolerated with PARITY_PENDING_OK=1. Both files: one shell glob per line, then
# "# reason, ADR 0002".
# Also: `ceph -v` is EXPECTED_MAJOR_MINOR, and every mgr module that imports in upstream's image imports in ours.
set -uo pipefail
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
run "$up" 'for d in /usr/bin /usr/sbin /usr/libexec/ceph /usr/lib64/ceph /usr/share/ceph/mgr; do
	ls -A "$d" | sed "s|^|$d/|"; done' </dev/null | sort -u >"$work/upstream.txt"
echo "upstream entries: $(wc -l <"$work/upstream.txt")"
# upstream's /usr/sbin may be /usr/bin (merged usr): an entry exists if it does in either place
run "$ours" 'while read -r p; do [ -e "$p" ] || echo "$p"; done' <"$work/upstream.txt" | sort -u >"$work/missing.txt"

patterns() { # glob patterns of a list file, checking each has an ADR 0002 reason
	local f=$1 line
	while IFS= read -r line; do
		case $line in '' | '#'*) continue ;; esac
		grep -q '#.*ADR 0002' <<<"$line" || fail "$f: entry without '# reason, ADR 0002': $line"
		echo "${line%%#*}" | sed 's/[[:space:]]*$//'
	done <"$f"
}
patterns "$here/parity-allow.txt" >"$work/allow.pat"
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
# stale list entries
for l in allow pending; do
	while IFS= read -r p; do
		grep -q -x -e "$(sed 's/[][\.^$]/\&/g; s/\*/.*/g; s/?/./g' <<<"$p")" "$work/missing.txt" || echo "NOTE: unused $l entry: $p"
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
join -j2 -a1 -a2 -e '?' -o 1.1,2.1 <(sort -k2 "$work/mgr-up.txt") <(sort -k2 "$work/mgr-ours.txt") | sort -u
grep '^FAIL' "$work/mgr-up.txt" | sed 's/^/upstream: /'
grep '^FAIL' "$work/mgr-ours.txt" | sed 's/^/ours:     /'
[ -s "$work/mgr-ours.txt" ] || fail "no mgr module imported in our image"
while read -r _ name _; do
	grep -q "^OK $name\$" "$work/mgr-up.txt" && fail "mgr module $name imports in upstream but not in ours"
done < <(grep '^FAIL' "$work/mgr-ours.txt")
while read -r _ name _; do
	grep -q "^OK $name\$" "$work/mgr-ours.txt" || fail "mgr module $name is missing in ours"
done < <(grep '^OK' "$work/mgr-up.txt")

echo "RESULT parity -> $([ $rc -eq 0 ] && echo OK || echo FAILED)"
exit $rc
