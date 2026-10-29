{
  description = "Ceph for x86-64-v2 hosts, built with Nix: container image, cephadm host module, OpenCAS";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";

  outputs =
    { self, nixpkgs }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
    in
    {
      formatter.${system} = pkgs.nixfmt;

      packages.${system} = { };

      nixosModules.builder = import ./nix/modules/builder.nix;

      checks.${system} = {
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
