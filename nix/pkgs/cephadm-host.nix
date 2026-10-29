# cephadm for NixOS hosts: the upstream zipapp of a Ceph release, patched so the units it writes carry
# X-StopOnRemoval=false (see patch-cephadm.py). The mgr copies cephadm from the *image* when it manages
# other hosts, so the patch fully applies once our image ships this cephadm; until then the module's
# unit-keep service adds the same key as a drop-in.
{
  lib,
  fetchurl,
  python3,
  runCommand,
  writeShellScriptBin,
  version ? "21.2.0",
  hash ? "sha256-9JTvZ2AfWIjXLdJrT4zJQcyG3qxpMA6LgWB4eNBRtRY=",
}:
let
  zipapp = fetchurl {
    url = "https://download.ceph.com/rpm-${version}/el9/noarch/cephadm";
    inherit hash;
  };
  patched = runCommand "cephadm-patched-${version}" { nativeBuildInputs = [ python3 ]; } ''
    python3 ${./patch-cephadm.py} ${zipapp} $out
    chmod 755 $out
  '';
in
writeShellScriptBin "cephadm" ''
  exec ${python3}/bin/python3 -s ${patched} "$@"
''
