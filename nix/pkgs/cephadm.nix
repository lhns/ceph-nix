# The cephadm zipapp from the same Ceph source as `ceph`, made self-contained and patched.
# nixpkgs builds it without bundled dependencies (CEPHADM_BUNDLED_DEPENDENCIES=none), so it needs jinja2,
# markupsafe and yaml from the host's python; the orchestrator ships /usr/sbin/cephadm to hosts that have none
# of them (NixOS). Bundle the pure-python code, as upstream's build.py does with pip. Then patch the units it
# writes to carry X-StopOnRemoval=false (patch-cephadm.py), so NixOS hosts keep their daemons across a switch.
# Tentacle's also gets the backport of ceph/ceph#72033 (ADR 0004 amendment).
#
# One cephadm for image and host: the image ships it (the mgr hands it out to the hosts), and `.host` runs the same
# file on a NixOS host, whose python3 is not at /usr/bin/python3 by default.
{
  lib,
  runCommand,
  writeShellScriptBin,
  python3,
  ceph,
}:
let
  py = ceph.pythonEnv;
  cephadm = runCommand "cephadm-${ceph.version}" { nativeBuildInputs = [ py ]; } ''
    mkdir -p $out/bin
    python3 ${./bundle-cephadm.py} ${ceph}/bin/.cephadm-wrapped bundled
    python3 ${./patch-cephadm.py} bundled $out/bin/cephadm ${lib.optionalString (lib.versionOlder ceph.version "21") "backport-80399"}
    chmod 755 $out/bin/cephadm
  '';
in
cephadm
// {
  # Host wrapper: the zipapp's `/usr/bin/python3` shebang is bypassed by running it with the host's python.
  host = writeShellScriptBin "cephadm" ''
    exec ${python3}/bin/python3 -s ${cephadm}/bin/cephadm "$@"
  '';
}
