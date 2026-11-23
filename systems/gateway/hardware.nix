{ lib, ... }:
{
  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";
  boot.initrd.availableKernelModules = [
    "ahci"
    "xhci_pci"
    "ehci_pci"
    "usb_storage"
    "sd_mod"
  ];
  boot.kernelModules = [
    "bonding"
    "8021q"
    "wireguard"
    "ifb"
    "sch_cake"
  ];
  # COM1 is the break-glass console on the OOB Avocent's port 2. The kernel and
  # a serial getty use it at 115200; tty0 stays last so PiKVM shows systemd's
  # boot status and a getty too.
  boot.kernelParams = [
    "console=ttyS0,115200"
    "console=tty0"
  ];
  # Log out idle shells after 15 minutes, so a console login left open on the
  # PiKVM or the Avocent does not stay logged in. Like VyOS's system login
  # timeout, this applies to every interactive bash, SSH included.
  programs.bash.interactiveShellInit = ''
    TMOUT=900
    readonly TMOUT
    export TMOUT
  '';
  # Installation contract: create these labels on the NEW NixOS disk.
  # These deliberately do not point at VyOS's persistence partition.
  fileSystems."/" = {
    device = "/dev/disk/by-label/nixos";
    fsType = "ext4";
  };
  fileSystems."/boot" = {
    device = "/dev/disk/by-label/ESP";
    fsType = "vfat";
    options = [ "umask=0077" ];
  };
}
