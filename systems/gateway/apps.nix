{ lib, pkgs, ... }:
let
  unifi = pkgs.unifi.overrideAttrs {
    version = "9.5.21";
    src = pkgs.fetchurl {
      url = "https://dl.ui.com/unifi/9.5.21/unifi_sysvinit_all.deb";
      hash = "sha256-faHMmrGuDI8wLCQtYi7lL4Z0V6aRFrKqTBOBLnVphq8=";
    };
  };
  speedtestSource = pkgs.fetchurl {
    url = "https://raw.githubusercontent.com/miguelndecarvalho/speedtest-exporter/v3.5.4/src/exporter.py";
    hash = "sha256-pCRxja/LKm+ANcfcEvATBwUD0TQPX0OTUryur7Al83o=";
  };
  speedtestPython = pkgs.python3.withPackages (p: [
    p.flask
    p.prometheus-client
    p.waitress
  ]);
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
    unifi = {
      address = "10.5.0.10";
      # Java and MongoDB initialization can exceed nspawn's one-minute deadline.
      timeoutStartSec = "3min";
      # Restore an application backup into fresh native state; the OCI MongoDB
      # files belong to a different MongoDB major and must not be opened here.
      mounts."/var/lib/unifi" = {
        hostPath = "/var/lib/gateway/unifi-native";
        isReadOnly = false;
      };
      module = {
        systemd.services.unifi = {
          after = [ "network-online.target" ];
          wants = [ "network-online.target" ];
        };
        services.unifi = {
          enable = true;
          unifiPackage = unifi;
          jrePackage = pkgs.jdk17_headless;
        };
      };
    };
    speedtest = {
      address = "10.5.0.11";
      mounts = { };
      module = {
        systemd.services.speedtest-exporter = {
          wantedBy = [ "multi-user.target" ];
          after = [ "network-online.target" ];
          wants = [ "network-online.target" ];
          path = [ pkgs.ookla-speedtest ];
          serviceConfig = {
            ExecStart = "${speedtestPython}/bin/python -u ${speedtestSource}";
            DynamicUser = true;
            StateDirectory = "speedtest-exporter";
            Environment = "HOME=/var/lib/speedtest-exporter";
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
    timeoutStartSec = app.timeoutStartSec or "1min";
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
      networking.nameservers = [ "172.53.53.53" ];
      # The gateway's container zone is the policy boundary.
      networking.firewall.enable = false;
    };
  }) applications;
  systemd.tmpfiles.rules = [
    "d /var/lib/gateway 0750 root systemd-network -"
    "d /var/lib/gateway/matchbox 0755 root root -"
    "d /var/lib/gateway/unifi-native 0755 root root -"
  ];
}
