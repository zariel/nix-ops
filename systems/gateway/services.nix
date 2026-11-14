{ pkgs, ... }:
{
  services.frr = {
    bgpd.enable = true;
    pimd.enable = true;
    pim6d.enable = true;
    config = builtins.readFile ./frr.conf;
  };
  services.prometheus.exporters.node.listenAddress = "10.254.254.1";
  # The exporter binds the loopback identity, which must exist before startup.
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
      bindaddress 10.254.254.1
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
  environment.systemPackages = with pkgs; [
    tcpdump
    conntrack-tools
    wireguard-tools
  ];
}
