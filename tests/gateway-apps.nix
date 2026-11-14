{ pkgs, ... }:
pkgs.testers.runNixOSTest {
  name = "gateway-apps";
  globalTimeout = 240;
  nodes.router = {
    imports = [
      ../systems/gateway/hardening.nix
      ../systems/gateway/firewall.nix
      ../systems/gateway/apps.nix
    ];
    systemd.network.wait-online.enable = false;
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
      "f /var/lib/gateway/matchbox/assets/probe 0644 root root - gateway-app-probe"
    ];
    environment.systemPackages = [
      pkgs.curl
      pkgs.python3
      pkgs.util-linux
    ];
  };
  nodes.fabric = {
    virtualisation.vlans = [ 1 ];
    networking.useDHCP = false;
    networking.firewall.enable = false;
    networking.interfaces.eth1.ipv4.addresses = [
      {
        address = "10.254.0.1";
        prefixLength = 31;
      }
    ];
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
    start_all()
    router.wait_for_unit("frr.service")
    router.wait_for_unit("matchbox.service")
    fabric.wait_for_unit("frr.service")
    router.succeed("ip link set eth1 name bond0.3001")
    fabric.wait_until_succeeds("ip route show 10.5.0.0/26 | grep 'via 10.254.0.0'")
    router.succeed("ip -4 address show lo | grep '10.5.0.8/32'")
    router.wait_until_succeeds("curl -fsS --max-time 2 http://10.5.0.8/assets/probe | grep gateway-app-probe")
    router.fail("systemctl list-units --all --no-legend | grep container@")

    for zone, interface, gateway_address, address in (
        ("trusted", "bond0.20", "10.1.2.1", "10.1.2.11"),
        ("servers", "bond0.10", "10.1.1.1", "10.1.1.31"),
        ("iot", "bond0.40", "10.1.3.1", "10.1.3.14"),
        ("lan", "bond0.100", "10.1.0.1", "10.1.0.22"),
        ("guest", "bond0.30", "192.168.2.1", "192.168.2.11"),
        ("wan", "wan0", "198.18.0.1", "198.18.0.2"),
    ):
        router.succeed(f"ip netns add {zone}; ip link add {interface} type veth peer name peer; ip link set peer netns {zone}; ip link set {interface} up")
        router.succeed(f"ip addr add {gateway_address}/24 dev {interface}; ip -n {zone} link set lo up; ip -n {zone} link set peer up; ip -n {zone} addr add {address}/24 dev peer; ip -n {zone} route add default via {gateway_address}")
        command = f"ip netns exec {zone} curl -fsS --max-time 2 http://10.5.0.8/assets/probe"
        (router.fail if zone in ("guest", "wan") else router.succeed)(command)

    # Even a process using the service identity cannot originate a WAN session.
    router.succeed("ip route replace default via 198.18.0.2")
    router.succeed("ip netns exec wan python -m http.server 443 --bind 198.18.0.2 >/tmp/wan.log 2>&1 &")
    router.wait_until_succeeds("curl -fsS --max-time 2 http://198.18.0.2:443")
    router.fail("runuser -u matchbox -- curl -fsS --max-time 2 http://198.18.0.2:443")
    pid = router.succeed("systemctl show matchbox -p MainPID --value").strip()
    router.fail(f"nsenter -t {pid} -m -- touch /var/lib/matchbox/forbidden")

    # The host block survives an application restart and individual address loss.
    router.succeed("systemctl stop matchbox")
    fabric.succeed("ip route show 10.5.0.0/26 | grep 'via 10.254.0.0'")
    router.succeed("systemctl start matchbox")
    router.wait_until_succeeds("curl -fsS --max-time 2 http://10.5.0.8/assets/probe | grep gateway-app-probe")
    router.succeed("ip addr del 10.5.0.8/32 dev lo")
    fabric.succeed("ip route show 10.5.0.0/26 | grep 'via 10.254.0.0'")
    router.succeed("networkctl reconfigure lo")
    router.wait_until_succeeds("curl -fsS --max-time 2 http://10.5.0.8/assets/probe | grep gateway-app-probe")

    # Unallocated addresses terminate here; the summary is not a connected LAN.
    router.succeed("ip route show 10.5.0.0/26 | grep '^unreachable '")
    router.fail("ip route get 10.5.0.62")
    fabric.succeed("ip route show 10.5.0.0/26 | grep 'via 10.254.0.0'")
    fabric.succeed("test -z \"$(ip route show 10.5.0.8/32)\"")
    # Removing the owned summary withdraws it, even though local /32s remain.
    router.succeed("ip route del unreachable 10.5.0.0/26")
    fabric.wait_until_fails("ip route show 10.5.0.0/26 | grep 'via 10.254.0.0'")
    router.succeed("networkctl reconfigure lo")
    fabric.wait_until_succeeds("ip route show 10.5.0.0/26 | grep 'via 10.254.0.0'")
  '';
}
