# Python side of tests/parity.sh: what the image's python3 (the mgr's) can import from site-packages.
#   pydists.py enum              print "pydist:<distribution>" for every installed distribution and "pymod:<module>"
#                                for every top-level module no distribution owns (distro bindings without metadata)
#   pydists.py missing FILE      print the lines of FILE (output of enum elsewhere) that this python lacks
# Names are normalized (case, runs of - _ . become -). A distribution is present by metadata; a module by find_spec.
import importlib.metadata as md
import importlib.util
import os
import re
import sys


def norm(name):
    return re.sub(r"[-_.]+", "-", name).lower()


def dists():
    names = {}
    for d in md.distributions():
        n = d.metadata["Name"]
        if n:
            names.setdefault(norm(n), d)
    return names


def toplevel(base, entry):  # module name of a site-packages entry, or None
    if entry == "__pycache__" or entry.endswith((".dist-info", ".egg-info", ".pth", ".egg-link")):
        return None
    if os.path.isdir(os.path.join(base, entry)):
        return entry
    return entry.split(".", 1)[0] if entry.endswith((".py", ".so")) else None


def enum():
    ds = dists()
    # top-level names that distributions own: their installed files, top_level.txt, or a name equal to theirs (EL's
    # RPM-built distributions often have no RECORD)
    owned = {n.replace("-", "_") for n in ds}
    for d in ds.values():
        owned.update((d.read_text("top_level.txt") or "").split())
        for f in d.files or []:
            if f.parts and f.parts[0] != "..":
                owned.add(f.parts[0].split(".", 1)[0])
    mods = set()
    for p in sys.path:
        if p.rstrip("/").endswith(("site-packages", "dist-packages")) and os.path.isdir(p):
            mods.update(m for m in (toplevel(p, e) for e in os.listdir(p)) if m)
    return sorted({"pydist:" + n for n in ds} | {"pymod:" + m for m in mods - owned})


def has_module(name):
    try:
        return importlib.util.find_spec(name) is not None
    except (ImportError, ValueError):
        return False


if sys.argv[1] == "enum":
    lines = enum()
    print("\n".join(lines))
else:
    ours = dists()
    for line in open(sys.argv[2]).read().split():
        kind, _, name = line.partition(":")
        if (kind == "pydist" and name not in ours) or (kind == "pymod" and not has_module(name)):
            print(line)
