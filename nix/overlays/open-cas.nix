# Adds `open-cas` (userspace) and `open-cas` to every linuxPackages set (kernel module).
{ open-cas-src }:
final: prev:
let
  extendKernelPackages =
    set:
    # Lazy per attribute: removed-kernel aliases that throw are never touched.
    prev.lib.mapAttrs (
      _: ps:
      ps.extend (
        self: _: {
          open-cas = self.callPackage ./../pkgs/open-cas/kmod.nix { src = open-cas-src; };
        }
      )
    ) set;
in
{
  open-cas = final.callPackage ./../pkgs/open-cas/userspace.nix { src = open-cas-src; };

  linuxKernel = prev.linuxKernel // {
    packages = extendKernelPackages prev.linuxKernel.packages;
    packageAliases = extendKernelPackages prev.linuxKernel.packageAliases;
  };
}
