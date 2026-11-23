{ lib }:
let
  addresses = (import ../../roles/gateway-services/settings.nix).addresses;
  dhcpDns = import ../../roles/dhcp-dns/settings.nix { inherit lib; };
  network = import ../../lib/network.nix;
  rock = builtins.elemAt (import ./reservations.nix).roon.rock 1;
  bluesoundPlayers = map (reservation: builtins.elemAt reservation 1) (
    with (import ./reservations.nix).roon;
    [
      bluesound-node2i
      blusound-flex-mini-office
    ]
  );
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
    roon = [ "bond0.60" ];
    thread = [ "bond0.1100" ];
    matter = [ "bond0.1101" ];
    transit = [ "bond0.3001" ];
  };
  # ROON is IPv4-only, so all of its IPv6 pairs are denied.
  internalIpv6 =
    lib.filter (
      zone:
      !builtins.elem zone [
        "wan"
        "roon"
      ]
    ) (builtins.attrNames zones)
    ++ [ "local" ];
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
  blockDot = tcpUdp {
    dport = 853;
    verdict = "drop";
    comment = "Block encrypted DNS";
  };
  ssh = tcp {
    dport = 22;
    comment = "SSH";
  };
  tftp = udp {
    daddr = addresses.tftp;
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
    daddr = setRef "dns_vips";
    dport = 53;
    comment = "DNS";
  };
  ntp4 = udp {
    daddr = addresses.ntp;
    dport = 123;
    comment = "NTP";
  };
  # IPv4 pings follow zone trust: the gateway may ping every zone, Trusted
  # every internal zone, management, transit and servers the zones they
  # operate, and restricted zones only the gateway. This decides only who may
  # start a ping; echo replies and the ICMP errors that path MTU discovery and
  # traceroute rely on are related traffic. Pings to the gateway are rate
  # limited.
  pingTargets = {
    local = [
      "wan"
      "trusted"
      "lan"
      "servers"
      "iot"
      "roon"
      "guest"
      "transit"
    ];
    trusted = [
      "local"
      "lan"
      "servers"
      "iot"
      "roon"
      "guest"
      "transit"
    ];
    lan = [
      "local"
      "servers"
      "transit"
    ];
    transit = [
      "local"
      "trusted"
      "servers"
      "lan"
      "iot"
    ];
    servers = [
      "local"
      "trusted"
      "iot"
      "transit"
    ];
    iot = [ "local" ];
    guest = [ "local" ];
    roon = [ "local" ];
  };
  ping =
    destination:
    {
      l4proto = "icmp";
      icmpType = "echo-request";
      comment = "Ping";
    }
    // lib.optionalAttrs (destination == "local") {
      limit = {
        rate = "10/second";
        burst = 20;
      };
    };
  # Each ping rule precedes the pair's other rules, creating the pair if needed.
  withPings =
    policy:
    lib.recursiveUpdate policy (
      lib.mapAttrs (source: destinations: {
        to = lib.genAttrs destinations (
          destination: [ (ping destination) ] ++ (policy.${source}.to.${destination} or [ ])
        );
      }) pingTargets
    );
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
    dns_vips = addressSet [
      "10.254.253.53"
      "172.53.53.53"
    ];
    proxmox_hosts = addressSet [
      "10.1.1.31"
      "10.1.1.32"
      "10.1.1.41"
    ];
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
      addresses.metrics
      "10.1.1.155"
      "10.1.2.16"
      "10.1.1.32"
      "10.1.2.57"
    ];
    plex_clients = addressSet [ "10.1.3.16" ];
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
    proxmox_ports = portSet [
      8006
      8007
    ];
  };

  # Omitted zone pairs are denied. Rules within a pair are evaluated in order.
  ipv4 = withPings {
    guest.to.local = [ dhcp ];
    guest.to.transit = [ dns4 ];
    guest.to.wan = [ accept ];
    iot.to.local = [
      (tcp {
        daddr = addresses.matchbox;
        dport = 80;
        comment = "PXE boot assets";
      })
      dhcp
      ntp4
      {
        l4proto = "igmp";
        comment = "Multicast membership";
      }
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
    iot.to.wan = [
      blockDot
      accept
    ];
    lan.to.local = [
      (tcp {
        daddr = addresses.matchbox;
        dport = 80;
        comment = "PXE boot assets";
      })
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
    local.to.roon = [
      {
        l4proto = "igmp";
        comment = "Multicast membership";
      }
    ];
    local.to.iot = [
      {
        l4proto = "igmp";
        comment = "Multicast membership";
      }
    ];
    local.to.servers = [
      {
        l4proto = 112;
        saddr = "10.1.1.5";
        daddr = "10.1.1.6";
        comment = "VRRP to servers backup";
      }
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
      (tcpUdp {
        daddr = dhcpDns.replicas;
        dport = 53;
        saddr = dhcpDns.primary;
        comment = "DNS zone notifications";
      })
      (tcp {
        daddr = "10.254.0.1";
        dport = 179;
        saddr = "10.254.0.0";
        comment = "BGP";
      })
    ];
    local.to.trusted = [
      {
        l4proto = 112;
        saddr = "10.1.2.5";
        daddr = "10.1.2.6";
        comment = "VRRP to trusted backup";
      }
      {
        l4proto = "igmp";
        comment = "Multicast membership";
      }
      (udp {
        sport = 51820;
        comment = "WireGuard";
      })
    ];
    local.to.wan = [
      {
        daddr = [
          "224.0.0.0/4"
          "255.255.255.255"
        ];
        verdict = "drop";
      }
      (tcpUdp {
        daddr = "1.1.1.1";
        dport = 53;
      })
      (udp { dport = 123; })
      (tcp { dport = 443; })
      (udp { sport = 51820; })
    ];
    roon.to.local = [
      dhcp
      ntp4
      {
        l4proto = "igmp";
        comment = "Multicast membership";
      }
    ];
    roon.to.transit = [
      (tcpUdp {
        daddr = network.dnsVip;
        dport = 53;
        comment = "DNS";
      })
      (tcp {
        saddr = rock;
        daddr = setRef "storage";
        dport = 445;
        comment = "ROCK music library";
      })
    ];
    # Relayed discovery keeps the client's source address, so ROCK replies
    # directly to the client's sending socket.
    roon.to.trusted = [
      (udp {
        saddr = rock;
        sport = 9003;
        daddr = "10.1.2.0/24";
        comment = "Roon discovery replies";
      })
    ];
    roon.to.wan = [
      (tcp {
        dport = [
          80
          443
        ];
        comment = "Music services and firmware updates";
      })
    ];
    servers.to.lan = [
      (udp {
        dport = 161;
        comment = "SNMP";
      })
    ];
    servers.to.local = [
      {
        l4proto = 112;
        saddr = "10.1.1.6";
        daddr = "10.1.1.5";
        comment = "VRRP from servers backup";
      }
      (tcp {
        daddr = addresses.matchbox;
        dport = 80;
        comment = "PXE boot assets";
      })
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
    # Pod addresses are not masqueraded, so Home Assistant reaches ROON devices
    # from the pod network.
    transit.to.roon = [
      (tcp {
        saddr = setRef "transit_pods";
        daddr = rock;
        dport = 9330;
        comment = "Pod access to the Roon Core API";
      })
      (tcp {
        saddr = setRef "transit_pods";
        daddr = bluesoundPlayers;
        dport = 11000;
        comment = "Pod access to the Bluesound players";
      })
    ];
    transit.to.lan = [
      (tcp {
        saddr = setRef "transit_pods";
        daddr = "10.1.0.23";
        dport = 443;
        comment = "UniFi controller";
      })
      (tcp {
        daddr = setRef "metrics_targets";
        dport = 9100;
        saddr = setRef "transit_pods";
        comment = "Host metrics";
      })
      # Home Assistant reaches these Trusted devices from the pod network.
      (tcp {
        saddr = setRef "transit_pods";
        daddr = "10.1.2.53";
        dport = 14999;
        comment = "Pod access to Anthem A/V control";
      })
      (tcp {
        saddr = setRef "transit_pods";
        daddr = "10.1.2.54";
        dport = [
          8080
          9090
        ];
        comment = "Pod access to Kodi JSON-RPC";
      })
      (tcp {
        saddr = setRef "transit_pods";
        daddr = "10.1.2.56";
        dport = 80;
        comment = "Pod access to the Unfolded Circle remote API";
      })
      (udp {
        saddr = setRef "transit_pods";
        daddr = "10.1.2.70";
        dport = 161;
        comment = "Pod access to Brother printer SNMP";
      })
    ];
    transit.to.local = [
      (tcpUdp {
        daddr = dhcpDns.primary;
        saddr = dhcpDns.replicas;
        dport = 53;
        comment = "DHCP DNS replication";
      })
      (tcp {
        daddr = "10.254.0.0";
        dport = 179;
        saddr = "10.254.0.1";
        comment = "BGP";
      })
      ntp4
      (tcp {
        daddr = setRef "metrics_targets";
        dport = 9100;
        saddr = setRef "transit_pods";
        comment = "Host metrics";
      })
      (udp {
        daddr = addresses.tftp;
        dport = 69;
        saddr = "10.254.0.0/24";
        comment = "TFTP";
      })
    ];
    transit.to.servers = [
      (tcp {
        saddr = setRef "transit_pods";
        daddr = "10.1.1.30";
        dport = 443;
        comment = "IPMI certificates";
      })
      (tcp {
        daddr = setRef "proxmox_hosts";
        dport = setRef "proxmox_ports";
        comment = "Proxmox management";
      })
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
      (tcp {
        saddr = setRef "transit_pods";
        daddr = "10.1.2.70";
        dport = [
          443
          54921
        ];
        comment = "Pod scanner access";
      })
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
        daddr.set = "geoip_cn_ru";
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
    trusted.to.iot = [ accept ];
    trusted.to.lan = [ accept ];
    trusted.to.local = [
      (tcp {
        daddr = addresses.matchbox;
        dport = 80;
        comment = "PXE boot assets";
      })
      {
        l4proto = 112;
        saddr = "10.1.2.6";
        daddr = "10.1.2.5";
        comment = "VRRP from trusted backup";
      }
      dhcp
      ntp4
      tftp
      {
        l4proto = "igmp";
        comment = "Multicast membership";
      }
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
    # Trusted clients, including WireGuard peers, may reach every ROON device:
    # Roon control and ARC, ROCK administration and the BluOS app.
    trusted.to.roon = [ accept ];
    trusted.to.servers = [ accept ];
    trusted.to.transit = [
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
      # WireGuard peers share the trusted zone but must not reach OOB.
      {
        saddr = "10.1.2.0/24";
        daddr = "10.1.254.0/24";
        comment = "Trusted LAN to OOB";
      }
      (tcp {
        daddr = setRef "k8s_nodes";
        dport = setRef "node_management";
        comment = "Node management";
      })
    ];
    trusted.to.wan = [
      blockDot
      accept
    ];
    wan.to.local = [
      (udp {
        dport = 51820;
        comment = "WireGuard";
      })
    ];
    wan.to.servers = [
      (tcp {
        daddr = "10.45.0.24";
        dport = 50413;
        ctStatus = "dnat";
        comment = "Torrent forwarding";
      })
    ];
    wan.to.transit = [
      {
        saddr.set = "geoip_cn_ru";
        verdict = "drop";
        comment = "GeoIP block";
      }
      (tcp {
        daddr = "10.45.0.24";
        dport = 50413;
        ctStatus = "dnat";
        comment = "Torrent forwarding";
      })
    ];
  };

  # Internal IPv6 zone pairs permit ICMPv6. WAN ingress permits only the
  # error types below, with neighbor discovery additionally allowed to local.
  ipv6 =
    lib.recursiveUpdate
      (lib.genAttrs internalIpv6 (source: {
        to = lib.genAttrs (lib.remove source internalIpv6) (_: [ icmp6 ]);
      }))
      {
        iot.to.local = [
          (icmpv6 {
            icmpv6Type = "nd-router-advert";
            verdict = "drop";
            comment = "Ignore IoT router advertisements";
          })
          icmp6
        ];
        iot.to.transit = [
          icmp6
        ];
        iot.to.wan = [
          blockDot
          accept
        ];
        local.to.iot = [
          icmp6
        ];
        local.to.transit = [
          icmp6
        ];
        local.to.trusted = [
          icmp6
          (udp {
            dport = 546;
            sport = 547;
            comment = "DHCPv6 client";
          })
        ];
        local.to.wan = [
          (icmpv6 {
            icmpv6Type = "nd-router-solicit";
            daddr = "ff02::2";
            hopLimit = 255;
          })
          (icmpv6 {
            icmpv6Type = [
              "nd-neighbor-solicit"
              "nd-neighbor-advert"
            ];
            hopLimit = 255;
          })
          (icmpv6 {
            icmpv6Type = [
              "mld-listener-report"
              "mld-listener-done"
              "mld2-listener-report"
            ];
            daddr = "ff02::/16";
            hopLimit = 1;
          })
          {
            daddr = "ff00::/8";
            verdict = "drop";
          }
          (tcpUdp {
            daddr = "2606:4700:4700::1111";
            dport = 53;
          })
          (udp { dport = 123; })
          (tcp { dport = 443; })
          (udp { sport = 51820; })
          (icmpv6 {
            icmpv6Type = [
              "echo-request"
              "echo-reply"
            ];
          })
        ]
        ++ icmp6Errors;
        transit.to.local = [ accept ];
        trusted.to.local = [
          icmp6
          ssh
        ];
        trusted.to.transit = [
          icmp6
        ];
        trusted.to.wan = [
          blockDot
          accept
        ];
        thread.to.local = [
          (icmpv6 {
            icmpv6Type = "nd-router-advert";
            saddr = "fe80::892:17ff:febd:446e";
            etherSaddr = "0a:92:17:bd:44:6e";
            comment = "OMR route advertisements from OTBR";
          })
          (icmpv6 {
            icmpv6Type = "nd-router-advert";
            verdict = "drop";
            comment = "Ignore other infrastructure router advertisements";
          })
          icmp6
        ];
        local.to.thread = [
          icmp6
        ];
        matter.to.local = [
          icmp6
        ];
        local.to.matter = [
          icmp6
        ];
        matter.to.thread = [
          icmp6
          (udp {
            saddr = "fd74:f571:d3bd:1061::2";
            daddr = "fd42:dfb5:24e4:1::/64";
          })
        ];
        thread.to.matter = [
          icmp6
          (udp {
            saddr = "fd42:dfb5:24e4:1::/64";
            daddr = "fd74:f571:d3bd:1061::2";
          })
        ];
        matter.to.iot = [
          icmp6
          (udp {
            saddr = "fd74:f571:d3bd:1061::2";
            daddr = "fd74:f571:d3bd:40::/64";
          })
        ];
        iot.to.matter = [
          icmp6
          (udp {
            saddr = "fd74:f571:d3bd:40::/64";
            daddr = "fd74:f571:d3bd:1061::2";
          })
        ];
        trusted.to.thread = [
          icmp6
          (udp {
            daddr = [
              "fd42:dfb5:24e4:1::/64"
              "fd74:f571:d3bd:1060::2"
            ];
          })
        ];
        thread.to.trusted = [
          icmp6
          (udp {
            saddr = "fd42:dfb5:24e4:1::/64";
            daddr = "fd74:f571:d3bd:20::/64";
          })
        ];
        trusted.to.matter = [
          icmp6
          (udp { daddr = "fd74:f571:d3bd:1061::2"; })
        ];
        wan.to = lib.genAttrs internalIpv6 (
          destination:
          icmp6Errors
          ++ (
            {
              local = [
                (icmpv6 {
                  icmpv6Type = "mld-listener-query";
                  saddr = "fe80::/10";
                  daddr = "ff02::/16";
                  hopLimit = 1;
                })
                (icmpv6 {
                  icmpv6Type = "nd-router-advert";
                  hopLimit = 255;
                  saddr = "fe80::/10";
                  comment = "ICMPv6";
                })
                (icmpv6 {
                  icmpv6Type = "nd-router-solicit";
                  hopLimit = 255;
                  comment = "ICMPv6";
                })
                (icmpv6 {
                  icmpv6Type = "nd-neighbor-solicit";
                  hopLimit = 255;
                  comment = "ICMPv6";
                })
                (icmpv6 {
                  icmpv6Type = "nd-neighbor-advert";
                  hopLimit = 255;
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
            }
            .${destination} or [ ]
          )
        );
      };
}
