#!/usr/bin/env python3
"""DT_NEEDED sonames of Ceph's daemons and libraries, for the linkage diff of tests/parity.sh (ADR 0002).

Run with the image's own python3 (no readelf in a Nix image), so it must work on Python 3.9 (EL9) and up.
  elfneeded.py                 print "so:<binary>:<normalized soname>" lines
Nix wrappers (.ceph-osd-wrapped, or a script that execs the store path) are resolved to the real ELF. A soname is
normalized by dropping the directory, the version after ".so" and a version in the name (libboost_system.so.1.87.0 ->
libboost_system.so, liblua-5.4.so -> liblua.so, libpython3.9.so.1.0 -> libpython3.so).
  so:<name>:<soname>       direct DT_NEEDED
  closure:<name>:<soname>  every library ldd resolves (to tell a direct link from one through a shared library)
  probe:<name>:<what>=<n>  feature probes, info only
"""
import glob
import os
import re
import struct
import subprocess

BINARIES = ["ceph-osd", "ceph-mon", "ceph-mgr", "ceph-mds", "radosgw", "rbd-mirror", "ceph-fuse", "rbd-nbd"]
LOADER = {"ld-linux-x86.so"}  # the dynamic loader, which Nix binaries list and EL ones do not
LIBRARIES = ["librados", "librbd", "libcephfs", "librgw", "libcephsqlite", "libradosstriper", "libceph-common"]


def is_elf(path):
    try:
        with open(path, "rb") as f:
            return f.read(4) == b"\x7fELF"
    except OSError:
        return False


def real_elf(path):
    """Follow symlinks and Nix wrappers until an ELF file is found."""
    seen = set()
    while path and path not in seen:
        seen.add(path)
        path = os.path.realpath(path)
        if is_elf(path):
            return path
        d, b = os.path.split(path)
        wrapped = os.path.join(d, "." + b + "-wrapped")
        if os.path.exists(wrapped):
            path = wrapped
            continue
        try:
            text = open(path, errors="replace").read(65536)
        except OSError:
            return None
        m = re.findall(r"exec(?: -a \"?\$0\"?)? +\"?(/[^\s\"']+)", text)
        path = m[-1] if m else None
    return None


def needed(path):
    with open(path, "rb") as f:
        data = f.read()
    if data[4] != 2 or data[5] != 1:
        raise ValueError("not ELF64 little endian")
    phoff, = struct.unpack_from("<Q", data, 0x20)
    phentsize, phnum = struct.unpack_from("<HH", data, 0x36)
    loads, dyn = [], None
    for i in range(phnum):
        p_type, _, p_off, p_vaddr, _, p_filesz, _, _ = struct.unpack_from("<IIQQQQQQ", data, phoff + i * phentsize)
        if p_type == 1:
            loads.append((p_vaddr, p_off, p_filesz))
        elif p_type == 2:
            dyn = (p_off, p_filesz)
    if dyn is None:
        return []

    def off(vaddr):
        for va, fo, sz in loads:
            if va <= vaddr < va + sz:
                return vaddr - va + fo
        raise ValueError("address outside segments")

    names, strtab = [], None
    for pos in range(dyn[0], dyn[0] + dyn[1], 16):
        tag, val = struct.unpack_from("<qQ", data, pos)
        if tag == 0:
            break
        if tag == 1:
            names.append(val)
        elif tag == 5:
            strtab = off(val)
    out = []
    for n in names:
        end = data.index(b"\0", strtab + n)
        out.append(data[strtab + n:end].decode())
    return out


def norm(soname):
    s = os.path.basename(soname)
    s = re.sub(r"\.so(\..*)?$", ".so", s)
    s = re.sub(r"^libpython3.[0-9]+", "libpython3", s)
    s = re.sub(r"^libboost_python[0-9]+", "libboost_python", s)
    s = re.sub(r"-[0-9][0-9.]*\.so$", ".so", s)
    return s


def closure(elf):
    try:
        out = subprocess.run(["ldd", elf], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, universal_newlines=True,
                             env={"PATH": os.environ.get("PATH", "")}).stdout
    except OSError:
        return None
    return {norm(m.group(1)) for m in re.finditer(r"^\s*(\S+) =>", out, re.M)}


def find(name):
    if name.startswith("lib"):
        for d in ("/usr/lib64", "/usr/lib", "/usr/lib64/ceph"):
            for p in sorted(glob.glob("%s/%s.so.*" % (d, name))) + sorted(glob.glob("%s/%s.so" % (d, name))):
                if real_elf(p):
                    return p
        return None
    for d in ("/usr/bin", "/usr/sbin"):
        if os.path.lexists(os.path.join(d, name)):
            return os.path.join(d, name)
    return None


def main():
    for name in BINARIES + LIBRARIES:
        path = find(name)
        elf = real_elf(path) if path else None
        if not elf:
            print("absent:%s" % name)
            continue
        try:
            sonames = needed(elf)
        except (OSError, ValueError, struct.error) as e:
            print("error:%s:%s" % (name, e))
            continue
        for so in sorted({norm(s) for s in sonames} - LOADER):
            print("so:%s:%s" % (name, so))
        for so in sorted((closure(elf) or set()) - LOADER):
            print("closure:%s:%s" % (name, so))
        if name in ("librbd", "rbd-mirror"):
            with open(elf, "rb") as f:
                print("probe:%s:ReplicatedWriteLog=%d" % (name, f.read().count(b"ReplicatedWriteLog")))


main()
