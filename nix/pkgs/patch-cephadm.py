"""Rewrite the cephadm zipapp so the units it writes carry X-StopOnRemoval=false.

NixOS's switch-to-configuration stops units whose file lives in /etc/systemd/system but not in the new
generation, which would take down every Ceph daemon on each switch. The templates and the generated
targets get the key in their [Unit] section; the stale .pyc of a patched module is dropped.

With a third argument "backport-80399" (Tentacle's cephadm) it also applies ceph/ceph#72033 (commit 0462865065, the
backport of 25de0e2ff0): a keyring that differs only in caps no longer triggers OSD.rotate_osd_lv_keyring, which
stops and restarts the OSD and can leave it stopped (tracker issue 80399). Umbrella's cephadm has the fix.
"""
import sys
import zipfile

src, dst = sys.argv[1:3]
backport = sys.argv[3:] == ["backport-80399"]
KEY = "X-StopOnRemoval=false"
TEMPLATES = (
    "ceph.service.j2",
    "init_ctr.service.j2",
    "sidecar.service.j2",
    "agent.service.j2",
)
SYSTEMD_UNIT = "cephadmlib/systemd_unit.py"
MAIN = "__main__.py"  # src/cephadm/cephadm.py
DATA_UTILS = "cephadmlib/data_utils.py"
patched = set()
PARSE_INI = '''def parse_ini_section(
    text: str, entity: str, option: Optional[str] = None
) -> Optional[Any]:
    """Parse text as INI and return the option of entity (None when absent or unparseable)."""
    parser = ConfigParser(interpolation=None)
    try:
        parser.read_string(text)
    except Exception:
        return None
    if not parser.has_section(entity):
        return None
    if option is not None:
        return parser.get(entity, option, fallback=None)
    return dict(parser.items(entity))
'''


def replace_once(text, old, new):
    assert text.count(old) == 1, old
    return text.replace(old, new)


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
    if backport and name == MAIN:
        text = replace_once(text, "    dict_get_join,\n", "    dict_get_join,\n    parse_ini_section,\n")
        old = """            # need to update keyring with ceph-bluestore-tool
            update_bluestore_label_osd_keyring = True
"""
        new = """            # The raw keyrings differ, maybe only in caps: update the bluestore label only if the key changed.
            existing_key = parse_ini_section(key_path_content, ident.daemon_name, 'key')
            new_key = parse_ini_section(keyring, ident.daemon_name, 'key')
            if existing_key and new_key and existing_key != new_key:
                # need to update keyring with ceph-bluestore-tool
                update_bluestore_label_osd_keyring = True
            else:
                logger.debug(
                    'OSD keyring key value unchanged (only caps differ); '
                    'skipping bluestore-label keyring update for %s',
                    ident.daemon_id,
                )
"""
        return replace_once(text, old, new)
    if backport and name == DATA_UTILS:
        return replace_once(text, "def try_convert_datetime(s):", PARSE_INI + "\n\ndef try_convert_datetime(s):")
    return None


data = open(src, "rb").read()
shebang = data[: data.index(b"\n") + 1]
assert shebang.startswith(b"#!")
zin = zipfile.ZipFile(src)
with open(dst, "wb") as f:
    f.write(shebang)
    with zipfile.ZipFile(f, "w") as zout:
        for info in zin.infolist():
            if info.filename in ("cephadmlib/systemd_unit.pyc", "cephadmlib/data_utils.pyc") or (backport and info.filename == "__main__.pyc"):
                continue
            content = zin.read(info)
            if info.filename.endswith((".j2", SYSTEMD_UNIT, MAIN, DATA_UTILS)):
                new = patch_text(info.filename, content.decode())
                if new is not None:
                    content = new.encode()
                    patched.add(info.filename)
            zout.writestr(info, content)
want = {"cephadmlib/templates/" + t for t in TEMPLATES} | {SYSTEMD_UNIT}
if backport:
    want |= {MAIN, DATA_UTILS}
assert patched == want, (patched, want)
