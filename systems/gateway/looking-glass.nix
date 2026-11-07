{ pkgs, ... }:
{
  environment.systemPackages = [
    (pkgs.callPackage ../../packages/routerctl/package.nix { })
    pkgs.procps
  ];
  boot.kernelModules = [ "nf_conntrack" ];
  # Account for packets and bytes in each direction of newly created flows.
  boot.kernel.sysctl."net.netfilter.nf_conntrack_acct" = 1;
}
