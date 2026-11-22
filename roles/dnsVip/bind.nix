{
  config,
  lib,
  pkgs,
  ...
}:

with lib;

let
  cfg = config.services.dnsVip;
  gatewayAddress = import ./gateway-address.nix;
  gatewayServices = (import ../gateway-services/settings.nix).addresses;
  dns = import ../dhcp-dns/settings.nix { inherit lib; };
  bindZoneChecks = attrsets.mapAttrsToList (
    zoneName: zoneCfg: "${pkgs.bind}/bin/named-checkzone ${zoneName} ${zoneCfg.file}"
  ) (attrsets.filterAttrs (_: zone: zone.master) config.services.bind.zones);

  bindPreflight = pkgs.writeShellScript "bind-preflight" ''
    set -euo pipefail
    ${pkgs.bind}/bin/named-checkconf ${config.services.bind.configFile}
    ${concatStringsSep "\n    " bindZoneChecks}
  '';
in
{
  config = mkIf cfg.enable {
    services.bind = {
      listenOn = [
        "127.0.53.10"
        cfg.nodeIp
      ];
      ipv4Only = true;
      directory = "/var/lib/bind";
      extraOptions = ''
        recursion no;
        transfer-source ${cfg.nodeIp};
      '';

      cacheNetworks = [
        "10.1.0.0/24" # LAN
        "10.1.1.0/24" # SERVERS
        "10.1.2.0/24" # TRUSTED
        "10.1.3.0/24" # IOT
        "10.1.4.0/24" # ROON
        "192.168.2.0/24" # GUEST
        "10.5.0.0/16" # Host-owned services
        "10.254.0.0/16" # L3 servers
      ];

      extraConfig = ''
        logging {
          channel stdout {
            stderr;
            severity info;
            print-category yes;
            print-severity yes;
            print-time yes;
          };
          category security { stdout; };
          category dnssec   { stdout; };
          category default  { stdout; };
        };
      '';

      zones = {
        "cbannister.casa" = {
          master = true;
          file = pkgs.writeText "db.cbannister.casa" (
            builtins.replaceStrings
              [
                "@GATEWAY_ADDRESS@"
                "@GATEWAY_NTP@"
                "@GATEWAY_TFTP@"
                "@GATEWAY_METRICS@"
                "@GATEWAY_DHCP_DNS@"
                "@GATEWAY_MATCHBOX@"
              ]
              [
                gatewayAddress
                gatewayServices.ntp
                gatewayServices.tftp
                gatewayServices.metrics
                gatewayServices.dhcpDns
                gatewayServices.matchbox
              ]
              (builtins.readFile ./files/bind/zones/db.cbannister.casa)
          );
        };

        "unifi" = {
          master = true;
          file = ./files/bind/zones/db.unifi;
        };

        # OOB devices are statically addressed and never use DHCP, so this zone
        # stays a static master after the gateway takes over the DHCP networks.
        "254.1.10.in-addr.arpa" = {
          master = true;
          file = ./files/bind/zones/db.254.1.10.in-addr.arpa;
        };
      }
      // genAttrs dns.zones (zone: {
        master = false;
        masters = [ dns.primary ];
        file = "/var/lib/bind/${zone}";
      });
    };

    # Ensure bind starts after the bind interface is ready
    systemd.services.bind = {
      after = [ "sys-subsystem-net-devices-bind.device" ];
      bindsTo = [ "sys-subsystem-net-devices-bind.device" ];
      startLimitIntervalSec = mkForce 60;
      startLimitBurst = mkForce 5;
      serviceConfig = {
        ExecStartPre = bindPreflight;
        Restart = "on-failure";
        RestartSec = "5s";
        TimeoutStartSec = "30s";
      };
    };
  };
}
