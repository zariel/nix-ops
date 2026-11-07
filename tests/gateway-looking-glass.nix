{ pkgs }:
pkgs.testers.runNixOSTest {
  name = "gateway-looking-glass";
  globalTimeout = 240;
  nodes.router = { lib, ... }: {
    imports = [
      ../systems/gateway/firewall.nix
      ../systems/gateway/looking-glass.nix
      ../systems/gateway/high-availability.nix
    ];
    # This fixture assigns the VIP directly; no VRRP election is needed.
    systemd.timers.keepalived-boot-delay.wantedBy = lib.mkForce [ ];
    networking.useDHCP = false;
    networking.interfaces.eth1.ipv4.addresses = [
      {
        address = "10.254.0.0";
        prefixLength = 31;
      }
    ];
    virtualisation.vlans = [ 1 ];
    virtualisation.memorySize = 1536;
    boot.kernel.sysctl = {
      "net.ipv4.ip_forward" = 1;
      "net.ipv6.conf.all.forwarding" = 1;
      "net.ipv4.conf.all.rp_filter" = 0;
      "net.ipv4.conf.default.rp_filter" = 0;
    };
    services.frr = {
      bgpd.enable = true;
      pimd.enable = true;
      pim6d.enable = true;
      config = builtins.readFile ../systems/gateway/frr.conf;
    };
    environment.systemPackages = [
      pkgs.python3
      pkgs.curl
      pkgs.iproute2
      pkgs.conntrack-tools
    ];
  };
  nodes.core = { ... }: {
    networking.useDHCP = false;
    networking.firewall.enable = false;
    virtualisation.vlans = [ 1 ];
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
        ip route 203.0.113.0/24 Null0
        router bgp 65001
         bgp router-id 10.254.0.1
         no bgp ebgp-requires-policy
         neighbor 10.254.0.0 remote-as 65000
         address-family ipv4 unicast
          network 203.0.113.0/24
         exit-address-family
        exit
      '';
    };
  };
  testScript = ''
    import json
    import shlex
    start_all()
    router.wait_for_unit("nftables.service")
    router.wait_for_unit("frr.service")
    core.wait_for_unit("frr.service")
    router.succeed("ip link set eth1 name bond0.3001; ip addr add 10.254.254.1/32 dev lo")

    # Real LAN and WAN traffic provides independent observations of NAT state.
    for namespace, interface, address, peer in (
        ("inside", "bond0.20", "10.1.2.1", "10.1.2.10"),
        ("outside", "wan0", "198.18.0.1", "198.18.0.2"),
    ):
        router.succeed(f"ip netns add {namespace}; ip link add {interface} type veth peer name peer")
        router.succeed(f"ip link set peer netns {namespace}; ip link set {interface} up; ip addr add {address}/24 dev {interface}")
        router.succeed(f"ip -n {namespace} link set lo up; ip -n {namespace} link set peer up; ip -n {namespace} addr add {peer}/24 dev peer")
        router.succeed(f"ip -n {namespace} route add default via {address}")
    router.succeed("ip route add default via 198.18.0.2")
    router.succeed("ip -6 addr add fd74:f571:d3bd:20::1/64 dev bond0.20 nodad; ip -n inside -6 addr add fd74:f571:d3bd:20::10/64 dev peer nodad")
    router.succeed("ip netns exec outside python -m http.server 8080 >/tmp/http.log 2>&1 &")
    router.wait_until_succeeds("ip netns exec inside curl -fsS --max-time 2 http://198.18.0.2:8080")
    router.succeed("ip netns exec inside python -c 'import socket,time; s=socket.create_connection((\"198.18.0.2\",8080)); open(\"/tmp/flow-ready\",\"w\").close(); time.sleep(180)' >/tmp/flow.log 2>&1 &")
    router.wait_until_succeeds("test -e /tmp/flow-ready")
    router.succeed("conntrack -L | grep 'src=10.1.2.10.*dst=198.18.0.1'")
    core.wait_until_succeeds("ip route show 203.0.113.0/24 | grep blackhole")
    try:
        router.wait_until_succeeds("vtysh -c 'show bgp ipv4 unicast 203.0.113.0/24' | grep 65001", timeout=30)
    except Exception:
        print(core.succeed("vtysh -c 'show bgp ipv4 unicast 203.0.113.0/24'; ip route"))
        print(router.succeed("vtysh -c 'show bgp summary'; vtysh -c 'show bgp ipv4 unicast 203.0.113.0/24'; ip route"))
        raise
    router.wait_until_succeeds("ip route show 203.0.113.0/24 | grep 'via 10.254.0.1'")

    # Join groups from a real client instead of fabricating FRR output.
    router.succeed("ip netns exec inside sysctl -w net.ipv4.conf.peer.force_igmp_version=2")
    join = """
    import socket, struct, time
    ipv4 = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    ipv4.setsockopt(socket.IPPROTO_IP, socket.IP_ADD_MEMBERSHIP, socket.inet_aton('239.1.2.3') + socket.inet_aton('10.1.2.10'))
    ipv6 = socket.socket(socket.AF_INET6, socket.SOCK_DGRAM)
    ipv6.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_JOIN_GROUP, socket.inet_pton(socket.AF_INET6, 'ff3e::1234') + struct.pack('@I', socket.if_nametoindex('peer')))
    time.sleep(180)
    """
    import textwrap
    router.succeed("ip netns exec inside python -c " + shlex.quote(textwrap.dedent(join)) + " >/tmp/groups.log 2>&1 &")
    router.wait_until_succeeds("vtysh -c 'show ip igmp groups' | grep 239.1.2.3", timeout=30)
    router.wait_until_succeeds("vtysh -c 'show ipv6 mld groups' | grep ff3e::1234", timeout=30)

    def report(name, target=""):
        output = router.succeed("routerctl --json " + name + (" " + shlex.quote(target) if target else ""))
        data = json.loads(output)
        assert data["report"] == name
        assert not data["incomplete"], data
        assert data["results"] and all(r["returncode"] == 0 for r in data["results"]), data
        return "\n".join(r["output"] for r in data["results"])

    router.succeed("routerctl list | grep bgp-route")
    for name in ("firewall", "nat", "connections", "bgp", "bgp-neighbors", "bgp-prefixes",
                 "routes", "igmp", "mld", "pim", "multicast", "links", "qos", "vrrp"):
        output = report(name)
        assert "Unknown command" not in output and "Operation not permitted" not in output, output

    nat = report("nat")
    assert "masquerade" in nat and "src=10.1.2.10" in nat and "dst=198.18.0.1" in nat
    assert "packets=" in nat and "bytes=" in nat
    kernel = json.loads(router.succeed("nft -j list chain inet gateway postrouting"))
    rules = [entry["rule"] for entry in kernel["nftables"] if "rule" in entry]
    assert any(expression.get("counter", {}).get("packets", 0) > 0 for rule in rules for expression in rule["expr"])
    assert "239.1.2.3" in report("igmp")
    assert "ff3e::1234" in report("mld")
    assert "203.0.113.0/24" in report("bgp-route", "203.0.113.0/24")
    assert "Established" in report("bgp-neighbors", "10.254.0.1")
    assert "10.254.0.1" in report("route", "203.0.113.10")
    assert "fd74:f571:d3bd:20::" in report("route", "fd74:f571:d3bd:20::10")

    # Invalid lookups must fail before native commands run; reports never clear state.
    before = router.succeed("nft -s -j list ruleset")
    for command in ("routerctl clear", "routerctl bgp-route", "routerctl nat unexpected",
                    "routerctl bgp-route '10.0.0.1; touch /tmp/injected'",
                    "routerctl bgp-neighbors '10.254.0.1 clear bgp *'"):
        router.fail(command)
    assert router.succeed("nft -s -j list ruleset") == before
    router.fail("test -e /tmp/injected")
    router.succeed("conntrack -L | grep 'src=10.1.2.10.*dst=198.18.0.1'")

    router.succeed("systemctl stop frr")
    router.fail("routerctl --json bgp >/tmp/unavailable.json")
    unavailable = json.loads(router.succeed("cat /tmp/unavailable.json"))
    assert unavailable["incomplete"] and unavailable["results"][0]["returncode"] != 0
  '';
}
