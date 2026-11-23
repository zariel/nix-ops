# Offline installer for the gateway. The gateway is the network's only WAN
# path, so when it is down nothing can fetch from a binary cache: the ISO carries
# the complete gateway system closure and installs it without network access.
{
  lib,
  pkgs,
  gatewaySystem,
  ...
}:
{
  isoImage.storeContents = [ gatewaySystem ];
  # Larger and faster to build than the default xz; an installer is rebuilt
  # often and written to USB rather than downloaded.
  isoImage.squashfsCompression = "zstd -Xcompression-level 6";

  # Same consoles as the installed gateway: PiKVM on tty0, the Avocent on COM1.
  boot.kernelParams = [
    "console=ttyS0,115200"
    "console=tty0"
  ];

  users.users.root.openssh.authorizedKeys.keys = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINiFPVXT03FdYS3BKuqNmgplaGrzNc6i++77vCI2AJ8c id_ed25519"
  ];

  environment.etc."gateway-system".text = "${gatewaySystem}\n";

  # Mount the new root at /mnt (and its ESP at /mnt/boot) first; see
  # docs/gateway.md "Installation and state transfer".
  environment.systemPackages = [
    (pkgs.writeShellApplication {
      name = "install-gateway";
      text = ''
        system=$(cat /etc/gateway-system)
        mountpoint -q /mnt || { echo "mount the new root at /mnt first" >&2; exit 1; }
        mountpoint -q /mnt/boot || { echo "mount the ESP at /mnt/boot first" >&2; exit 1; }
        exec nixos-install --system "$system" --no-root-passwd --no-channel-copy "$@"
      '';
    })
  ];

  networking.hostName = lib.mkForce "gateway-installer";
}
