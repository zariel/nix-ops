{
  config,
  lib,
  pkgs,
  ...
}:
let
  addresses = (import ../../roles/gateway-services/settings.nix).addresses;
  trusted = config.services.keepalived.vrrpInstances.TRUSTED;
  trustedVip = (builtins.head trusted.virtualIps).addr;
  roonInterfaces = [
    trusted.interface
    "bond0.60"
  ];
  roonReady = map (interface: "systemd-networkd-wait-online@${interface}.service") roonInterfaces;
  roonDiscovery = pkgs.writeShellScript "roon-discovery" ''
    # The relay reads interface subnets once at startup to build its capture
    # filters and broadcast addresses, so it needs Trusted's VRRP /24.
    until ip -4 -o addr show dev ${trusted.interface} | grep -Fq ' ${trustedVip} '; do
      sleep 1
    done
    exec ${
      lib.getExe (pkgs.callPackage ../../packages/udp-proxy-2020/package.nix { })
    } --interface ${lib.concatStringsSep "," roonInterfaces} --port 9003
  '';
in
{
  imports = [ ./service-addresses.nix ];
  services.frr = {
    bgpd.enable = true;
    pimd.enable = true;
    pim6d.enable = true;
    config = builtins.readFile ./frr.conf;
  };
  services.prometheus.exporters.node.listenAddress = addresses.metrics;
  # The exporter binds the loopback identity, which must exist before startup.
  systemd.services.chronyd = {
    requires = [ "systemd-networkd-wait-online@lo.service" ];
    after = [ "systemd-networkd-wait-online@lo.service" ];
  };
  systemd.services.prometheus-node-exporter = {
    requires = [ "systemd-networkd-wait-online@lo.service" ];
    after = [ "systemd-networkd-wait-online@lo.service" ];
  };
  services.openssh.settings = {
    PasswordAuthentication = false;
    KbdInteractiveAuthentication = false;
  };
  services.chrony = {
    enable = true;
    servers = [
      "0.uk.pool.ntp.org"
      "1.uk.pool.ntp.org"
      "2.uk.pool.ntp.org"
      "3.uk.pool.ntp.org"
    ];
    extraConfig = ''
      bindaddress ${addresses.ntp}
      allow 127.0.0.0/8
      allow 10.0.0.0/8
      allow 172.16.0.0/12
      allow 192.168.0.0/16
    '';
  };
  services.journald.settings.Journal.ForwardToSyslog = false;
  services.rsyslogd = {
    enable = true;
    extraParams = [
      "-i"
      "/run/rsyslog/rsyslogd.pid"
    ];
    defaultConfig = ""; # journald remains the local log store
    extraConfig = ''
      $WorkDirectory /var/lib/rsyslog
      module(load="imjournal" StateFile="/var/lib/rsyslog/imjournal.state")
      kern.warning action(type="omfwd" target="10.45.0.2" port="6001"
        protocol="tcp" TCP_Framing="octet-counted" template="RSYSLOG_SyslogProtocol23Format"
        action.resumeRetryCount="-1" queue.type="LinkedList" queue.size="10000")
    '';
  };
  services.avahi = {
    enable = true;
    openFirewall = false;
    settings = {
      server = {
        use-ipv4 = true;
        use-ipv6 = true;
        allow-interfaces = [
          "bond0.20"
          "bond0.40"
          "bond0.1100"
          "bond0.1101"
        ];
      };
      reflector = {
        enable-reflector = true;
        reflect-filters = "_hap._tcp.local,_hap._udp.local,_airplay._tcp.local,_raop._tcp.local,_ipp._tcp.local,_printer._tcp.local,_companion-link._tcp.local,_meshcop._udp.local,_matterc._udp.local,_matter._tcp.local,_matterd._udp.local";
      };
    };
  };
  # Avahi owns mDNS sockets and reflection; resolved handles unicast DNS.
  services.resolved.settings.Resolve.MulticastDNS = false;

  # Roon discovery broadcasts on UDP 9003 and does not cross VLANs. The relay
  # captures and re-injects it through packet sockets, which bypass nftables;
  # unicast replies are routed and filtered normally.
  systemd.services.roon-discovery = {
    description = "Roon discovery relay between Trusted and ROON";
    wantedBy = [ "multi-user.target" ];
    requires = roonReady;
    after = roonReady;
    path = [ pkgs.iproute2 ];
    serviceConfig = (import ./sandbox.nix) // {
      # The start script waits in ExecStart so a missing VIP cannot block boot
      # or activation.
      ExecStart = roonDiscovery;
      DynamicUser = true;
      AmbientCapabilities = [ "CAP_NET_RAW" ];
      CapabilityBoundingSet = [ "CAP_NET_RAW" ];
      RestrictAddressFamilies = [
        "AF_UNIX"
        "AF_INET"
        "AF_NETLINK"
        "AF_PACKET"
      ];
      # The relay binds sink sockets on its interface addresses and discards
      # what they receive.
      SocketBindDeny = "any";
      SocketBindAllow = "ipv4:udp:9003";
      IPAddressDeny = "any";
      MemoryHigh = "64M";
      MemoryMax = "128M";
      TasksMax = 64;
      Restart = "always";
      RestartSec = "2s";
    };
  };

  environment.systemPackages = with pkgs; [
    tcpdump
    conntrack-tools
    wireguard-tools
  ];
}
