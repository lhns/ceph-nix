# The cephadm zipapp from the same Ceph source as `ceph`, made self-contained.
# nixpkgs builds it without bundled dependencies (CEPHADM_BUNDLED_DEPENDENCIES=none), so it needs jinja2 and
# markupsafe from the host's python; the orchestrator ships /usr/sbin/cephadm to hosts that have neither (NixOS).
# Bundle the pure-python code of both, as upstream's build.py does with pip.
{ runCommand, ceph }:
let
  py = ceph.pythonEnv;
in
runCommand "cephadm-${ceph.version}" { nativeBuildInputs = [ py ]; } ''
  mkdir -p $out/bin
  python3 ${./bundle-cephadm.py} ${ceph}/bin/.cephadm-wrapped $out/bin/cephadm
  chmod 755 $out/bin/cephadm
''
