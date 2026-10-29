# ceph-iscsi 3.9-2 (upstream's image: ceph-iscsi-3.9-2.g6f9a6d2.el9): rbd-target-api, rbd-target-gw and gwcli.
# The scripts keep the RPM's `#!/usr/bin/python3`: cephadm's iSCSI container runs them in the image's python, whose
# PYTHONPATH carries this package and its dependencies (mkCephImage's extraPython). rados/rbd come from the image's ceph.
{
  python,
  buildPythonPackage,
  fetchFromGitHub,
  cryptography,
  configshell-fb,
  distro,
  flask,
  netifaces,
  pyopenssl,
  requests,
  callPackage,
}:
buildPythonPackage {
  pname = "ceph-iscsi";
  version = "3.9-2.g6f9a6d2";
  format = "other";

  src = fetchFromGitHub {
    owner = "ceph";
    repo = "ceph-iscsi";
    rev = "6f9a6d294fbae9526c598b269490f97a04a34c68";
    hash = "sha256-L1t5SYw+oCnk2eONxh0u3K5OVorMtqt445okDKPJ1m0=";
  };

  propagatedBuildInputs = [
    configshell-fb
    cryptography
    distro
    flask
    netifaces
    pyopenssl
    requests
    (callPackage ./rtslib-fb.nix { })
  ];

  dontBuild = true;
  dontPatchShebangs = true;
  dontWrapPythonPrograms = true; # keep the plain scripts; the image sets PYTHONPATH
  doCheck = false;

  # setup.py would do the same (and needs distutils); the RPM's file list is these two packages and three scripts
  installPhase = ''
    runHook preInstall
    mkdir -p $out/bin $out/share/doc/ceph-iscsi $out/share/man/man8 $out/etc/target/pr $out/etc/target/alua
    d=$out/${python.sitePackages}
    mkdir -p $d
    cp -r ceph_iscsi_config gwcli $d/
    for s in rbd-target-gw rbd-target-api gwcli; do
      install -m755 $s.py $out/bin/$s
      sed -i '1s|^#!.*|#!/usr/bin/python3|' $out/bin/$s
    done
    install -m644 gwcli.8 $out/share/man/man8/
    install -m644 README iscsi-gateway.cfg_sample $out/share/doc/ceph-iscsi/
    runHook postInstall
  '';

  meta = {
    description = "iSCSI gateway for Ceph RBD: rbd-target-api, rbd-target-gw, gwcli";
    homepage = "https://github.com/ceph/ceph-iscsi";
    license = "GPL-3.0-or-later";
    mainProgram = "gwcli";
  };
}
