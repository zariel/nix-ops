{ pkgs, ... }:
pkgs.testers.runNixOSTest {
  name = "gateway-apps";
  globalTimeout = 300;
  nodes.router = { ... }: {
    imports = [
      ../systems/gateway/firewall.nix
      ../systems/gateway/apps.nix
    ];
    systemd.network.wait-online.enable = false;
    containers.matchbox.config.systemd.services.hold-ready = {
      unitConfig.ConditionPathExists = "!/var/lib/matchbox/network-test-released";
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${pkgs.coreutils}/bin/sleep infinity";
      };
    };
    virtualisation.memorySize = 3072;
    virtualisation.vlans = [ 1 ];
    networking.useDHCP = false;
    networking.interfaces.eth1.ipv4.addresses = [
      {
        address = "10.254.0.0";
        prefixLength = 31;
      }
    ];
    boot.kernel.sysctl."net.ipv4.ip_forward" = 1;
    services.frr = {
      bgpd.enable = true;
      config = builtins.readFile ../systems/gateway/frr.conf;
    };
    systemd.tmpfiles.rules = [
      "d /var/lib/gateway/matchbox/assets 0755 root root -"
      "f /var/lib/gateway/matchbox/assets/probe 0644 root root - gateway-app-probe"
    ];
    environment.systemPackages = [ pkgs.curl ];
  };
  nodes.fabric = { ... }: {
    virtualisation.vlans = [ 1 ];
    networking.useDHCP = false;
    networking.firewall.enable = false;
    networking.interfaces.eth1.ipv4.addresses = [
      {
        address = "10.254.0.1";
        prefixLength = 31;
      }
    ];
    environment.systemPackages = [ pkgs.curl ];
    services.frr = {
      bgpd.enable = true;
      config = ''
        frr defaults traditional
        router bgp 65001
         bgp router-id 10.254.0.1
         no bgp ebgp-requires-policy
         neighbor 10.254.0.0 remote-as 65000
      '';
    };
  };
  testScript = ''
    import json
    start_all()
    router.wait_for_unit("frr.service")
    fabric.wait_for_unit("frr.service")
    router.succeed("ip link set eth1 name bond0.3001")
    # Networking must work while the container is still initializing.
    fabric.wait_until_succeeds("ip route show 10.5.0.8/32 | grep 'via 10.254.0.0'")
    router.succeed("systemctl show container@matchbox.service -p ActiveState --value | grep -x activating")
    router.succeed("touch /var/lib/gateway/matchbox/network-test-released")
    router.succeed("nixos-container run matchbox -- systemctl stop hold-ready")
    router.wait_for_unit("container@matchbox.service")
    router.wait_until_succeeds("curl -fsS --max-time 2 http://10.5.0.8/assets/probe | grep gateway-app-probe")
    router.succeed("ip route show 10.5.0.8/32 | grep 'dev ve-matchbox'")
    router.fail("ip -4 address show | grep 'inet 10.5.0.8/'")
    fabric.wait_until_succeeds("ip route show 10.5.0.8/32 | grep 'via 10.254.0.0'")
    routes = json.loads(fabric.succeed("vtysh -c 'show bgp ipv4 unicast json'"))["routes"]
    assert "10.5.0.8/32" in routes
    assert "10.5.0.10/32" not in routes
    assert "10.5.0.11/32" not in routes
    assert "10.5.0.0/24" not in routes

    # Export only service /32 routes, not unrelated kernel routes or subnets.
    router.succeed("ip route add 198.18.0.8/32 dev ve-matchbox; ip route add 10.5.0.128/25 dev ve-matchbox; ip route add 10.5.0.9/32 dev ve-matchbox")
    router.succeed("systemctl reload frr")
    fabric.wait_until_succeeds("ip route show 10.5.0.9/32 | grep 'via 10.254.0.0'")
    routes = json.loads(fabric.succeed("vtysh -c 'show bgp ipv4 unicast json'"))["routes"]
    assert "198.18.0.8/32" not in routes
    assert "10.5.0.128/25" not in routes

    router.succeed("systemctl stop container@matchbox.service")
    router.fail("ip link show ve-matchbox")
    fabric.wait_until_fails("ip route show 10.5.0.8/32 | grep 'via 10.254.0.0'")
    router.succeed("systemctl start container@matchbox.service")
    router.wait_until_succeeds("curl -fsS --max-time 2 http://10.5.0.8/assets/probe | grep gateway-app-probe")
    fabric.wait_until_succeeds("ip route show 10.5.0.8/32 | grep 'via 10.254.0.0'")
  '';
}
