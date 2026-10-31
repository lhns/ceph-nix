{
  description = "Ceph for x86-64-v2 hosts, built with Nix: container image, cephadm host module, OpenCAS";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
  inputs.nixos-cloudinit = {
    url = "github:lhns/nixos-cloudinit";
    inputs.nixpkgs.follows = "nixpkgs";
  };

  # Open CAS packages and module (ADR 0009); it brings its own open-cas-src.
  inputs.opencas-nix = {
    url = "github:lhns/opencas-nix";
    inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs =
    {
      self,
      nixpkgs,
      nixos-cloudinit,
      opencas-nix,
    }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
    in
    {
      overlays.default = opencas-nix.overlays.default;

      formatter.${system} = pkgs.nixfmt;

      packages.${system} = import ./nix/images { inherit pkgs self; } // {
        # Slow VM test (about 30 minutes): run by .github/workflows/vm-tests.yml, not part of `checks`.
        test-ceph-host = import ./nix/tests/ceph-host.nix {
          inherit
            pkgs
            self
            nixos-cloudinit
            opencas-nix
            ;
        };
        test-ceph-cpu = import ./nix/tests/ceph-cpu.nix { inherit pkgs self; };
        # The same tests with the Umbrella image: run on the self-hosted builder, not by CI (ADR 0007).
        test-ceph-host-umbrella = import ./nix/tests/ceph-host.nix {
          inherit
            pkgs
            self
            nixos-cloudinit
            opencas-nix
            ;
          track = "umbrella";
        };
        test-ceph-cpu-umbrella = import ./nix/tests/ceph-cpu.nix {
          inherit pkgs self;
          track = "umbrella";
        };
      };

      nixosModules = {
        builder = import ./nix/modules/builder.nix;
        ceph-host = import ./nix/modules/ceph-host.nix;
        # Re-exported so existing users keep working; it lives in lhns/opencas-nix.
        opencas = opencas-nix.nixosModules.opencas;
      };

      checks.${system} = {
        # Evaluates a system using the ceph-host module, without building it.
        ceph-host-eval =
          let
            sys = nixpkgs.lib.nixosSystem {
              inherit system;
              modules = [
                self.nixosModules.ceph-host
                {
                  services.ceph-host = {
                    enable = true;
                    image = "localhost/ceph-nix:test";
                    clientKernelModules = true;
                    orchestratorKeys = [ "ssh-ed25519 AAAA test" ];
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
          pkgs.writeText "ceph-host-eval" (
            builtins.unsafeDiscardStringContext sys.config.system.build.toplevel.drvPath
          );
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
