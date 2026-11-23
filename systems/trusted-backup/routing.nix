{ pkgs, ... }:
let
  network = import ../../lib/network.nix;
in
{
  boot.kernel.sysctl = {
    "net.ipv4.ip_forward" = 1;
    "net.ipv4.conf.all.send_redirects" = 0;
    "net.ipv4.conf.default.send_redirects" = 0;
  };

  systemd.network = {
    enable = true;
    links = {
      # Proxmox net0: vmbr1, tag 20; the guest receives untagged traffic.
      "10-trusted" = {
        matchConfig.MACAddress = "bc:24:11:02:06:20";
        linkConfig.Name = "trusted";
      };
      # Proxmox net1: vmbr1, tag 3005; the guest receives untagged traffic.
      "10-transit" = {
        matchConfig.MACAddress = "bc:24:11:02:06:05";
        linkConfig.Name = "transit";
      };
      # Proxmox net2: vmbr1, tag 10, MTU 9000; the guest receives untagged traffic.
      "10-servers" = {
        matchConfig.MACAddress = "bc:24:11:02:06:10";
        linkConfig.Name = "servers";
      };
    };
    networks = {
      "10-loopback" = {
        matchConfig.Name = "lo";
        # NetBox network-device loopback pool; independent of VRRP ownership.
        address = [ "10.254.254.2/32" ];
        # Routed identities follow BIRD's selected path so standby replies do
        # not bypass the active gateway's connection tracking. Other traffic
        # uses the on-link routes in main before consulting learned routes.
        routingPolicyRules = [
          {
            From = "10.254.254.2/32";
            Table = 100;
            Priority = 100;
          }
          {
            From = "10.254.0.8/32";
            Table = 100;
            Priority = 101;
          }
          {
            Table = 254;
            Priority = 200;
          }
          {
            Table = 100;
            Priority = 300;
          }
        ];
      };
      "10-trusted" = {
        matchConfig.Name = "trusted";
        address = [ "10.1.2.6/32" ];
        linkConfig = {
          MTUBytes = "1500";
          RequiredForOnline = false;
        };
        networkConfig = {
          DHCP = "no";
          IPv6AcceptRA = false;
          LinkLocalAddressing = "no";
          # Keep networkd from removing keepalived's gateway address on reload.
          KeepConfiguration = "static";
        };
        # Standby needs on-link ARP/replies, without originating the subnet.
        routes = [
          {
            Destination = "10.1.2.0/24";
            Scope = "link";
            PreferredSource = "10.1.2.6";
            Metric = 100;
          }
        ];
      };
      "10-servers" = {
        matchConfig.Name = "servers";
        address = [ "10.1.1.6/32" ];
        linkConfig = {
          MTUBytes = "9000";
          RequiredForOnline = false;
        };
        networkConfig = {
          DHCP = "no";
          IPv6AcceptRA = false;
          LinkLocalAddressing = "no";
          # Keep networkd from removing keepalived's gateway address on reload.
          KeepConfiguration = "static";
        };
        # As for trusted: on-link replies while standing by, never originated.
        routes = [
          {
            Destination = "10.1.1.0/24";
            Scope = "link";
            PreferredSource = "10.1.1.6";
            Metric = 100;
          }
        ];
      };
      "10-transit" = {
        # Carry VLAN 3005 over pve enp66s0f0np0 to beefchunk 1/2/6.
        # Beefchunk VE 3005 owns the peer address 10.254.0.9/31.
        matchConfig.Name = "transit";
        address = [ "10.254.0.8/31" ];
        linkConfig.MTUBytes = "1500";
        networkConfig = {
          DHCP = "no";
          IPv6AcceptRA = false;
          LinkLocalAddressing = "no";
        };
      };
    };
  };

  services.keepalived = {
    enable = true;
    # Before first startup, verify VyOS is MASTER and its advertisements reach
    # trusted through vmbr1. Both peers start BACKUP. This VM never preempts; the
    # primary reclaims the VIP 180 seconds after its keepalived starts, since this
    # VM has no WAN.
    vrrpInstances.TRUSTED = {
      interface = "trusted";
      state = "BACKUP";
      virtualRouterId = 20;
      priority = 100;
      # Manual handback, if the primary does not preempt: stop this service,
      # verify the primary owns the VIP, then start this service again. While
      # this VM holds the VIP, reach VyOS by SSH only at 10.1.2.5.
      noPreempt = true;
      unicastSrcIp = "10.1.2.6";
      unicastPeers = [ "10.1.2.5" ];
      virtualIps = [
        {
          addr = "10.1.2.1/24";
          dev = "trusted";
        }
      ];
      # Carrier tracking does not probe BGP or downstream service health.
      trackInterfaces = [ "transit" ];
      extraConfig = ''
        version 2
        advert_int 1
        check_unicast_src
        unicast_fault_no_peer
      '';
    };
    vrrpInstances.SERVERS = {
      interface = "servers";
      state = "BACKUP";
      virtualRouterId = 10;
      priority = 100;
      noPreempt = true;
      unicastSrcIp = "10.1.1.6";
      unicastPeers = [ "10.1.1.5" ];
      virtualIps = [
        {
          addr = "10.1.1.1/24";
          dev = "servers";
        }
      ];
      trackInterfaces = [ "transit" ];
      extraConfig = ''
        version 2
        advert_int 1
        check_unicast_src
        unicast_fault_no_peer
      '';
    };
    # Both gateways belong to one router at a time, matching VyOS's sync group:
    # split ownership would route trusted-servers traffic asymmetrically through
    # two stateful firewalls.
    extraConfig = ''
      vrrp_sync_group GATEWAY {
        group {
          TRUSTED
          SERVERS
        }
      }
    '';
  };

  services.bird = {
    enable = true;
    package = pkgs.bird2;
    # Beefchunk's TRUSTED-BACKUP inbound list permits only the identity /32
    # and the trusted and servers /24s; those must come from VRRP's connected
    # addresses.
    config = ''
      router id 10.254.254.2;

      protocol device {}

      protocol direct identity {
        interface "lo";
        ipv4 { import where net = 10.254.254.2/32; };
      }

      protocol direct transit_connected {
        interface "transit";
        ipv4;
      }

      # Only the VRRP address creates this connected prefix. The permanent
      # /32 and networkd's standby static route cannot pass this filter.
      protocol direct trusted_connected {
        interface "trusted";
        check link yes;
        ipv4 { import where net = 10.1.2.0/24; };
      }

      protocol direct servers_connected {
        interface "servers";
        check link yes;
        ipv4 { import where net = 10.1.1.0/24; };
      }

      protocol kernel {
        kernel table 100;
        ipv4 {
          import none;
          export all;
        };
      }

      protocol bgp core {
        local 10.254.0.8 as 65120;
        neighbor 10.254.0.9 as 65001;
        check link yes;
        ipv4 {
          import all;
          export where source = RTS_DEVICE && net ~ [10.1.2.0/24, 10.1.1.0/24, 10.254.254.2/32];
        };
      }
    '';
  };

  # Proxmox NIC firewalls are disabled; guest nftables owns filtering.
  networking.firewall.enable = false;
  networking.nftables = {
    enable = true;
    tables.router = {
      family = "inet";
      content = ''
        chain input {
          type filter hook input priority filter; policy drop;
          iifname "lo" accept
          ct state established,related accept
          ip protocol icmp accept
          iifname "trusted" ip saddr 10.1.2.5 ip daddr 10.1.2.6 ip protocol 112 accept
          iifname "servers" ip saddr 10.1.1.5 ip daddr 10.1.1.6 ip protocol 112 accept
          iifname "transit" ip saddr 10.254.0.9 tcp dport 179 accept
          ip saddr { 10.0.0.0/8, 172.20.0.0/16 } tcp dport 22 accept
          ip saddr 172.20.0.0/16 tcp dport 9100 accept
        }
        chain forward {
          type filter hook forward priority filter; policy drop;
          ct state invalid drop
          ct state established,related accept
          # Maintenance access to the internal fabric, without WAN or NAT.
          iifname "trusted" oifname "transit" ip saddr 10.1.2.0/24 ip daddr { 10.0.0.0/8, 172.20.0.0/16, 172.21.0.0/16 } accept
          iifname "trusted" oifname "transit" ip saddr 10.1.2.0/24 ip daddr { ${network.dnsVip}, ${network.legacyDnsVip} } tcp dport 53 accept
          iifname "trusted" oifname "transit" ip saddr 10.1.2.0/24 ip daddr { ${network.dnsVip}, ${network.legacyDnsVip} } udp dport 53 accept
          iifname "trusted" oifname "transit" ip saddr 10.1.2.0/24 ip daddr { ${network.dnsVip}, ${network.legacyDnsVip} } ip protocol icmp accept
          # While this VM owns the servers gateway, mirror VyOS's servers policies:
          # trusted-servers accepts everything, servers-transit admits DNS, NFS and
          # the Kubernetes load balancers, and transit-servers admits ping, the Nix
          # cache and the Proxmox UIs. Servers reach trusted only by reply.
          iifname "trusted" oifname "servers" ip saddr 10.1.2.0/24 accept
          iifname "servers" oifname "transit" ip saddr 10.1.1.0/24 ip protocol icmp accept
          iifname "servers" oifname "transit" ip saddr 10.1.1.0/24 ip daddr { ${network.dnsVip}, ${network.legacyDnsVip} } meta l4proto { tcp, udp } th dport 53 accept
          iifname "servers" oifname "transit" ip saddr { 10.1.1.31, 10.1.1.41 } ip daddr 10.254.1.101 meta l4proto { tcp, udp } th dport { 111, 2049 } accept
          iifname "servers" oifname "transit" ip saddr 10.1.1.0/24 ip daddr 10.45.0.0/24 accept
          iifname "transit" oifname "servers" ip daddr 10.1.1.0/24 ip protocol icmp accept
          iifname "transit" oifname "servers" ip daddr 10.1.1.155 tcp dport 5000 accept
          iifname "transit" oifname "servers" ip daddr { 10.1.1.31, 10.1.1.32, 10.1.1.41 } tcp dport { 8006, 8007 } accept
        }
      '';
    };
  };
}
