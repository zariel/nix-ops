{ lib, ... }:
let
  policy = import ./firewall-policy.nix { inherit lib; };
  inherit (policy) zones;
  renderRule = import ./firewall-rule.nix { inherit lib; };
  interfaces = names: "{ " + lib.concatMapStringsSep ", " (n: ''"${n}"'') names + " }";
  flows =
    lib.concatMap
      (
        family:
        lib.concatLists (
          lib.mapAttrsToList (
            source: sourcePolicy:
            lib.mapAttrsToList (destination: rules: {
              inherit
                family
                source
                destination
                rules
                ;
              chain = "${family}_${source}_${destination}";
            }) sourcePolicy.to
          ) policy.${family}
        )
      )
      [
        "ipv4"
        "ipv6"
      ];
  sets =
    definitions:
    lib.concatStringsSep "\n" (
      lib.mapAttrsToList (name: definition: ''
        set ${name} {
          type ${definition.type}; flags ${lib.concatStringsSep ", " definition.flags};
          elements = { ${
            lib.concatMapStringsSep ", " (
              value:
              if builtins.isAttrs value then "${toString value.from}-${toString value.to}" else toString value
            ) definition.elements
          } }
        }
      '') definitions
    );
  chains = lib.concatMapStringsSep "\n" (flow: ''
    chain ${flow.chain} {
      ${lib.concatMapStringsSep "\n" (renderRule flow.family) flow.rules}
      counter drop
    }
  '') flows;
  dispatch =
    hook:
    lib.concatMapStringsSep "\n" (
      flow:
      lib.optionalString
        (
          if hook == "input" then
            flow.destination == "local"
          else if hook == "output" then
            flow.source == "local"
          else
            flow.source != "local" && flow.destination != "local"
        )
        (
          "meta nfproto ${flow.family} "
          + lib.optionalString (flow.source != "local") "iifname ${interfaces zones.${flow.source}} "
          +
            lib.optionalString (flow.destination != "local")
              "oifname ${interfaces zones.${flow.destination}} "
          + "jump ${flow.chain}"
        )
    ) flows;
in
{
  assertions = [
    {
      assertion = lib.all (
        flow:
        flow.source != flow.destination
        && builtins.elem flow.source (builtins.attrNames zones ++ [ "local" ])
        && builtins.elem flow.destination (builtins.attrNames zones ++ [ "local" ])
        && flow.rules != [ ]
      ) flows;
      message = "Gateway firewall policies must name distinct known zones and contain rules; omit denied pairs.";
    }
  ];
  boot.kernelModules = [ "nf_conntrack_tftp" ];
  networking.firewall.enable = false;
  networking.nftables = {
    enable = true;
    flushRuleset = false;
    tables.gateway = {
      family = "inet";
      content =
        builtins.readFile ./geoip-cn-ru.nft
        + sets policy.addressSets
        + sets policy.portSets
        + chains
        + ''
          ct helper tftp {
            type "tftp" protocol udp;
            l3proto ip;
          }
          chain helpers {
            type filter hook prerouting priority mangle; policy accept;
            iifname { "bond0.10", "bond0.20", "bond0.100", "bond0.3001", "wg01" } meta nfproto ipv4 udp dport 69 ct helper set "tftp"
          }
          chain input {
            type filter hook input priority filter; policy drop;
            iifname "lo" accept
            ct state invalid drop
            ct state established,related accept
            # WAN lease bootstrap is independent of the zone policy.
            iifname "wan0" udp sport 67 udp dport 68 accept
            iifname "wan0" udp sport 547 udp dport 546 accept
            # Transit monitoring reaches the gateway's loopback identity.
            iifname "bond0.3001" ip saddr 172.20.0.0/16 ip daddr 10.254.254.1 tcp dport 9100 accept
            ${dispatch "input"}
          }
          chain forward {
            type filter hook forward priority filter; policy drop;
            ct state invalid drop
            ct state established,related accept
            # A zone includes all its interfaces, including WireGuard -> trusted.
            ${lib.concatStringsSep "\n" (
              lib.mapAttrsToList (_: ifs: "iifname ${interfaces ifs} oifname ${interfaces ifs} accept") zones
            )}
            ${dispatch "forward"}
          }
          chain output {
            type filter hook output priority filter; policy drop;
            oifname "lo" accept
            ct state invalid drop
            ct state established,related accept
            # DHCP replies and router advertisements bypass per-zone output rules.
            oifname "wan0" udp sport { 68, 546 } udp dport { 67, 547 } accept
            oifname { "bond0.10", "bond0.20", "bond0.30", "bond0.40", "bond0.100" } udp sport 67 udp dport 68 accept
            oifname { "bond0.20", "bond0.40" } meta l4proto ipv6-icmp accept
            # Kernel log collector is routed through transit, not the servers VLAN.
            oifname "bond0.3001" ip daddr 10.45.0.2 tcp dport 6001 accept
            ${dispatch "output"}
          }
          chain mss {
            type filter hook forward priority mangle; policy accept;
            tcp flags & (syn | rst) == syn tcp option maxseg size set rt mtu
          }
          chain prerouting {
            type nat hook prerouting priority dstnat; policy accept;
            iifname { "bond0.40", "wg01" } ip daddr != 172.53.53.53 meta l4proto { tcp, udp } th dport 53 dnat ip to 172.53.53.53
            iifname { "bond0.20", "bond0.40" } ip6 daddr != fd74:f571:d3bd:53::53 meta l4proto { tcp, udp } th dport 53 dnat ip6 to fd74:f571:d3bd:53::53
            # Management NTP interception applies to VLAN 100.
            iifname { "bond0.100", "bond0.10", "bond0.20", "bond0.40", "wg01" } ip daddr != 10.254.254.1 udp dport 123 dnat ip to 10.254.254.1
            iifname "wan0" tcp dport 59453 dnat ip to 10.1.2.60:59453
            iifname "wan0" tcp dport 50413 dnat ip to 10.45.0.24:50413
          }
          chain postrouting {
            type nat hook postrouting priority srcnat; policy accept;
            oifname "wan0" meta nfproto ipv4 masquerade
          }
        '';
    };
  };
}
