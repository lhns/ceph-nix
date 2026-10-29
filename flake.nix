{
  description = "Ceph for x86-64-v2 hosts, built with Nix: container image, cephadm host module, OpenCAS";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";

  # The fork adds a per-IO-class cache mode; OCF is a submodule.
  inputs.open-cas-src = {
    url = "git+https://github.com/lhns/open-cas-linux?ref=refs/tags/v26.03.3%2Bmode.2&submodules=1";
    flake = false;
  };

  outputs =
    {
      self,
      nixpkgs,
      open-cas-src,
    }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
      ocPkgs = import nixpkgs {
        inherit system;
        overlays = [ self.overlays.default ];
      };
      ocKernels = ocPkgs.linuxKernel.packages;
    in
    {
      overlays.default = import ./nix/overlays/open-cas.nix { inherit open-cas-src; };

      formatter.${system} = pkgs.nixfmt;

      packages.${system} = {
        open-cas = ocPkgs.open-cas;
        open-cas-kmod = ocPkgs.linuxPackages.open-cas;
      };

      nixosModules.opencas =
        { ... }:
        {
          imports = [ ./nix/modules/opencas.nix ];
          nixpkgs.overlays = [ self.overlays.default ];
        };

      checks.${system} = {
        opencas = import ./nix/tests/opencas.nix { inherit pkgs self; };
        # Supported kernels (5.10 to 7.0): the default one is also covered by the VM test.
        open-cas-kmod-lts = ocKernels.linux_6_12.open-cas;
        open-cas-kmod-latest = ocKernels.linux_6_18.open-cas;
        formatting =
          pkgs.runCommand "formatting"
            {
              nativeBuildInputs = [
                pkgs.nixfmt
                pkgs.findutils
              ];
            }
            ''
              cd ${self}
              find . -name '*.nix' -exec nixfmt --check {} +
              touch $out
            '';
      };
    };
}
