# Shared by userspace.nix and kmod.nix.
{
  version = "26.03.3+mode.2";

  # tools/cas_version_gen.sh needs a git checkout or this file; the Nix source has no .git.
  # Format: "%02d.%02d.%01d.%04d.%s" of main, major, minor, merge count, release type.
  prepareVersion = ''
    mkdir -p .metadata
    cat > .metadata/cas_version <<'EOV'
    CAS_VERSION_MAIN=26
    CAS_VERSION_MAJOR=3
    CAS_VERSION_MINOR=3
    CAS_VERSION_BUILD=0
    CAS_VERSION_RELEASE=release
    CAS_VERSION=26.03.3.0000.release
    EOV
  '';
}
