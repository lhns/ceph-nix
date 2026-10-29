"""Rewrite the cephadm zipapp so the units it writes carry X-StopOnRemoval=false.

NixOS's switch-to-configuration stops units whose file lives in /etc/systemd/system but not in the new
generation, which would take down every Ceph daemon on each switch. The templates and the generated
targets get the key in their [Unit] section; the stale .pyc of a patched module is dropped.
"""
import sys
import zipfile

src, dst = sys.argv[1:3]
KEY = "X-StopOnRemoval=false"
TEMPLATES = (
    "ceph.service.j2",
    "init_ctr.service.j2",
    "sidecar.service.j2",
    "agent.service.j2",
)
SYSTEMD_UNIT = "cephadmlib/systemd_unit.py"
patched = set()


def patch_text(name, text):
    if name.startswith("cephadmlib/templates/") and name.rsplit("/", 1)[-1] in TEMPLATES:
        assert text.count("[Unit]\n") == 1, name
        return text.replace("[Unit]\n", "[Unit]\n" + KEY + "\n")
    if name == SYSTEMD_UNIT:
        # ceph.target and ceph-<fsid>.target are written as '[Unit]\n' 'Description=...' string literals
        head = "'[Unit]\\n'\n            "
        for desc in ("'Description=All Ceph", "'Description=Ceph cluster"):
            assert text.count(head + desc) == 1, desc
            text = text.replace(head + desc, head + "'" + KEY + "\\n'\n            " + desc)
        return text
    return None


data = open(src, "rb").read()
shebang = data[: data.index(b"\n") + 1]
assert shebang.startswith(b"#!")
zin = zipfile.ZipFile(src)
with open(dst, "wb") as f:
    f.write(shebang)
    with zipfile.ZipFile(f, "w") as zout:
        for info in zin.infolist():
            if info.filename == "cephadmlib/systemd_unit.pyc":
                continue
            content = zin.read(info)
            if info.filename.endswith((".j2", SYSTEMD_UNIT)):
                new = patch_text(info.filename, content.decode())
                if new is not None:
                    content = new.encode()
                    patched.add(info.filename)
            zout.writestr(info, content)
want = {"cephadmlib/templates/" + t for t in TEMPLATES} | {SYSTEMD_UNIT}
assert patched == want, (patched, want)
