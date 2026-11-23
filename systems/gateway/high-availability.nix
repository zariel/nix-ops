{ ... }:
let
  ready = map (interface: "systemd-networkd-wait-online@${interface}.service") [
    "bond0.10"
    "bond0.20"
    "bond0.3001"
  ];

  instance =
    {
      interface,
      id,
      node,
      peer,
      vip,
    }:
    {
      inherit interface;
      state = "BACKUP";
      virtualRouterId = id;
      priority = 200;
      unicastSrcIp = node;
      unicastPeers = [ peer ];
      virtualIps = [
        {
          addr = vip;
          dev = interface;
        }
      ];
      trackInterfaces = [ "bond0.3001" ];
      extraConfig = ''
        version 2
        advert_int 1
        # The backup has no WAN, so a recovered primary reclaims the VIP once
        # networkd, nftables and BGP have had time to come up.
        preempt_delay 180
        check_unicast_src
        unicast_fault_no_peer
      '';
    };
in
{
  services.keepalived = {
    enable = true;
    vrrpInstances = {
      TRUSTED = instance {
        interface = "bond0.20";
        id = 20;
        node = "10.1.2.5";
        peer = "10.1.2.6";
        vip = "10.1.2.1/24";
      };
      SERVERS = instance {
        interface = "bond0.10";
        id = 10;
        node = "10.1.1.5";
        peer = "10.1.1.6";
        vip = "10.1.1.1/24";
      };
    };
    # Asymmetric paths would break conntrack if the VIPs were owned by
    # different gateways, so the gateway VIPs fail over together.
    extraConfig = ''
      vrrp_sync_group GATEWAY {
        group {
          TRUSTED
          SERVERS
        }
      }
    '';
  };

  systemd.services.keepalived = {
    requires = ready;
    after = ready;
  };
}
