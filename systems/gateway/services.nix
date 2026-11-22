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
  # mDNS reflection is granted per service between VLAN pairs. Each grant
  # exposes services advertised on its device VLANs to clients on its client
  # VLANs; queries cross towards the devices and answers come back, and
  # nothing is reflected the other way.
  threadMatter = [
    "bond0.20"
    "bond0.40"
    "bond0.1100"
    "bond0.1101"
  ];
  discovery = [
    {
      # Apple Home hubs, iPhones and Macs on Trusted control HomeKit
      # accessories and AirPlay receivers on IoT. IoT may open only AirPlay
      # return connections to Trusted, so it has no use for Trusted's services.
      clients = [ "bond0.20" ];
      devices = [ "bond0.40" ];
      services = [
        "_hap._tcp"
        "_hap._udp"
        "_airplay._tcp"
        "_raop._tcp"
        "_ipp._tcp"
        "_printer._tcp"
        "_companion-link._tcp"
      ];
    }
    {
      # Thread border routers, Matter controllers and Matter devices find each
      # other across Trusted, IoT and the OTBR and controller VLANs.
      clients = threadMatter;
      devices = threadMatter;
      services = [
        "_meshcop._udp"
        "_matter._tcp"
        "_matterc._udp"
        "_matterd._udp"
      ];
    }
    {
      # The BluOS app on Trusted finds the Bluesound players on ROON. Their
      # Spotify, TIDAL and Qobuz Connect and AirPlay advertisements stay on ROON.
      clients = [ "bond0.20" ];
      devices = [ "bond0.60" ];
      services = [ "_musc._tcp" ];
    }
  ];
  ipv6Only = [
    "bond0.1100"
    "bond0.1101"
  ];
  # netflector takes one mDNS entry per direction, so grants sharing a client
  # and device VLAN merge their services.
  reflectors = lib.foldl' (
    entries:
    {
      clients,
      devices,
      services,
    }:
    lib.foldl' (
      entries: client:
      lib.foldl' (
        entries: device:
        let
          name = "${client}-to-${device}";
        in
        if client == device then
          entries
        else
          entries
          // {
            ${name} = {
              source_if = client;
              target_if = device;
              mdns = true;
              mdns_services = lib.unique ((entries.${name}.mdns_services or [ ]) ++ services);
              address_family =
                if builtins.elem client ipv6Only || builtins.elem device ipv6Only then "ipv6" else "default";
            };
          }
      ) entries devices
    ) entries clients
  ) { } discovery;
  netflector = pkgs.callPackage ../../packages/netflector/package.nix { };
  # netflector exits if an interface is absent at startup; it follows later
  # address changes itself.
  reflectorLinks = map (interface: "sys-subsystem-net-devices-${interface}.device") (
    lib.unique (lib.concatMap ({ clients, devices, ... }: clients ++ devices) discovery)
  );
  # Parsing needs no interfaces, so conflicting entries fail the build.
  reflectorConfig =
    pkgs.runCommand "netflector.toml"
      {
        config = (pkgs.formats.toml { }).generate "netflector.toml" { inherit reflectors; };
      }
      ''
        ${lib.getExe netflector} --check-config "$config"
        cp "$config" "$out"
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
  # netflector captures and re-emits mDNS through packet sockets, which bypass
  # nftables; it binds no IP port.
  systemd.services.mdns-reflector = {
    description = "mDNS reflection between VLAN pairs";
    wants = reflectorLinks;
    after = reflectorLinks;
    wantedBy = [ "multi-user.target" ];
    serviceConfig = (import ./sandbox.nix) // {
      ExecStart = "${lib.getExe netflector} ${reflectorConfig}";
      DynamicUser = true;
      AmbientCapabilities = [ "CAP_NET_RAW" ];
      CapabilityBoundingSet = [ "CAP_NET_RAW" ];
      RestrictAddressFamilies = [
        "AF_UNIX"
        "AF_INET"
        "AF_INET6"
        "AF_NETLINK"
        "AF_PACKET"
      ];
      SocketBindDeny = "any";
      IPAddressDeny = "any";
      MemoryHigh = "64M";
      MemoryMax = "128M";
      TasksMax = 64;
      Restart = "always";
      RestartSec = "2s";
    };
  };
  # Resolved must not answer or join mDNS on the reflected VLANs.
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
