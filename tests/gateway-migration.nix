{ pkgs }:
pkgs.testers.runNixOSTest {
  name = "gateway-migration";
  globalTimeout = 480;
  nodes = {
    primary = { lib, ... }: {
      imports = [
        ../systems/gateway/network.nix
        ../systems/gateway/high-availability.nix
        ../systems/gateway/services.nix
        ../systems/gateway/hardening.nix
        ../systems/gateway/firewall.nix
      ];
      services.prometheus.exporters.node.enable = true;
      virtualisation.vlans = [ 1 ];
      virtualisation.memorySize = 1536;
      systemd.network.links."10-lan0".matchConfig = lib.mkForce { OriginalName = "eth1"; };
      # The fixture switch has no LACP peer; exercise the production VLANs on
      # one bond member while the existing gateway test covers 802.3ad.
      systemd.network.netdevs."20-bond0".bondConfig = lib.mkForce {
        Mode = "active-backup";
        MIIMonitorSec = "100ms";
      };
      systemd.network.netdevs."20-wg01".wireguardConfig.PrivateKeyFile = "/var/lib/gateway/wireguard.key";
      systemd.services.systemd-networkd.after = [ "systemd-tmpfiles-setup.service" ];
      systemd.tmpfiles.rules = [
        "d /var/lib/gateway 0750 root systemd-network -"
        "f /var/lib/gateway/wireguard.key 0640 root systemd-network - AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQE="
      ];
      environment.systemPackages = [
        pkgs.curl
        pkgs.python3
        pkgs.iputils
      ];
    };
    backup = { lib, ... }: {
      virtualisation.vlans = [ 1 ];
      networking.useDHCP = false;
      networking.firewall.enable = false;
      boot.kernel.sysctl = {
        "net.ipv4.ip_forward" = 1;
        "net.ipv4.conf.all.send_redirects" = 0;
        "net.ipv4.conf.default.send_redirects" = 0;
      };
      systemd.network = {
        enable = true;
        wait-online.enable = false;
        netdevs = {
          "20-trusted" = {
            netdevConfig = {
              Name = "trusted";
              Kind = "vlan";
            };
            vlanConfig.Id = 20;
          };
          "20-transit" = {
            netdevConfig = {
              Name = "transit";
              Kind = "vlan";
            };
            vlanConfig.Id = 3005;
          };
        };
        networks = {
          "20-eth1" = {
            matchConfig.Name = "eth1";
            vlan = [
              "trusted"
              "transit"
            ];
          };
          "30-trusted" = {
            matchConfig.Name = "trusted";
            address = [ "10.1.2.6/32" ];
            networkConfig = {
              IPv6AcceptRA = false;
              KeepConfiguration = "static";
            };
            routes = [
              {
                Destination = "10.1.2.0/24";
                Scope = "link";
                Metric = 100;
                PreferredSource = "10.1.2.6";
              }
            ];
          };
          "30-transit" = {
            matchConfig.Name = "transit";
            address = [ "10.254.0.8/31" ];
            networkConfig.IPv6AcceptRA = false;
          };
        };
      };
      services.keepalived = {
        enable = true;
        vrrpInstances.TRUSTED = {
          interface = "trusted";
          state = "BACKUP";
          priority = 100;
          virtualRouterId = 20;
          noPreempt = true;
          unicastSrcIp = "10.1.2.6";
          unicastPeers = [ "10.1.2.5" ];
          virtualIps = [
            {
              addr = "10.1.2.1/24";
              dev = "trusted";
            }
          ];
          trackInterfaces = [ "transit" ];
          extraConfig = "version 2\nadvert_int 1\ncheck_unicast_src\nunicast_fault_no_peer";
        };
      };
      systemd.services.keepalived.wantedBy = lib.mkForce [ ];
      systemd.timers.keepalived-boot-delay.wantedBy = lib.mkForce [ ];
      services.frr = {
        bgpd.enable = true;
        config = ''
          frr defaults traditional
          router bgp 65120
           bgp router-id 10.254.0.8
           neighbor 10.254.0.9 remote-as 65001
           address-family ipv4 unicast
            redistribute connected route-map TRUSTED
            neighbor 10.254.0.9 route-map ALLOW in
            neighbor 10.254.0.9 route-map ALLOW out
           exit-address-family
          exit
          ip prefix-list TRUSTED seq 10 permit 10.1.2.0/24
          route-map TRUSTED permit 10
           match ip address prefix-list TRUSTED
           match interface trusted
          exit
          route-map ALLOW permit 10
          exit
        '';
      };
    };
    core = { ... }: {
      virtualisation.vlans = [ 1 ];
      networking.useDHCP = false;
      networking.firewall.enable = false;
      boot.kernel.sysctl."net.ipv4.ip_forward" = 1;
      systemd.network = {
        enable = true;
        wait-online.enable = false;
        netdevs = {
          "20-primary" = {
            netdevConfig = {
              Name = "primary";
              Kind = "vlan";
            };
            vlanConfig.Id = 3001;
          };
          "20-backup" = {
            netdevConfig = {
              Name = "backup";
              Kind = "vlan";
            };
            vlanConfig.Id = 3005;
          };
        };
        networks = {
          "20-eth1" = {
            matchConfig.Name = "eth1";
            vlan = [
              "primary"
              "backup"
            ];
          };
          "30-primary" = {
            matchConfig.Name = "primary";
            address = [ "10.254.0.1/31" ];
            networkConfig.IPv6AcceptRA = false;
          };
          "30-backup" = {
            matchConfig.Name = "backup";
            address = [ "10.254.0.9/31" ];
            networkConfig.IPv6AcceptRA = false;
          };
          "10-loopback" = {
            matchConfig.Name = "lo";
            address = [ "10.254.253.53/32" ];
          };
        };
      };
      services.frr = {
        bgpd.enable = true;
        config = ''
          frr defaults traditional
          router bgp 65001
           bgp router-id 10.254.0.1
           no bgp ebgp-requires-policy
           neighbor 10.254.0.0 remote-as 65000
           neighbor 10.254.0.8 remote-as 65120
           ! Bound detection time for a simulated subinterface failure.
           neighbor 10.254.0.0 timers 1 3
           neighbor 10.254.0.8 timers 1 3
           address-family ipv4 unicast
            network 10.254.253.53/32
           exit-address-family
          exit
        '';
      };
      systemd.services.http = {
        wantedBy = [ "multi-user.target" ];
        requires = [ "systemd-networkd-wait-online@lo.service" ];
        after = [ "systemd-networkd-wait-online@lo.service" ];
        serviceConfig.ExecStart = "${pkgs.python3}/bin/python3 -m http.server 53 --bind 10.254.253.53";
      };
    };
    client = { ... }: {
      virtualisation.vlans = [ 1 ];
      networking.useDHCP = false;
      networking.firewall.enable = false;
      environment.systemPackages = [
        pkgs.curl
        (pkgs.python3.withPackages (ps: [ ps.scapy ]))
        pkgs.iputils
      ];
      environment.etc."gateway-matter.py".source = ./gateway-matter.py;
    };
  };
  testScript = builtins.readFile ./gateway-migration.py;
}
