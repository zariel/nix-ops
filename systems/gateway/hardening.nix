{ config, lib, ... }:
let
  sandbox = import ./sandbox.nix;
  dns = import ../../roles/dhcp-dns/settings.nix { inherit lib; };
  ip = [
    "AF_UNIX"
    "AF_INET"
    "AF_INET6"
  ];
  control = ip ++ [
    "AF_NETLINK"
    "AF_PACKET"
  ];
in
{
  systemd.settings.Manager = {
    DefaultTasksMax = 512;
    DefaultLimitCORE = 0;
  };
  # A crash must not persist credentials or consume the router's disk with cores.
  systemd.coredump.settings.Coredump = {
    Storage = "none";
    ProcessSizeMax = 0;
  };
  services.journald.settings.Journal = {
    SystemMaxUse = "256M";
    RuntimeMaxUse = "64M";
    RateLimitIntervalSec = "30s";
    RateLimitBurst = 10000;
  };
  systemd.services = {
    dbus-broker = lib.mkIf config.services.dbus.enable {
      serviceConfig = sandbox // {
        InaccessiblePaths = [ ];
        CapabilityBoundingSet = [
          "CAP_AUDIT_WRITE"
          "CAP_SETUID"
          "CAP_SETGID"
        ];
        RestrictAddressFamilies = [
          "AF_UNIX"
          "AF_NETLINK"
        ];
        ReadWritePaths = [ "/run/dbus" ];
        MemoryHigh = "128M";
        MemoryMax = "256M";
      };
    };
    nscd = lib.mkIf config.services.nscd.enable {
      serviceConfig = sandbox // {
        ProtectHome = lib.mkForce true;
        CapabilityBoundingSet = "";
        RestrictAddressFamilies = [
          "AF_UNIX"
          "AF_INET"
          "AF_INET6"
          "AF_NETLINK"
        ];
        MemoryHigh = "64M";
        MemoryMax = "128M";
      };
    };
    frr = lib.mkIf config.services.frr.bgpd.enable {
      serviceConfig = sandbox // {
        # FRR requests SYS_ADMIN at startup even without network-namespace VRFs.
        # Mount and namespace syscalls remain blocked by the unit sandbox.
        CapabilityBoundingSet = [
          "CAP_CHOWN"
          "CAP_DAC_OVERRIDE"
          "CAP_FOWNER"
          "CAP_KILL"
          "CAP_NET_ADMIN"
          "CAP_NET_BIND_SERVICE"
          "CAP_NET_RAW"
          "CAP_SETGID"
          "CAP_SETUID"
          "CAP_SYS_ADMIN"
        ];
        RestrictAddressFamilies = control;
        # watchfrr supervises daemons that drop to the separate frr identity.
        ProtectProc = "default";
        ReadWritePaths = [ "/run/frr" ];
        # The root supervisor and daemons running as frr share persistent PIM state.
        Group = "frr";
        StateDirectory = "frr";
        StateDirectoryMode = "0770";
        MemoryHigh = "512M";
        MemoryMax = "1G";
      };
    };
    keepalived = lib.mkIf config.services.keepalived.enable {
      serviceConfig = sandbox // {
        CapabilityBoundingSet = [
          "CAP_NET_ADMIN"
          "CAP_NET_RAW"
          "CAP_NET_BIND_SERVICE"
        ];
        RestrictAddressFamilies = control;
        # The native module puts its parent and VRRP child PID files in /run.
        ReadWritePaths = [ "/run" ];
        MemoryHigh = "64M";
        MemoryMax = "256M";
      };
    };
    kea-dhcp4-server = lib.mkIf config.services.kea.dhcp4.enable {
      serviceConfig = sandbox // {
        RestrictAddressFamilies = [
          "AF_UNIX"
          "AF_INET"
          "AF_NETLINK"
          "AF_PACKET"
        ];
        MemoryHigh = "256M";
        MemoryMax = "512M";
      };
    };
    kea-dhcp-ddns-server = lib.mkIf config.services.kea.dhcp-ddns.enable {
      serviceConfig = sandbox // {
        CapabilityBoundingSet = lib.mkForce "";
        AmbientCapabilities = lib.mkForce "";
        RestrictAddressFamilies = [
          "AF_UNIX"
          "AF_INET"
        ];
        IPAddressDeny = "any";
        IPAddressAllow = "localhost";
        MemoryHigh = "128M";
        MemoryMax = "256M";
      };
    };
    atftpd = lib.mkIf config.services.atftpd.enable {
      serviceConfig = sandbox // {
        DynamicUser = true;
        User = "tftp";
        AmbientCapabilities = [ "CAP_NET_BIND_SERVICE" ];
        CapabilityBoundingSet = [ "CAP_NET_BIND_SERVICE" ];
        RestrictAddressFamilies = [
          "AF_UNIX"
          "AF_INET"
          "AF_NETLINK"
        ];
        ReadOnlyPaths = [ config.services.atftpd.root ];
        Restart = "on-failure";
        MemoryHigh = "64M";
        MemoryMax = "128M";
      };
    };
    syslog = lib.mkIf config.services.rsyslogd.enable {
      serviceConfig = sandbox // {
        DynamicUser = true;
        User = "rsyslog";
        SupplementaryGroups = [ "systemd-journal" ];
        CapabilityBoundingSet = "";
        StateDirectory = "rsyslog";
        RuntimeDirectory = "rsyslog";
        ExecStartPre = lib.mkForce [ ];
        RestrictAddressFamilies = [
          "AF_UNIX"
          "AF_INET"
        ];
        IPAddressDeny = "any";
        IPAddressAllow = "10.45.0.2/32";
        Restart = "on-failure";
        MemoryHigh = "128M";
        MemoryMax = "256M";
      };
    };
    bind = lib.mkIf config.services.bind.enable {
      serviceConfig = {
        IPAddressDeny = "any";
        IPAddressAllow = [ "localhost" ] ++ dns.replicas;
        Restart = "on-failure";
        RestartSec = "2s";
        LimitCORE = 0;
        TasksMax = 512;
        MemoryHigh = "512M";
        MemoryMax = "1G";
      };
    };
    chronyd = lib.mkIf config.services.chrony.enable {
      serviceConfig = {
        ProtectSystem = lib.mkForce "strict";
        PrivateDevices = lib.mkForce true;
        LimitCORE = 0;
        TasksMax = 128;
        MemoryHigh = "64M";
        MemoryMax = "128M";
      };
    };
    avahi-daemon = lib.mkIf config.services.avahi.enable {
      serviceConfig = {
        LimitCORE = 0;
        TasksMax = 128;
        MemoryHigh = "64M";
        MemoryMax = "128M";
      };
    };
    prometheus-node-exporter = lib.mkIf config.services.prometheus.exporters.node.enable {
      serviceConfig = {
        # The timex collector reads adjtimex; the empty capability set forbids clock changes.
        SystemCallFilter = [
          "@system-service"
          "adjtimex"
          "clock_adjtime"
        ];
        SystemCallErrorNumber = "EPERM";
        LimitCORE = 0;
        TasksMax = 512;
        MemoryHigh = "256M";
        MemoryMax = "512M";
      };
    };
    systemd-networkd = lib.mkIf config.systemd.network.enable {
      serviceConfig = {
        # Gateway links need no BPF loading or network-namespace administration.
        CapabilityBoundingSet = [
          ""
          "CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_BROADCAST CAP_NET_RAW"
        ];
        AmbientCapabilities = [
          ""
          "CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_BROADCAST CAP_NET_RAW"
        ];
      };
    };
    sshd = lib.mkIf config.services.openssh.enable {
      # SSH sessions must retain sudo and activation access to the host.
      serviceConfig = {
        LimitCORE = 0;
        TasksMax = 512;
        MemoryHigh = "256M";
        MemoryMax = "1G";
      };
    };
    nix-daemon = lib.mkIf config.nix.enable {
      # Builds and activation need namespaces and privilege transitions.
      serviceConfig = {
        CPUWeight = 10;
        IOWeight = 10;
        MemoryHigh = "512M";
        MemoryMax = "2G";
        TasksMax = lib.mkForce 1024;
        LimitCORE = 0;
      };
    };
  };
  nix.settings = {
    sandbox = true;
    allowed-users = [
      "root"
      "chris"
    ];
    max-jobs = 1;
    cores = 1;
  };
}
