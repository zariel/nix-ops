{ ... }:
{
  imports = [
    ./hardening.nix
    ./hardware.nix
    ./network.nix
    ./high-availability.nix
    ./secrets.nix
    ./firewall.nix
    ./spamhaus.nix
    ./dhcp.nix
    ./services.nix
    ./looking-glass.nix
    ./apps.nix
    ./qos.nix
  ];
  networking.hostName = "gateway";
  networking.domain = "cbannister.casa";
  system.stateVersion = "26.05";
  # Updates are deliberate maintenance operations on the only router.
  system.autoUpgrade.enable = false;
}
