{
  config,
  lib,
  pkgs,
  modulesPath,
  ...
}:
let
  network = import ../../lib/network.nix;
in
{
  # pve VM 108: maintenance access to the IPv4 fabric, without DHCP or NAT.
  # LANs whose only gateway is VyOS still depend on it; IPv6 has no failover.
  imports = [
    (modulesPath + "/profiles/qemu-guest.nix")
    ./routing.nix
  ];

  networking.hostName = "trusted-backup";
  networking.useDHCP = false;
  networking.nameservers = [ network.dnsVip ];
  services.resolved.enable = true;
  services.qemuGuest.enable = true;

  boot.initrd.availableKernelModules = [ "virtio_scsi" ];
  boot.kernelParams = [ "console=ttyS0,115200" ];
  # The image must boot without installer-created EFI firmware variables.
  boot.loader.efi.canTouchEfiVariables = lib.mkForce false;
  fileSystems."/" = {
    device = "/dev/disk/by-label/nixos";
    fsType = "ext4";
    autoResize = true;
  };
  fileSystems."/boot" = {
    device = "/dev/disk/by-label/ESP";
    fsType = "vfat";
    options = [ "umask=0077" ];
  };

  # Build .#nixosConfigurations.trusted-backup.config.system.build.vmImage,
  # then import nixos.qcow2 into a new OVMF VM with Secure Boot disabled.
  # Update the existing VM through deploy-rs node trusted-backup.
  system.build.vmImage = import (modulesPath + "/../lib/make-disk-image.nix") {
    inherit config lib pkgs;
    name = "trusted-backup";
    format = "qcow2";
    diskSize = 8192;
    partitionTableType = "efi";
    bootSize = "256M";
  };

  environment.systemPackages = with pkgs; [
    tcpdump
    dnsutils
  ];
}
