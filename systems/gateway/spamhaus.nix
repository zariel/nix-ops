{ config, pkgs, ... }:
let
  command = "${pkgs.python3}/bin/python3 ${./spamhaus-drop.py} ${./spamhaus-drop.nft}";
  stateDirectory = "spamhaus-drop";
in
{
  assertions = [
    {
      assertion = config.networking.nftables.enable && !config.networking.nftables.flushRuleset;
      message = "Spamhaus DROP requires nftables to preserve independently managed tables.";
    }
  ];

  systemd.services.spamhaus-drop = {
    description = "Restore Spamhaus DROP firewall";
    wantedBy = [ "multi-user.target" ];
    wants = [ "network-pre.target" ];
    after = [
      "local-fs.target"
      "sysinit.target"
    ];
    before = [
      "network-pre.target"
      "shutdown.target"
    ];
    conflicts = [ "shutdown.target" ];
    unitConfig.DefaultDependencies = false;
    reloadIfChanged = true;
    path = [ pkgs.nftables ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = "${command} restore";
      ExecReload = "${command} restore";
      ExecStop = "${pkgs.nftables}/bin/nft delete table inet spamhaus_drop";
      StateDirectory = stateDirectory;
      StateDirectoryMode = "0700";
    };
  };

  systemd.services.spamhaus-drop-update = {
    description = "Update Spamhaus DROP lists";
    wantedBy = [ "multi-user.target" ];
    requires = [ "spamhaus-drop.service" ];
    wants = [ "network-online.target" ];
    after = [
      "spamhaus-drop.service"
      "network-online.target"
    ];
    environment.SPAMHAUS_URL_BASE = "https://www.spamhaus.org/drop";
    path = [ pkgs.nftables ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${command} update";
      StateDirectory = stateDirectory;
      StateDirectoryMode = "0700";
      TimeoutStartSec = "2min";
    };
  };

  systemd.timers.spamhaus-drop-update = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "daily";
      Persistent = true;
      RandomizedDelaySec = "15min";
    };
  };
}
