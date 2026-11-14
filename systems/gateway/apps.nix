{
  config,
  lib,
  pkgs,
  ...
}:
let
  addresses = (import ../../roles/gateway-services/settings.nix).addresses;
in
{
  imports = [ ./service-addresses.nix ];
  users.users.matchbox = {
    isSystemUser = true;
    group = "matchbox";
  };
  users.groups.matchbox = { };
  users.groups.matchbox-assets.members = lib.optional (config.users.users ? chris) "chris";

  systemd.services.matchbox = {
    description = "Matchbox network boot assets";
    wantedBy = [ "multi-user.target" ];
    requires = [ "systemd-networkd-wait-online@lo.service" ];
    after = [ "systemd-networkd-wait-online@lo.service" ];
    serviceConfig = (import ./sandbox.nix) // {
      ExecStart = "${pkgs.matchbox-server}/bin/matchbox -address=${addresses.matchbox}:80 -log-level=info";
      User = "matchbox";
      Group = "matchbox";
      WorkingDirectory = "/var/lib/matchbox";
      # Preserve the host's asset path while exposing only a read-only mount.
      BindReadOnlyPaths = [ "/var/lib/gateway/matchbox:/var/lib/matchbox" ];
      AmbientCapabilities = [ "CAP_NET_BIND_SERVICE" ];
      CapabilityBoundingSet = [ "CAP_NET_BIND_SERVICE" ];
      RestrictAddressFamilies = [
        "AF_UNIX"
        "AF_INET"
      ];
      SocketBindDeny = "any";
      SocketBindAllow = "ipv4:tcp:80";
      IPAddressDeny = "any";
      IPAddressAllow = [
        "localhost"
        "10.0.0.0/8"
        "172.16.0.0/12"
        "192.168.0.0/16"
      ];
      MemoryHigh = "128M";
      MemoryMax = "256M";
      TasksMax = 128;
      CPUQuota = "100%";
      CPUWeight = 20;
      IOWeight = 20;
      Restart = "on-failure";
      RestartSec = "2s";
    };
  };
  systemd.tmpfiles.rules = [
    "d /var/lib/gateway 0755 root root -"
    "d /var/lib/gateway/matchbox 0755 root root -"
    "d /var/lib/gateway/matchbox/assets 2775 root matchbox-assets -"
    "d /var/lib/matchbox 0755 root root -"
  ];
}
