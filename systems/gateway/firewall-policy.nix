{ lib }:
let
  inherit (import ./firewall-helpers.nix)
    addressSet
    portSet
    setRef
    tcp
    udp
    tcpUdp
    icmpv6
    ;
  zones = {
    wan = [ "wan0" ];
    lan = [ "bond0.100" ];
    servers = [ "bond0.10" ];
    trusted = [
      "bond0.20"
      "wg01"
    ];
    guest = [ "bond0.30" ];
    iot = [ "bond0.40" ];
    containers = [ "ve-*" ];
    transit = [ "bond0.3001" ];
  };
  internal = lib.filter (zone: zone != "wan") (builtins.attrNames zones) ++ [ "local" ];
  accept = {
    verdict = "accept";
  };
  dhcp = udp {
    dport = [
      67
      68
    ];
    sport = [
      67
      68
    ];
    comment = "DHCP";
  };
  ssh = tcp {
    dport = 22;
    comment = "SSH";
  };
  tftp = udp {
    dport = 69;
    comment = "TFTP";
  };
  dns = tcpUdp {
    dport = [
      53
      853
    ];
    comment = "DNS";
  };
  dns4 = tcpUdp {
    daddr = "172.53.53.53";
    dport = 53;
    comment = "DNS";
  };
  ntp4 = udp {
    daddr = "10.254.254.1";
    dport = 123;
    comment = "NTP";
  };
  icmp4 = {
    l4proto = "icmp";
    comment = "ICMP";
  };
  icmp6 = icmpv6 {
    comment = "ICMPv6";
  };
  icmp6Errors =
    map
      (
        icmpv6Type:
        icmpv6 {
          inherit icmpv6Type;
          comment = "ICMPv6";
        }
      )
      [
        "destination-unreachable"
        "packet-too-big"
        "time-exceeded"
        "parameter-problem"
      ];
in
{
  inherit zones;
  addressSets = {
    k8s_nodes = addressSet [
      "10.254.1.1"
      "10.254.1.3"
      "10.254.1.5"
    ];
    storage = addressSet [ "10.254.1.101" ];
    airplay_sources = addressSet [
      "10.1.2.11"
      "10.1.2.14"
    ];
    airplay_targets = addressSet [ "10.1.3.14" ];
    k8s_ingress = addressSet [ "10.45.0.10" ];
    k8s_ingress_clients = addressSet [ "10.1.3.16" ];
    k8s_jellyfin = addressSet [ "10.45.0.21" ];
    k8s_plex = addressSet [ "10.45.0.20" ];
    nfs_clients = addressSet [
      "10.1.1.31"
      "10.1.1.41"
    ];
    metrics_targets = addressSet [
      "10.1.2.54"
      "10.1.2.15"
      "10.1.1.31"
      "10.1.1.41"
      "10.1.0.1"
      "10.1.1.155"
      "10.1.2.16"
      "10.1.1.32"
      "10.1.0.100"
      "10.1.2.57"
    ];
    plex_clients = addressSet [ "10.1.3.16" ];
    snmp_targets = addressSet [
      "10.1.0.10"
      "10.1.0.31"
    ];
    dns_servers = addressSet [ "10.254.53.0/24" ];
    routed_servers = addressSet [ "10.254.0.0/16" ];
    load_balancers = addressSet [ "10.45.0.0/24" ];
    transit_pods = addressSet [ "172.20.0.0/16" ];
    k8s_pods = addressSet [
      "10.42.0.0/16"
      "172.20.0.0/16"
    ];
  };
  portSets = {
    node_management = portSet [
      22
      8080
      9443
    ];
    airplay_ports = portSet [
      3722
      6002
      7000
      {
        from = 30000;
        to = 65535;
      }
    ];
    ingress_ports = portSet [ 443 ];
    nfs_ports = portSet [
      2049
      111
    ];
    roon_arc_ports = portSet [ 59453 ];
  };

  # Omitted zone pairs are denied. Rules within a pair are evaluated in order.
  ipv4 = {
    containers.to.local = [
      dns
      dhcp
      (udp {
        dport = 123;
        comment = "NTP";
      })
    ];
    containers.to.servers = [ accept ];
    containers.to.transit = [
      dns4
      (tcp {
        daddr = setRef "k8s_nodes";
        dport = [
          6443
          50000
        ];
        comment = "Node management";
      })
      (tcpUdp {
        daddr = "10.45.0.55";
        dport = 53;
        comment = "DNS";
      })
    ];
    containers.to.wan = [ accept ];
    guest.to.containers = [
      dns
    ];
    guest.to.local = [ dhcp ];
    guest.to.transit = [ dns4 ];
    guest.to.wan = [ accept ];
    iot.to.containers = [ accept ];
    iot.to.local = [
      dhcp
      ntp4
      {
        l4proto = "igmp";
        comment = "Multicast membership";
      }
      (udp {
        daddr = "224.0.0.251";
        dport = 5353;
        comment = "mDNS";
      })
    ];
    iot.to.servers = [
      (tcp {
        daddr = setRef "k8s_plex";
        dport = 32400;
        saddr = setRef "plex_clients";
        comment = "Plex";
      })
      (tcpUdp {
        daddr = setRef "k8s_jellyfin";
        saddr = setRef "plex_clients";
        comment = "Jellyfin";
      })
      (tcp {
        daddr = setRef "k8s_ingress";
        dport = setRef "ingress_ports";
        saddr = setRef "k8s_ingress_clients";
        comment = "HTTPS ingress";
      })
    ];
    iot.to.transit = [
      dns4
      (tcp {
        daddr = setRef "k8s_plex";
        dport = 32400;
        saddr = setRef "plex_clients";
        comment = "Plex";
      })
    ];
    iot.to.trusted = [
      (tcpUdp {
        daddr = setRef "airplay_sources";
        dport = setRef "airplay_ports";
        saddr = setRef "airplay_targets";
        comment = "AirPlay";
      })
    ];
    iot.to.wan = [ accept ];
    lan.to.containers = [ accept ];
    lan.to.local = [
      dhcp
      ntp4
      tftp
      (tcp {
        dport = 9100;
        saddr = setRef "k8s_pods";
        comment = "Host metrics";
      })
      ssh
    ];
    lan.to.servers = [
      (tcpUdp {
        dport = [
          161
          162
        ];
        comment = "SNMP";
      })
      (tcpUdp {
        daddr = "10.1.1.51";
        dport = 5000;
        saddr = "10.1.0.100";
        comment = "Port 5000 service";
      })
    ];
    lan.to.transit = [ dns4 ];
    lan.to.trusted = [
      (udp {
        daddr = "10.1.2.14";
        dport = 6343;
        comment = "sFlow";
      })
    ];
    lan.to.wan = [ accept ];
    local.to.containers = [ accept ];
    local.to.iot = [
      {
        l4proto = "igmp";
        comment = "Multicast membership";
      }
      (udp {
        dport = 5353;
        sport = 5353;
        comment = "mDNS";
      })
    ];
    local.to.servers = [
      dns
      (tcp {
        dport = 179;
        comment = "BGP";
      })
      (udp {
        comment = "Server UDP services";
      })
      (tcp {
        daddr = "10.45.0.2";
        dport = 6001;
        comment = "Kernel log collector";
      })
      (tcp {
        daddr = setRef "k8s_nodes";
        dport = 6443;
        comment = "Kubernetes API";
      })
    ];
    local.to.transit = [
      {
        l4proto = 89;
        comment = "Routing protocol 89";
      }
      (tcp {
        daddr = "10.254.0.1";
        dport = 179;
        saddr = "10.254.0.0";
        comment = "BGP";
      })
      icmp4
    ];
    local.to.trusted = [
      icmp4
      {
        l4proto = "igmp";
        comment = "Multicast membership";
      }
      (udp {
        dport = 5353;
        sport = 5353;
        comment = "mDNS";
      })
      (udp {
        sport = 51820;
        comment = "WireGuard";
      })
    ];
    local.to.wan = [ accept ];
    servers.to.containers = [ accept ];
    servers.to.lan = [
      (udp {
        dport = 161;
        comment = "SNMP";
      })
    ];
    servers.to.local = [
      dhcp
      ntp4
      (tcp {
        dport = 179;
        comment = "BGP";
      })
      tftp
      (tcp {
        dport = 9100;
        saddr = setRef "k8s_pods";
        comment = "Host metrics";
      })
      (tcp {
        dport = 9100;
        saddr = setRef "k8s_nodes";
        comment = "Host metrics";
      })
    ];
    servers.to.transit = [
      dns4
      (tcpUdp {
        daddr = setRef "storage";
        dport = setRef "nfs_ports";
        saddr = setRef "nfs_clients";
        comment = "NFS";
      })
      (tcpUdp {
        daddr = setRef "load_balancers";
        comment = "Load balancer services";
      })
    ];
    servers.to.trusted = [
      (tcp {
        daddr = "10.1.2.54";
        dport = 9100;
        saddr = setRef "k8s_pods";
        comment = "Host metrics";
      })
      (tcp {
        daddr = setRef "metrics_targets";
        dport = 9100;
        saddr = setRef "k8s_nodes";
        comment = "Host metrics";
      })
    ];
    servers.to.wan = [ accept ];
    transit.to.containers = [
      (tcpUdp {
        daddr = "10.5.0.4";
        dport = 53;
        comment = "DNS";
      })
      (tcp {
        daddr = "10.5.0.2";
        dport = [
          6443
          50000
        ];
        saddr = setRef "transit_pods";
        comment = "Node management";
      })
      (tcp {
        daddr = "10.5.0.4";
        dport = 8083;
        saddr = setRef "transit_pods";
        comment = "Application port 8083";
      })
      (tcp {
        daddr = "10.5.0.7";
        dport = 4000;
        saddr = setRef "transit_pods";
        comment = "Application port 4000";
      })
    ];
    transit.to.iot = [ icmp4 ];
    transit.to.lan = [
      icmp4
      (udp {
        daddr = setRef "snmp_targets";
        dport = [
          161
          162
        ];
        saddr = setRef "transit_pods";
        comment = "SNMP";
      })
      (tcp {
        daddr = setRef "metrics_targets";
        dport = 9100;
        saddr = setRef "transit_pods";
        comment = "Host metrics";
      })
    ];
    transit.to.local = [
      {
        l4proto = 89;
        comment = "Routing protocol 89";
      }
      (tcp {
        daddr = "10.254.0.0";
        dport = 179;
        saddr = "10.254.0.1";
        comment = "BGP";
      })
      icmp4
      ntp4
      (tcp {
        daddr = setRef "metrics_targets";
        dport = 9100;
        saddr = setRef "transit_pods";
        comment = "Host metrics";
      })
      (udp {
        daddr = "10.254.254.1";
        dport = 69;
        saddr = "10.254.0.0/24";
        comment = "TFTP";
      })
    ];
    transit.to.servers = [
      icmp4
      (tcp {
        daddr = setRef "metrics_targets";
        dport = [
          9100
          9633
          9290
        ];
        saddr = setRef "transit_pods";
        comment = "Host metrics";
      })
      (tcp {
        daddr = "10.1.1.155";
        dport = 5000;
        comment = "Port 5000 service";
      })
      (tcp {
        daddr = "10.1.1.55";
        dport = 11434;
        saddr = setRef "transit_pods";
        comment = "Model API";
      })
    ];
    transit.to.trusted = [
      icmp4
      (tcp {
        daddr = setRef "metrics_targets";
        dport = [
          9100
          9633
        ];
        saddr = setRef "transit_pods";
        comment = "Host metrics";
      })
    ];
    transit.to.wan = [
      {
        daddr = setRef "geoip_cn_ru";
        verdict = "drop";
        comment = "GeoIP block";
      }
      {
        saddr = setRef "k8s_nodes";
        comment = "Cluster nodes";
      }
      (tcp {
        dport = [
          80
          443
        ];
        saddr = setRef "storage";
        comment = "Storage web access";
      })
      {
        saddr = setRef "transit_pods";
        comment = "Routed pods";
      }
      {
        saddr = setRef "dns_servers";
        comment = "DNS servers";
      }
    ];
    trusted.to.containers = [ accept ];
    trusted.to.iot = [ accept ];
    trusted.to.lan = [ accept ];
    trusted.to.local = [
      dhcp
      ntp4
      tftp
      icmp4
      {
        l4proto = "igmp";
        comment = "Multicast membership";
      }
      (udp {
        daddr = "224.0.0.251";
        dport = 5353;
        comment = "mDNS";
      })
      (udp {
        daddr = "255.255.255.255";
        dport = 9;
        comment = "Wake on LAN";
      })
      ssh
      (tcp {
        dport = 8443;
        comment = "Management HTTPS";
      })
      (udp {
        dport = 51820;
        comment = "WireGuard";
      })
      (tcp {
        dport = 5201;
        comment = "Throughput testing";
      })
    ];
    trusted.to.servers = [ accept ];
    trusted.to.transit = [
      icmp4
      dns4
      {
        daddr = setRef "routed_servers";
        comment = "Routed servers";
      }
      {
        daddr = setRef "load_balancers";
        comment = "Load balancer services";
      }
      {
        daddr = setRef "dns_servers";
        comment = "DNS servers";
      }
      (tcp {
        daddr = setRef "k8s_nodes";
        dport = setRef "node_management";
        comment = "Node management";
      })
    ];
    trusted.to.wan = [ accept ];
    wan.to.local = [
      (udp {
        dport = 51820;
        comment = "WireGuard";
      })
    ];
    wan.to.servers = [
      (tcpUdp {
        daddr = "10.45.0.24";
        dport = 50413;
        comment = "Torrent forwarding";
      })
    ];
    wan.to.transit = [
      {
        saddr = setRef "geoip_cn_ru";
        verdict = "drop";
        comment = "GeoIP block";
      }
      (tcp {
        daddr = "10.45.0.24";
        dport = 50413;
        comment = "Torrent forwarding";
      })
    ];
    wan.to.trusted = [
      (tcp {
        daddr = "10.1.2.60";
        dport = setRef "roon_arc_ports";
        comment = "Roon ARC";
      })
    ];
  };

  # Internal IPv6 zone pairs permit ICMPv6. WAN ingress permits only the
  # error types below, with neighbor discovery additionally allowed to local.
  ipv6 =
    lib.recursiveUpdate
      (lib.genAttrs internal (source: {
        to = lib.genAttrs (lib.remove source internal) (_: [ icmp6 ]);
      }))
      {
        iot.to.containers = [ accept ];
        iot.to.local = [
          icmp6
          (udp {
            dport = 5353;
            sport = 5353;
            comment = "mDNS";
          })
        ];
        iot.to.transit = [
          icmp6
          (tcpUdp {
            daddr = "fd74:f571:d3bd:53::53";
            dport = [
              53
              853
            ];
            comment = "DNS";
          })
        ];
        iot.to.wan = [ accept ];
        local.to.iot = [
          icmp6
          (udp {
            dport = 5353;
            sport = 5353;
            comment = "mDNS";
          })
        ];
        local.to.transit = [
          {
            l4proto = 89;
            comment = "Routing protocol 89";
          }
          icmp6
        ];
        local.to.trusted = [
          icmp6
          (udp {
            dport = 546;
            sport = 547;
            comment = "DHCPv6 client";
          })
          (udp {
            dport = 5353;
            comment = "mDNS";
          })
        ];
        local.to.wan = [ accept ];
        transit.to.local = [ accept ];
        trusted.to.containers = [ accept ];
        trusted.to.iot = [
          icmp6
          {
            daddr = "fd42:dfb5:24e4:1::/64";
            comment = "Thread prefix";
          }
        ];
        trusted.to.local = [
          icmp6
          (udp {
            dport = 5353;
            sport = 5353;
            comment = "mDNS";
          })
          ssh
        ];
        trusted.to.transit = [
          icmp6
          (tcpUdp {
            daddr = "fd74:f571:d3bd:53::53";
            dport = [
              53
              853
            ];
            comment = "DNS";
          })
        ];
        trusted.to.wan = [ accept ];
        wan.to = lib.genAttrs internal (
          destination:
          icmp6Errors
          ++ (
            {
              local = [
                (icmpv6 {
                  icmpv6Type = "nd-router-advert";
                  comment = "ICMPv6";
                })
                (icmpv6 {
                  icmpv6Type = "nd-router-solicit";
                  comment = "ICMPv6";
                })
                (icmpv6 {
                  icmpv6Type = "nd-neighbor-solicit";
                  comment = "ICMPv6";
                })
                (icmpv6 {
                  icmpv6Type = "nd-neighbor-advert";
                  comment = "ICMPv6";
                })
                (udp {
                  dport = 546;
                  sport = 547;
                  comment = "DHCPv6 client";
                })
              ];
              iot = [
                (tcpUdp {
                  daddr = {
                    mask = "::ffff:ffff:ffff:ffff";
                    value = "::5679:68e4:9fe0:46e4";
                  };
                  dport = 3074;
                  comment = "Game console";
                })
                (udp {
                  daddr = {
                    mask = "::ffff:ffff:ffff:ffff";
                    value = "::5679:68e4:9fe0:46e4";
                  };
                  dport = [
                    88
                    500
                    3544
                    4500
                  ];
                  comment = "Game console";
                })
              ];
              trusted = [
                (tcp {
                  daddr = {
                    mask = "::ffff:ffff:ffff:ffff";
                    value = "::7c7d:c6ff:fec7:26ac";
                  };
                  dport = setRef "roon_arc_ports";
                  comment = "Roon ARC";
                })
              ];
            }
            .${destination} or [ ]
          )
        );
      };
}
