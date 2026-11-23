{ ... }:
let
  ready = map (interface: "systemd-networkd-wait-online@${interface}.service") [
    "bond0.20"
    "bond0.3001"
  ];
in
{
  services.keepalived = {
    enable = true;
    vrrpInstances.TRUSTED = {
      interface = "bond0.20";
      state = "BACKUP";
      virtualRouterId = 20;
      priority = 200;
      unicastSrcIp = "10.1.2.5";
      unicastPeers = [ "10.1.2.6" ];
      virtualIps = [
        {
          addr = "10.1.2.1/24";
          dev = "bond0.20";
        }
      ];
      trackInterfaces = [ "bond0.3001" ];
      extraConfig = ''
        version 2
        advert_int 1
        # trusted-backup has no WAN, so a recovered primary reclaims the VIP once
        # networkd, nftables and BGP have had time to come up.
        preempt_delay 180
        check_unicast_src
        unicast_fault_no_peer
      '';
    };
  };

  systemd.services.keepalived = {
    requires = ready;
    after = ready;
  };
}
