{ lib, pkgs, ... }:
let
  applications = {
    matchbox = {
      address = "10.5.0.8";
      mounts."/var/lib/matchbox" = {
        hostPath = "/var/lib/gateway/matchbox";
        isReadOnly = false;
      };
      module = {
        users.users.matchbox = {
          isSystemUser = true;
          group = "matchbox";
        };
        users.groups.matchbox = { };
        systemd.services.matchbox = {
          wantedBy = [ "multi-user.target" ];
          after = [ "network-online.target" ];
          wants = [ "network-online.target" ];
          serviceConfig = {
            ExecStart = "${pkgs.matchbox-server}/bin/matchbox -address=0.0.0.0:80 -log-level=info";
            User = "matchbox";
            StateDirectory = "matchbox";
            AmbientCapabilities = [ "CAP_NET_BIND_SERVICE" ];
            CapabilityBoundingSet = [ "CAP_NET_BIND_SERVICE" ];
            Restart = "on-failure";
          };
        };
      };
    };
  };
in
{
  # Configure host routing when each veth appears, before container readiness.
  systemd.network.enable = true;
  systemd.network.networks = lib.mapAttrs' (
    name: app:
    lib.nameValuePair "30-app-${name}" {
      matchConfig.Name = "ve-${name}";
      address = [ "10.5.0.1/32" ];
      networkConfig = {
        LinkLocalAddressing = "no";
        IPv6AcceptRA = false;
      };
      routes = [
        {
          Destination = "${app.address}/32";
          Scope = "link";
          # FRR imports these externally managed kernel routes.
          Protocol = "boot";
        }
      ];
    }
  ) applications;
  containers = lib.mapAttrs (_: app: {
    autoStart = true;
    privateNetwork = true;
    extraFlags = [ "--network-veth" ];
    bindMounts = app.mounts;
    config = {
      imports = [ app.module ];
      nixpkgs.pkgs = pkgs;
      system.stateVersion = "26.05";
      time.timeZone = "Europe/London";
      networking.useDHCP = false;
      networking.useNetworkd = true;
      systemd.network.networks."10-uplink" = {
        matchConfig.Name = "host0";
        address = [ "${app.address}/32" ];
        networkConfig = {
          LinkLocalAddressing = "no";
          IPv6AcceptRA = false;
        };
        routes = [
          {
            Destination = "10.5.0.1/32";
            Scope = "link";
          }
          { Gateway = "10.5.0.1"; }
        ];
      };
      networking.useHostResolvConf = false;
      networking.nameservers = [ "10.254.253.53" ];
      # The gateway's container zone is the policy boundary.
      networking.firewall.enable = false;
    };
  }) applications;
  systemd.tmpfiles.rules = [
    "d /var/lib/gateway 0750 root systemd-network -"
    "d /var/lib/gateway/matchbox 0755 root root -"
  ];
}
