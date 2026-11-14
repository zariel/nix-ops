{ pkgs, sopsModule }:
let
  keys = import (pkgs.path + "/nixos/tests/ssh-keys.nix") pkgs;
  collector = pkgs.writeText "gateway-log-collector.py" ''
    import socket
    server = socket.socket()
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    server.bind(("10.45.0.2", 6001))
    server.listen()
    while True:
        connection, _ = server.accept()
        with connection:
            while data := connection.recv(65536):
                with open("/run/log-collector/messages", "ab") as output:
                    output.write(data)
  '';
  build = pkgs.writeText "gateway-build.nix" ''
    derivation {
      name = "gateway-sandbox-check";
      system = "x86_64-linux";
      builder = (builtins.storePath "${pkgs.busybox}") + "/bin/sh";
      args = [ "-c" "echo sandbox-build > $out" ];
    }
  '';
in
pkgs.testers.runNixOSTest {
  name = "gateway-hardening";
  globalTimeout = 360;
  nodes = {
    gateway = { lib, ... }: {
      imports = [
        sopsModule
        ../roles/base
        ../systems/gateway
        ./dhcp-dns-secret.nix
      ];
      disabledModules = [ ../systems/gateway/hardware.nix ];
      virtualisation.memorySize = 3072;
      virtualisation.vlans = [
        1
        2
      ];
      systemd.network.links = {
        "10-lan0".matchConfig = lib.mkForce { OriginalName = "eth1"; };
        "10-wan0".matchConfig = lib.mkForce { OriginalName = "eth2"; };
      };
      systemd.network.netdevs."20-bond0".bondConfig = lib.mkForce {
        Mode = "active-backup";
        MIIMonitorSec = "100ms";
      };
      sops.secrets.gateway-wireguard = {
        sopsFile = lib.mkForce ./fixtures/dhcp-dns-secret.yaml;
        key = lib.mkForce "tsig_secret";
      };
      systemd.services.spamhaus-drop-update.wantedBy = lib.mkForce [ ];
      systemd.timers.spamhaus-drop-update.wantedBy = lib.mkForce [ ];
      users.users.chris.openssh.authorizedKeys.keys = [ keys.snakeOilEd25519PublicKey ];
      environment.systemPackages = [
        pkgs.curl
        pkgs.python3
        pkgs.util-linux
      ];
      systemd.tmpfiles.rules = [
        "f /var/lib/gateway/matchbox/assets/probe 0644 root root - hardened-boot-assets"
        "f /var/lib/tftpboot/probe 0644 root root - hardened-tftp"
      ];
      environment.etc."gateway-build.nix".source = build;
    };
    lan = { ... }: {
      virtualisation.vlans = [ 1 ];
      networking.useDHCP = false;
      networking.firewall.enable = false;
      systemd.network = {
        enable = true;
        wait-online.enable = false;
        netdevs."20-core" = {
          netdevConfig = {
            Name = "core";
            Kind = "vlan";
          };
          vlanConfig.Id = 3001;
        };
        networks = {
          "10-eth1" = {
            matchConfig.Name = "eth1";
            vlan = [ "core" ];
          };
          "20-core" = {
            matchConfig.Name = "core";
            address = [ "10.254.0.1/31" ];
          };
          "10-loopback" = {
            matchConfig.Name = "lo";
            address = [ "10.45.0.2/32" ];
          };
        };
      };
      services.frr = {
        bgpd.enable = true;
        config = ''
          frr defaults traditional
          router bgp 65001
           bgp router-id 10.254.0.1
           no bgp ebgp-requires-policy
           neighbor 10.254.0.0 remote-as 65000
           address-family ipv4 unicast
            network 10.45.0.2/32
           exit-address-family
          exit
        '';
      };
      systemd.services.log-collector = {
        wantedBy = [ "multi-user.target" ];
        after = [ "systemd-networkd-wait-online@lo.service" ];
        requires = [ "systemd-networkd-wait-online@lo.service" ];
        serviceConfig = {
          ExecStart = "${pkgs.python3}/bin/python3 ${collector}";
          RuntimeDirectory = "log-collector";
        };
      };
      environment.systemPackages = [
        pkgs.curl
        pkgs.python3
        pkgs.busybox
        pkgs.openssh
      ];
      environment.etc."gateway-dhcp.py".source = ./gateway-dhcp.py;
      environment.etc."test-ssh-key" = {
        source = keys.snakeOilEd25519PrivateKey;
        mode = "0600";
      };
    };
    isp = { lib, ... }: {
      virtualisation.vlans = [ 2 ];
      networking.useDHCP = false;
      networking.firewall.enable = false;
      networking.interfaces.eth1.ipv4.addresses = lib.mkForce [
        {
          address = "198.18.0.1";
          prefixLength = 24;
        }
      ];
      services.dnsmasq = {
        enable = true;
        settings = {
          interface = "eth1";
          bind-interfaces = true;
          dhcp-range = "198.18.0.100,198.18.0.200,255.255.255.0,1h";
          dhcp-option = [ "option:router,198.18.0.1" ];
        };
      };
    };
  };
  testScript = builtins.readFile ./gateway-hardening.py;
}
