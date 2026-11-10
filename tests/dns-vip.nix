{ pkgs }:

pkgs.testers.runNixOSTest {
  name = "dns-vip";

  defaults = {
    networking.useNetworkd = true;
    networking.firewall.enable = false;
    virtualisation.memorySize = 768;
  };

  nodes = {
    dns =
      { lib, ... }:
      {
        imports = [ ../roles/dnsVip ];

        networking.interfaces.eth1.ipv4.addresses = lib.mkForce [
          {
            address = "10.254.53.0";
            prefixLength = 31;
          }
        ];

        services.dnsVip = {
          enable = true;
          nodeIp = "10.254.53.0";
          bgpPeerIp = "10.254.53.1";
        };
        services.dnsHealthcheck = {
          checkInterval = 1;
          failureThreshold = 2;
          successThreshold = 2;
        };

        # Keep the filtering health check while making the VM independent of
        # external blocklist downloads.
        services.blocky.settings.blocking = {
          denylists = {
            ads = lib.mkForce [
              (pkgs.writeText "dns-vip-test-denylist" "blocky-healthcheck.invalid\n")
            ];
            fakenews = lib.mkForce [ ];
            gambling = lib.mkForce [ ];
          };
          allowlists.ads = lib.mkForce [ ];
        };

        specialisation = {
          overlap.configuration.services.dnsVip.ipv4Addresses = lib.mkForce [
            "172.53.53.53"
            "10.254.253.53"
          ];
          replacement.configuration.services.dnsVip.ipv4Addresses = lib.mkForce [ "10.254.253.53" ];
        };
      };

    client =
      { lib, ... }:
      {
        networking.interfaces.eth1.ipv4.addresses = lib.mkForce [
          {
            address = "10.254.53.1";
            prefixLength = 31;
          }
        ];

        environment.systemPackages = [ pkgs.dnsutils ];
        services.bird = {
          enable = true;
          config = ''
            router id 10.254.53.1;
            protocol device {}
            protocol kernel {
              ipv4 { import none; export all; };
            }
            protocol bgp dns {
              local as 65001;
              neighbor 10.254.53.0 as 65110;
              ipv4 { import all; export none; };
            }
          '';
        };
      };
  };

  testScript = ''
    start_all()
    dns.wait_for_unit("dns-healthcheck.service")
    client.wait_for_unit("bird.service")
    booted_system = dns.succeed("readlink -f /run/current-system").strip()

    def query(address, tcp=False):
        transport = "+tcp" if tcp else "+notcp +ignore"
        return f"dig @{address} gateway.cbannister.casa A +short +tries=1 +time=2 {transport}"

    def check_vip(address):
        dns.succeed(f"ip -4 -o address show dev dnsvip | grep -F 'inet {address}/32 '")
        client.wait_until_succeeds(f"ip -4 route show {address}/32 | grep -F 'via 10.254.53.0'")
        for tcp in [False, True]:
            client.wait_until_succeeds(f"test \"$({query(address, tcp)})\" = 10.254.254.1")

    with subtest("Default VIP remains usable"):
        check_vip("172.53.53.53")

    with subtest("Adding a VIP serves both addresses"):
        dns.succeed(f"{booted_system}/specialisation/overlap/bin/switch-to-configuration test")
        check_vip("172.53.53.53")
        check_vip("10.254.253.53")

    with subtest("Node failure withdraws every VIP and recovery restores them"):
        dns.succeed("systemctl stop bind.service")
        for address in ["172.53.53.53", "10.254.253.53"]:
            client.wait_until_succeeds(f"test -z \"$(ip -4 route show {address}/32)\"")
        dns.succeed("systemctl start bind.service dnsdist.service")
        check_vip("172.53.53.53")
        check_vip("10.254.253.53")

    with subtest("Restarting the frontend preserves both listeners"):
        dns.succeed("systemctl restart dnsdist.service")
        check_vip("172.53.53.53")
        check_vip("10.254.253.53")

    with subtest("Removing the old VIP leaves only the replacement"):
        dns.succeed(f"{booted_system}/specialisation/replacement/bin/switch-to-configuration test")
        check_vip("10.254.253.53")
        dns.fail("ip -4 -o address show dev dnsvip | grep -F 'inet 172.53.53.53/32 '")
        client.wait_until_succeeds('test -z "$(ip -4 route show 172.53.53.53/32)"')
        dns.fail("ss -H -lntu | grep -F '172.53.53.53:53 '")

    with subtest("Reapplying the replacement configuration is idempotent"):
        dns.succeed(f"{booted_system}/specialisation/replacement/bin/switch-to-configuration test")
        check_vip("10.254.253.53")
        client.succeed('test -z "$(ip -4 route show 172.53.53.53/32)"')
  '';
}
