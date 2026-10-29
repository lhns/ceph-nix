{
  description = "Ceph for x86-64-v2 hosts, built with Nix: container image, cephadm host module, OpenCAS";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
  inputs.nixos-cloudinit = {
    url = "github:lhns/nixos-cloudinit";
    inputs.nixpkgs.follows = "nixpkgs";
  };

  # The fork adds a per-IO-class cache mode; OCF is a submodule.
  inputs.open-cas-src = {
    url = "git+https://github.com/lhns/open-cas-linux?ref=refs/tags/v26.03.3%2Bmode.2&submodules=1";
    flake = false;
  };

  outputs =
    {
      self,
      nixpkgs,
      nixos-cloudinit,
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

      nixosModules.builder = import ./nix/modules/builder.nix;

      checks.${system} = {
        cephadm-spike = import ./nix/tests/cephadm-spike.nix { inherit pkgs nixos-cloudinit; };
        opencas = import ./nix/tests/opencas.nix { inherit pkgs self; };
        # Supported kernels (5.10 to 7.0): the default one is also covered by the VM test.
        open-cas-kmod-lts = ocKernels.linux_6_12.open-cas;
        open-cas-kmod-latest = ocKernels.linux_6_18.open-cas;
        # Evaluates a system using the builder module, without building it.
        builder-eval =
          let
            sys = nixpkgs.lib.nixosSystem {
              inherit system;
              modules = [
                self.nixosModules.builder
                {
                  services.ceph-nix-builder = {
                    enable = true;
                    runner.tokenFile = "/run/secrets/runner-token";
                    cache.signingKeyFile = "/run/secrets/cache-key";
                    gcRoots = [ pkgs.hello ];
                  };
                  boot.loader.grub.enable = false;
                  fileSystems."/" = {
                    device = "none";
                    fsType = "tmpfs";
                  };
                  system.stateVersion = "26.05";
                }
              ];
            };
          in
          pkgs.writeText "builder-eval" (
            builtins.unsafeDiscardStringContext sys.config.system.build.toplevel.drvPath
          );

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
