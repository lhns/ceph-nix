{
  description = "Ceph for x86-64-v2 hosts, built with Nix: container image, cephadm host module, OpenCAS";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
  inputs.nixos-cloudinit = {
    url = "github:lhns/nixos-cloudinit";
    inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs =
    {
      self,
      nixpkgs,
      nixos-cloudinit,
    }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
    in
    {
      formatter.${system} = pkgs.nixfmt;

      packages.${system} = { };

      nixosModules = { };

      checks.${system} = {
        cephadm-spike = import ./nix/tests/cephadm-spike.nix { inherit pkgs nixos-cloudinit; };
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
