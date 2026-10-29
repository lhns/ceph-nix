"""Rewrite nixpkgs' cephadm zipapp: FHS shebang, jinja2 and markupsafe bundled."""
import os
import sys
import zipfile

import jinja2
import markupsafe

src, dst = sys.argv[1:3]
data = open(src, "rb").read()
assert data.startswith(b"#!"), "cephadm is expected to be a zipapp with a shebang"
with open(dst, "wb") as f:
    f.write(b"#!/usr/bin/python3\n" + data[data.index(b"\n") + 1 :])

with zipfile.ZipFile(dst, "a") as z:
    names = set(z.namelist())
    for mod in (jinja2, markupsafe):
        root = os.path.dirname(os.path.realpath(mod.__file__))
        parent = os.path.dirname(root)
        for dirpath, dirnames, files in os.walk(root):
            dirnames[:] = [d for d in dirnames if d != "__pycache__"]
            for name in files:
                # the C speedups can't be loaded from a zip; markupsafe falls back to pure python
                if not name.endswith((".py", ".typed")):
                    continue
                path = os.path.join(dirpath, name)
                arc = os.path.relpath(path, parent)
                assert arc not in names, arc
                info = zipfile.ZipInfo(arc, date_time=(1980, 1, 1, 0, 0, 0))  # store paths have mtime 1
                info.compress_type = zipfile.ZIP_DEFLATED
                info.external_attr = 0o644 << 16
                with open(path, "rb") as f:
                    z.writestr(info, f.read())
