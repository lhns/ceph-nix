# rtslib-fb 2.1.76 (upstream's image: python3-rtslib-2.1.76). nixpkgs has 2.2.x, which renamed RTSLibNotInCFS, and
# ceph-iscsi 3.9 imports the old name.
{
  buildPythonPackage,
  fetchFromGitHub,
  pyudev,
  six,
}:
buildPythonPackage {
  pname = "rtslib-fb";
  version = "2.1.76";
  format = "setuptools";

  src = fetchFromGitHub {
    owner = "open-iscsi";
    repo = "rtslib-fb";
    tag = "v2.1.76";
    hash = "sha256-z9fpSVyv96ZoJaP0ch2A3bX/o/K23ooEpxa/OAhY6Z4=";
  };

  propagatedBuildInputs = [
    pyudev
    six
  ];

  doCheck = false;
  pythonImportsCheck = [ "rtslib_fb" ];

  meta = {
    description = "Python object API for managing the Linux LIO kernel target";
    homepage = "https://github.com/open-iscsi/rtslib-fb";
  };
}
