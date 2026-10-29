# casadm, casctl (python), the udev rules and systemd units of Open CAS, installed to $out.
{
  lib,
  stdenv,
  python3,
  makeWrapper,
  gzip,
  util-linux,
  systemd,
  src,
  # The udev loader runs this before attaching devices; on NixOS the wrapper in the system
  # profile knows where the kernel modules live.
  modprobePath ? "/run/current-system/sw/bin/modprobe",
}:
let
  common = import ./common.nix;
in
stdenv.mkDerivation {
  pname = "open-cas";
  inherit (common) version;
  inherit src;

  nativeBuildInputs = [
    python3
    makeWrapper
    gzip
  ];
  buildInputs = [ python3 ];

  # The Makefile sets -D_FORTIFY_SOURCE=2 itself.
  hardeningDisable = [ "fortify" ];

  postPatch = ''
    ${common.prepareVersion}

    substituteInPlace utils/opencas.py \
      --replace-fail "'/sbin/casadm'" "'$out/bin/casadm'"
    substituteInPlace utils/open-cas-loader.py \
      --replace-fail "'/sbin/modprobe'" "'${modprobePath}'"
    substituteInPlace utils/open-cas.service utils/open-cas-shutdown.service \
      --replace-fail "/sbin/casctl" "$out/bin/casctl"
    substituteInPlace utils/60-persistent-storage-cas-load.rules \
      --replace-fail "/lib/opencas/open-cas-loader.py" "$out/lib/opencas/open-cas-loader.py"

    sed -i -e 's/__CAS_DATE__/${common.version}/' -e 's/v_*_*CAS_VERSION__/v${common.version}/' \
      casadm/casadm.8 utils/casctl.8 utils/opencas.conf.5
  '';

  dontConfigure = true;

  buildPhase = ''
    runHook preBuild
    make -C casadm
    make -C utils
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall

    install -Dm755 casadm/casadm $out/bin/casadm
    install -Dm644 casadm/casadm.8.gz $out/share/man/man8/casadm.8.gz
    install -Dm644 utils/casctl.8.gz $out/share/man/man8/casctl.8.gz
    install -Dm644 utils/opencas.conf.5.gz $out/share/man/man5/opencas.conf.5.gz

    install -Dm644 utils/opencas.py $out/lib/opencas/opencas.py
    install -Dm755 utils/casctl $out/lib/opencas/casctl
    install -Dm755 utils/open-cas-loader.py $out/lib/opencas/open-cas-loader.py
    # The scripts import opencas.py from their own directory; the wrappers keep them there.
    for f in casctl open-cas-loader.py; do
      patchShebangs $out/lib/opencas/$f
      wrapProgram $out/lib/opencas/$f \
        --prefix PATH : ${
          lib.makeBinPath [
            util-linux
            systemd
          ]
        }
    done
    mkdir -p $out/bin
    ln -s $out/lib/opencas/casctl $out/bin/casctl

    install -Dm644 utils/60-persistent-storage-cas-load.rules \
      $out/lib/udev/rules.d/60-persistent-storage-cas-load.rules
    install -Dm644 utils/60-persistent-storage-cas.rules \
      $out/lib/udev/rules.d/60-persistent-storage-cas.rules

    install -Dm644 utils/open-cas.service $out/lib/systemd/system/open-cas.service
    install -Dm644 utils/open-cas-shutdown.service $out/lib/systemd/system/open-cas-shutdown.service

    # Reference files, the NixOS module generates the real ones.
    install -Dm644 utils/opencas.conf $out/share/doc/open-cas/opencas.conf
    install -Dm644 utils/ioclass-config.csv $out/share/doc/open-cas/ioclass-config.csv

    runHook postInstall
  '';

  meta = {
    description = "Open CAS cache acceleration: casadm, casctl, udev rules and systemd units (lhns fork with per-IO-class cache mode)";
    homepage = "https://github.com/lhns/open-cas-linux";
    license = lib.licenses.bsd3;
    platforms = [ "x86_64-linux" ];
    mainProgram = "casadm";
  };
}
