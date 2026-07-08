{ lib, ... }:
let
  settings = (import ./settings.nix).networking;
  nameservers = [
    "172.53.53.53"
    "1.1.1.1"
    "8.8.8.8"
  ];
in
{
  networking = {
    inherit nameservers;
    useDHCP = false;
  };
  systemd.network.enable = true;

  systemd.network.netdevs."10-identity" = lib.mkIf settings.enable {
    netdevConfig = {
      Name = "dummy0";
      Kind = "dummy";
    };
  };

  assertions = lib.optionals settings.enable [
    {
      assertion = settings.identityAddress != null && settings.localASN != null;
      message = "Nostromo routing requires an identityAddress and localASN in settings.nix.";
    }
    {
      assertion =
        builtins.length settings.uplinks == 2
        && lib.all (
          link: link.macAddress != null && link.address != null && link.peerAddress != null
        ) settings.uplinks;
      message = "Nostromo routing requires two uplinks with physical MAC addresses and /31 endpoints.";
    }
    {
      assertion = !settings.cilium.enable || settings.localASN != settings.cilium.localASN;
      message = "Nostromo and Cilium require distinct ASNs for local eBGP.";
    }
  ];

  boot.kernel.sysctl = lib.mkIf settings.enable {
    "net.ipv4.ip_forward" = 1;
    # Either uplink may carry the return path.
    "net.ipv4.conf.all.rp_filter" = 2;
    "net.ipv4.conf.default.rp_filter" = 2;
  };

  systemd.network.links = lib.mkIf settings.enable (
    builtins.listToAttrs (
      map (link: {
        name = "10-${link.name}";
        value = {
          matchConfig.PermanentMACAddress = link.macAddress;
          linkConfig.Name = link.name;
        };
      }) settings.uplinks
    )
  );

  systemd.network.networks = lib.mkMerge [
    {
      # Bootstrap configuration, replaced when the routed links are ready.
      "10-uplink" = lib.mkIf (!settings.enable) {
        matchConfig.Name = "enp5s0np1";
        address = [ "10.254.1.101/31" ];
        dns = nameservers;
        gateway = [ "10.254.1.100" ];
        networkConfig = {
          DHCP = "no";
          IPv6AcceptRA = false;
          LinkLocalAddressing = "ipv6";
        };
        linkConfig.MTUBytes = "9000";
      };
    }
    (lib.mkIf settings.enable (
      {
        "10-identity" = {
          matchConfig.Name = "dummy0";
          address = [ "${settings.identityAddress}/32" ];
          networkConfig = {
            ConfigureWithoutCarrier = true;
            DHCP = "no";
            IPv6AcceptRA = false;
            LinkLocalAddressing = "no";
          };
        };
      }
      // builtins.listToAttrs (
        map (link: {
          name = "20-${link.name}";
          value = {
            matchConfig.Name = link.name;
            address = [ "${link.address}/31" ];
            dns = nameservers;
            linkConfig = {
              MTUBytes = "9000";
              RequiredForOnline = "no";
            };
            networkConfig = {
              DHCP = "no";
              IPv6AcceptRA = false;
              LinkLocalAddressing = "ipv6";
            };
          };
        }) settings.uplinks
      )
    ))
  ];

  services.bird = lib.mkIf settings.enable {
    enable = true;
    config = ''
      router id ${settings.identityAddress};

      protocol device {}

      protocol direct identity {
        interface "dummy0";
        ipv4 {
          import where net = ${settings.identityAddress}/32;
          export none;
        };
      }

      # Cilium owns pod/service forwarding. Only upstream defaults enter the FIB.
      protocol kernel host_routes {
        merge paths on;
        ipv4 {
          import none;
          export where net = 0.0.0.0/0;
        };
      }

      filter upstream_export {
        if proto = "identity" && net = ${settings.identityAddress}/32 then accept;
        ${lib.optionalString settings.cilium.enable ''
          if proto = "cilium" && net ~ [
            ${settings.cilium.podCIDR}+, ${settings.cilium.serviceCIDR}{32,32}
          ] then accept;
        ''}
        reject;
      }

      template bgp upstream {
        local as ${toString settings.localASN};
        direct;
        check link on;
        hold time 9;
        keepalive time 3;
        ipv4 {
          import where net = 0.0.0.0/0;
          export filter upstream_export;
          next hop self;
        };
      }

      ${lib.concatMapStringsSep "\n" (link: ''
        protocol bgp ${link.name} from upstream {
          source address ${link.address};
          neighbor ${link.peerAddress} as ${toString link.peerASN};
        }
      '') settings.uplinks}

      ${lib.optionalString settings.cilium.enable ''
        protocol bgp cilium {
          local 127.0.0.1 as ${toString settings.localASN};
          neighbor ${settings.cilium.address} as ${toString settings.cilium.localASN};
          passive on;
          multihop 2;
          ipv4 {
            gateway recursive;
            import filter {
              if net !~ [
                ${settings.cilium.podCIDR}+, ${settings.cilium.serviceCIDR}{32,32}
              ] then reject;
              # A local speaker has no forwarding next hop. Keep these only in
              # BIRD's RIB; host_routes excludes them from the kernel FIB.
              dest = RTD_BLACKHOLE;
              accept;
            };
            export none;
          };
        }
      ''}
    '';
  };
}
