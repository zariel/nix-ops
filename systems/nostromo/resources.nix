{ lib, ... }:
{
  systemd.slices = {
    storage.sliceConfig = {
      CPUAccounting = true;
      MemoryAccounting = true;
      IOAccounting = true;
      CPUWeight = 200;
    };
    background.sliceConfig = {
      CPUAccounting = true;
      MemoryAccounting = true;
      IOAccounting = true;
      CPUWeight = 25;
      IOWeight = 25;
    };
    # The future kubelet/runtime must use the systemd cgroup driver and this root.
    kubepods.sliceConfig = {
      CPUAccounting = true;
      MemoryAccounting = true;
      IOAccounting = true;
      CPUWeight = 100;
    };
  };

  systemd.services = lib.genAttrs [ "nfs-server" "nfs-mountd" "samba-smbd" ] (_: {
    serviceConfig.Slice = lib.mkForce "storage.slice";
  });

  # ARC is shared kernel memory; it is not bounded by storage.slice.
  boot.extraModprobeConfig = ''
    options zfs zfs_arc_max=68719476736
  '';
}
