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

      packages.${system} = import ./nix/images { inherit pkgs self; };

      nixosModules = { };

      checks.${system} = {
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
