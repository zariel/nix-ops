{ pkgs }:
let
  inherit (pkgs) lib;
  inherit (import ../systems/gateway/firewall-helpers.nix)
    addressSet
    portSet
    setRef
    tcp
    udp
    tcpUdp
    icmpv6
    ;
  render = import ../systems/gateway/firewall-rule.nix { inherit lib; };
  rejects = family: rule: !(builtins.tryEval (builtins.deepSeq (render family rule) true)).success;
  failures = lib.runTests {
    testProtocols = {
      expr =
        map
          (
            helper:
            render "ipv4" (helper {
              dport = 53;
              verdict = "drop";
              comment = "DNS";
            })
          )
          [
            tcp
            udp
            tcpUdp
          ];
      expected = [
        ''meta l4proto tcp th dport 53 counter drop comment "DNS"''
        ''meta l4proto udp th dport 53 counter drop comment "DNS"''
        ''meta l4proto { tcp, udp } th dport 53 counter drop comment "DNS"''
      ];
    };
    testProtocolOverrides = {
      expr =
        map
          (
            helper:
            (builtins.tryEval (helper {
              l4proto = "icmp";
            })).success
          )
          [
            tcp
            udp
            tcpUdp
            icmpv6
          ];
      expected = [
        false
        false
        false
        false
      ];
    };
    testSets = {
      expr = {
        addresses = addressSet [
          "192.0.2.1"
          "192.0.2.2"
        ];
        ports = portSet [
          22
          443
        ];
      };
      expected = {
        addresses = {
          type = "ipv4_addr";
          flags = [ "interval" ];
          elements = [
            "192.0.2.1"
            "192.0.2.2"
          ];
        };
        ports = {
          type = "inet_service";
          flags = [ "interval" ];
          elements = [
            22
            443
          ];
        };
      };
    };
    testPorts = {
      expr = render "ipv4" {
        l4proto = [
          "tcp"
          "udp"
        ];
        sport = {
          from = 1024;
          to = 65535;
        };
        dport = [
          53
          853
        ];
        comment = "DNS";
      };
      expected = ''meta l4proto { tcp, udp } th sport 1024-65535 th dport { 53, 853 } counter accept comment "DNS"'';
    };
    testAddresses = {
      expr = render "ipv4" (tcp {
        saddr = setRef "k8s_nodes";
        daddr = "10.1.2.54";
        dport = 9100;
      });
      expected = "meta l4proto tcp ip saddr @k8s_nodes ip daddr 10.1.2.54 th dport 9100 counter accept";
    };
    testMask = {
      expr = render "ipv6" {
        l4proto = "tcp";
        daddr = {
          mask = "::ffff:ffff:ffff:ffff";
          value = "::7c7d:c6ff:fec7:26ac";
        };
        dport = 3074;
      };
      expected = "meta l4proto tcp ip6 daddr & ::ffff:ffff:ffff:ffff == ::7c7d:c6ff:fec7:26ac th dport 3074 counter accept";
    };
    testIcmpv6 = {
      expr = render "ipv6" (icmpv6 {
        icmpv6Type = "packet-too-big";
      });
      expected = "meta l4proto ipv6-icmp icmpv6 type packet-too-big counter accept";
    };
    testDnat = {
      expr = render "ipv4" (tcp {
        daddr = "10.45.0.24";
        dport = 50413;
        ctStatus = "dnat";
      });
      expected = "meta l4proto tcp ip daddr 10.45.0.24 th dport 50413 ct status dnat counter accept";
    };
    testHopLimit = {
      expr = render "ipv6" (icmpv6 {
        icmpv6Type = "nd-router-advert";
        saddr = "fe80::/10";
        hopLimit = 255;
      });
      expected = "meta l4proto ipv6-icmp ip6 saddr fe80::/10 icmpv6 type nd-router-advert ip6 hoplimit 255 counter accept";
    };
    testIcmp = {
      expr = render "ipv4" {
        l4proto = "icmp";
        icmpType = "echo-request";
      };
      expected = "meta l4proto icmp icmp type echo-request counter accept";
    };
    testRouterIdentity = {
      expr = render "ipv6" (icmpv6 {
        saddr = "fe80::892:17ff:febd:446e";
        etherSaddr = "0a:92:17:bd:44:6e";
        icmpv6Type = "nd-router-advert";
      });
      expected = "meta l4proto ipv6-icmp ip6 saddr fe80::892:17ff:febd:446e ether saddr 0a:92:17:bd:44:6e icmpv6 type nd-router-advert counter accept";
    };
    testDrop = {
      expr = render "ipv4" {
        saddr.set = "blocked_sources";
        verdict = "drop";
      };
      expected = "ip saddr @blocked_sources counter drop";
    };
    testUnrestricted = {
      expr = render "ipv4" { verdict = "accept"; };
      expected = "counter accept";
    };
    testInvalidMatches = {
      expr = map (rejects "ipv4") [
        {
          l4proto = "tcp";
          icmpType = "echo-request";
        }
        { hopLimit = 255; }
        { ctStatus = "snat"; }
        {
          l4proto = "tcp";
          dprot = 22;
        }
        { dport = 22; }
        {
          l4proto = "tcp";
          dport = [ ];
        }
        {
          l4proto = "udp";
          dport = 65536;
        }
        {
          l4proto = "tcp";
          dport = {
            from = 100;
            to = 50;
          };
        }
        {
          l4proto = "ipv6-icmp";
          icmpv6Type = "packet-too-big";
        }
      ];
      expected = [
        true
        true
        true
        true
        true
        true
        true
        true
        true
      ];
    };
  };
in
assert lib.assertMsg (failures == [ ]) (builtins.toJSON failures);
pkgs.runCommand "gateway-firewall" { } ''
  touch "$out"
''
