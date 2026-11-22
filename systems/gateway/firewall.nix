{ config, lib, ... }:
let
  addresses = (import ../../roles/gateway-services/settings.nix).addresses;
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
  systemd.services.nftables.serviceConfig = (import ./sandbox.nix) // {
    CapabilityBoundingSet = [ "CAP_NET_ADMIN" ];
    RestrictAddressFamilies = [
      "AF_UNIX"
      "AF_NETLINK"
    ];
    MemoryMax = "256M";
    TasksMax = 64;
  };
  networking.firewall.enable = false;
  networking.nftables = {
    # The build sandbox has no host user database; runtime resolves the service UID.
    preCheckRuleset = lib.optionalString (config.users.users ? matchbox) ''
      sed -i 's/skuid "matchbox"/skuid 0/g' ruleset.conf
    '';
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
            # Lease bootstrap must work before a default route exists for source validation.
            iifname "wan0" meta nfproto ipv4 udp sport 67 udp dport 68 accept
            iifname "wan0" meta nfproto ipv6 udp sport 547 udp dport 546 accept
            # Loose source validation permits asymmetric routing but rejects unroutable WAN sources.
            iifname "wan0" meta nfproto ipv4 fib saddr oif missing counter drop
            ct state invalid drop
            ct state established,related accept
            # The OOB port is in no zone. Input from a VRF member is seen on the VRF
            # device, so this admits SSH arriving on rescue0 and nothing else.
            iifname "vrf-oob" meta nfproto ipv4 tcp dport 22 accept
            ${dispatch "input"}
          }
          chain forward {
            type filter hook forward priority filter; policy drop;
            iifname "wan0" meta nfproto ipv4 fib saddr oif missing counter drop
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
            ${lib.optionalString (config.users.users ? matchbox) ''
              # Matchbox serves inbound requests and may only send tracked replies.
              meta skuid "matchbox" ct state established,related accept
              meta skuid "matchbox" counter drop
            ''}
            oifname "lo" accept
            # Packets leaving through a VRF also pass this hook a second time,
            # untracked, with the VRF device as their output interface. The pass
            # on rescue0 itself is still filtered below, so only replies leave.
            oifname "vrf-oob" accept
            ct state invalid drop
            ct state established,related accept
            # DHCP replies and router advertisements bypass per-zone output rules.
            oifname "wan0" meta nfproto ipv4 udp sport 68 udp dport 67 accept
            oifname "wan0" meta nfproto ipv6 udp sport 546 udp dport 547 accept
            oifname { "bond0.10", "bond0.20", "bond0.30", "bond0.40", "bond0.60", "bond0.100" } udp sport 67 udp dport 68 accept
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
            iifname { "bond0.20", "bond0.40", "wg01" } ip daddr != @dns_vips meta l4proto { tcp, udp } th dport 53 counter dnat ip to 10.254.253.53
            # Management NTP interception applies to VLAN 100.
            iifname { "bond0.100", "bond0.10", "bond0.20", "bond0.40", "wg01" } ip daddr != ${addresses.ntp} udp dport 123 counter dnat ip to ${addresses.ntp}
            iifname "wan0" tcp dport 50413 counter dnat ip to 10.45.0.24:50413
          }
          chain postrouting {
            type nat hook postrouting priority srcnat; policy accept;
            oifname "wan0" meta nfproto ipv4 counter masquerade
          }
        '';
    };
  };
}
