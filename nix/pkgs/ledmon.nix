# libled (Intel ledmon >= 1.0), which libstoragemgmt links for enclosure/drive LED control. nixpkgs' ledmon is 0.92,
# which has neither the library nor the pkg-config file. Library only: the ledmon/ledctl daemons are not needed.
{
  lib,
  stdenv,
  fetchFromGitHub,
  autoreconfHook,
  autoconf-archive,
  pkg-config,
  perl,
  systemdLibs,
  sg3_utils,
  pciutils,
}:
stdenv.mkDerivation (finalAttrs: {
  pname = "ledmon";
  version = "1.1.0";

  src = fetchFromGitHub {
    owner = "intel";
    repo = "ledmon";
    tag = "v${finalAttrs.version}";
    hash = "sha256-ecO5aMN+X1H7qKhuk/XyY47L+SomrrrWYnTAHzsu30Q=";
  };

  nativeBuildInputs = [
    autoreconfHook
    autoconf-archive
    pkg-config
    perl
  ];
  buildInputs = [
    systemdLibs
    sg3_utils
    pciutils
  ];

  configureFlags = [
    "--enable-library"
    "--disable-doc"
  ];
  # BUILD_LABEL is the only git-derived value
  makeFlags = [ "BUILD_LABEL=${finalAttrs.version}" ];

  meta = {
    description = "Enclosure LED library (libled) from Intel ledmon";
    homepage = "https://github.com/intel/ledmon";
    license = lib.licenses.gpl2Only;
    platforms = lib.platforms.linux;
  };
})
