{ lib, ... }:
{
  imports = [
    ./disk-config.nix
    ./nas.nix
    ./networking.nix
    ./resources.nix
    ./storage.nix
  ];

  boot.initrd.systemd.enable = true;

  boot.loader.efi.canTouchEfiVariables = lib.mkForce false;
  boot.loader.grub = {
    enable = true;
    efiInstallAsRemovable = true;
    efiSupport = true;
    mirroredBoots = [
      {
        devices = [ "nodev" ];
        path = "/boot";
      }
      {
        devices = [ "nodev" ];
        path = "/boot-fallback";
      }
    ];
  };
  boot.loader.systemd-boot.enable = lib.mkForce false;

  networking.hostName = "nostromo";

  system.stateVersion = "26.05";
}
