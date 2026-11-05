{ pkgs }:
pkgs.testers.runNixOSTest {
  name = "gateway-spamhaus";
  globalTimeout = 240;
  nodes.router = { lib, ... }: {
    imports = [
      ../systems/gateway/firewall.nix
      ../systems/gateway/spamhaus.nix
    ];
    networking.useDHCP = false;
    boot.kernel.sysctl = {
      "net.ipv4.ip_forward" = 1;
      "net.ipv6.conf.all.forwarding" = 1;
      "net.ipv4.conf.all.rp_filter" = 0;
      "net.ipv4.conf.default.rp_filter" = 0;
    };
    # Updates use a local HTTP fixture, never the live Spamhaus feeds.
    systemd.services.spamhaus-drop-update = {
      wantedBy = lib.mkForce [ ];
      unitConfig.StartLimitIntervalSec = 0;
      environment.SPAMHAUS_URL_BASE = lib.mkForce "http://127.0.0.1:8088";
    };
    systemd.timers.spamhaus-drop-update.wantedBy = lib.mkForce [ ];
    systemd.services.feed-fixture = {
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        ExecStart = "${pkgs.python3}/bin/python3 -m http.server 8088 --bind 127.0.0.1 --directory /var/lib/feed-fixture";
        StateDirectory = "feed-fixture";
      };
    };
    environment.systemPackages = [
      pkgs.curl
      pkgs.python3
      pkgs.iproute2
      pkgs.iputils
    ];
  };
  testScript = ''
    import json
    import shlex
    import textwrap

    router.start(allow_reboot=True)
    router.wait_for_unit("spamhaus-drop.service")
    router.wait_for_unit("nftables.service")
    router.wait_for_open_port(8088)

    def feed(version, entries):
        records = [dict(cidr=entry, sblid="SBL1", rir="test") for entry in entries]
        records.append(dict(type="metadata", records=len(entries), timestamp=1793897042,
                            copyright="(c) 2026 The Spamhaus Project SLU"))
        router.succeed("printf %s " + shlex.quote("\n".join(map(json.dumps, records)))
                       + f" > /var/lib/feed-fixture/drop_v{version}.json")

    def update(success=True):
        router.succeed("touch -d '2 hours ago' /var/lib/spamhaus-drop/last-attempt")
        command = "systemctl start spamhaus-drop-update.service"
        (router.succeed if success else router.fail)(command)

    def sets():
        result = []
        for version in (4, 6):
            data = json.loads(router.succeed(f"nft -j list set inet spamhaus_drop drop_v{version}"))
            result.append(next(entry["set"]["elem"] for entry in data["nftables"] if "set" in entry))
        return result

    def allow_probes():
        # Make the zone policy permit these probes so a DROP rule must stop them.
        for chain in ("input", "forward"):
            router.succeed(f"nft insert rule inet gateway {chain} iifname wan0 tcp dport 8080 accept")
            router.succeed(f"nft insert rule inet gateway {chain} iifname wan0 udp dport 8082 accept")

    receiver = """
    import socket
    import sys
    from pathlib import Path

    sock = socket.socket(socket.AF_INET6, socket.SOCK_DGRAM)
    sock.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 0)
    sock.bind(("::", 8082))
    Path(sys.argv[1]).touch()
    while True:
        data, _ = sock.recvfrom(1024)
        with open(sys.argv[1], "a") as log:
            log.write(data.decode() + "\\n")
    """
    for name, interface, address, address6, peer, peer6 in (
        ("wan", "wan0", "198.18.0.1", "2001:db8:ffff::1", "198.18.0.2", "2001:db8:ffff::2"),
        ("trusted", "bond0.20", "10.1.2.1", "fd00:20::1", "10.1.2.60", "fd00:20::2"),
    ):
        router.succeed(f"ip netns add {name}; ip link add {interface} type veth peer name peer")
        router.succeed(f"ip link set peer netns {name}; ip link set {interface} up")
        router.succeed(f"ip addr add {address}/24 dev {interface}; ip -6 addr add {address6}/64 dev {interface} nodad")
        router.succeed(f"ip -n {name} link set lo up; ip -n {name} link set peer up")
        router.succeed(f"ip -n {name} addr add {peer}/24 dev peer; ip -n {name} -6 addr add {peer6}/64 dev peer nodad")
        router.succeed(f"ip -n {name} route add default via {address}; ip -n {name} -6 route add default via {address6}")
        router.succeed(f"ip netns exec {name} python -m http.server 8080 --bind :: >/tmp/{name}-http.log 2>&1 &")

    for address in ("192.0.2.2/32", "198.51.100.2/32"):
        router.succeed(f"ip -n wan addr add {address} dev lo")
    for address in ("2001:db8:bad::2/128", "2001:db8:feed::2/128"):
        router.succeed(f"ip -n wan -6 addr add {address} dev lo nodad")
    router.succeed("ip route add 192.0.2.0/24 via 198.18.0.2; ip route add 198.51.100.0/24 via 198.18.0.2")
    router.succeed("ip -6 route add 2001:db8:bad::/64 via 2001:db8:ffff::2; ip -6 route add 2001:db8:feed::/64 via 2001:db8:ffff::2")
    router.succeed("python -m http.server 8080 --bind :: >/tmp/router-http.log 2>&1 &")
    allow_probes()

    for namespace in ("wan", "trusted", "router"):
        prefix = f"ip netns exec {namespace} " if namespace != "router" else ""
        router.succeed(prefix + "python -c " + shlex.quote(textwrap.dedent(receiver))
                       + f" /tmp/{namespace}-udp >/tmp/{namespace}-udp.log 2>&1 &")
        router.wait_until_succeeds(f"test -e /tmp/{namespace}-udp")

    curl = "curl --noproxy '*' -gfsS --connect-timeout 1 --max-time 2 "
    def url(address):
        host = f"[{address}]" if ":" in address else address
        return f"http://{host}:8080"

    probes = []
    controls = []
    datagrams = []
    for remote, good, gateway, lan in (
        ("192.0.2.2", "198.51.100.2", "198.18.0.1", "10.1.2.60"),
        ("2001:db8:bad::2", "2001:db8:feed::2", "2001:db8:ffff::1", "fd00:20::2"),
    ):
        # Router and forwarded traffic, in both directions, for each family.
        probes.extend([
            curl + url(remote),
            "ip netns exec trusted " + curl + url(remote),
            "ip netns exec wan " + curl + f"--interface {remote} " + url(gateway),
            "ip netns exec wan " + curl + f"--interface {remote} " + url(lan),
        ])
        controls.extend([
            curl + url(good),
            "ip netns exec trusted " + curl + url(good),
        ])
        datagrams.extend([
            ("", None, remote, "wan"),
            ("ip netns exec trusted ", None, remote, "wan"),
            ("ip netns exec wan ", remote, gateway, "router"),
            ("ip netns exec wan ", remote, lan, "trusted"),
        ])
    for probe in probes + controls:
        router.wait_until_succeeds(probe, timeout=15)

    def send_datagrams(batch):
        for index, (prefix, source, target, _) in enumerate(datagrams):
            family = "AF_INET6" if ":" in target else "AF_INET"
            sender = f"import socket; s=socket.socket(socket.{family},socket.SOCK_DGRAM); "
            if source:
                sender += f"s.bind(({source!r}, 0)); "
            send = f"s.sendto(b'{batch}-{index}', ({target!r}, 8082))"
            if batch == "blocked" and not prefix:
                # A local output drop may report EPERM directly to sendto().
                sender += f"\ntry: {send}\nexcept PermissionError: pass"
            else:
                sender += send
            router.succeed(prefix + "python -c " + shlex.quote(sender))

    # One-way delivery distinguishes blocking each direction from dropping replies.
    send_datagrams("before")
    for index, (_, _, _, destination) in enumerate(datagrams):
        router.wait_until_succeeds(f"grep -qx before-{index} /tmp/{destination}-udp")

    # Leave an established connection open across the list update.
    connection_probe = """
    import socket
    import time
    from pathlib import Path

    connection = socket.create_connection(("192.0.2.2", 8080))
    connection.settimeout(2)
    Path("/tmp/connected").touch()
    while not Path("/tmp/send").exists():
        time.sleep(0.1)
    connection.sendall(b"GET / HTTP/1.0\\r\\n\\r\\n")
    try:
        connection.recv(4096)
    except TimeoutError:
        Path("/tmp/blocked").touch()
    """
    router.succeed("python -c " + shlex.quote(textwrap.dedent(connection_probe)) + " >/tmp/connection.log 2>&1 &")
    router.wait_until_succeeds("test -e /tmp/connected")

    feed(4, ["192.0.2.0/24"])
    feed(6, ["2001:db8:bad::/64"])
    update()
    installed = sets()
    saved = router.succeed("cat /var/lib/spamhaus-drop/feeds.json")
    send_datagrams("blocked")
    for probe in probes:
        router.fail(probe)
    for probe in controls:
        router.succeed(probe)
    for destination in ("wan", "trusted", "router"):
        router.fail(f"grep -q blocked /tmp/{destination}-udp")
    router.succeed("touch /tmp/send")
    router.wait_until_succeeds("test -e /tmp/blocked")

    # Listed addresses on an internal link must remain reachable.
    router.succeed("ip -n trusted addr add 192.0.2.3/32 dev lo; ip route add 192.0.2.3/32 via 10.1.2.60")
    router.succeed("ip -n trusted -6 addr add 2001:db8:bad::3/128 dev lo nodad; ip -6 route add 2001:db8:bad::3/128 via fd00:20::2")
    router.succeed("ping -c 1 -W 2 192.0.2.3")
    router.succeed("ping -6 -c 1 -W 2 2001:db8:bad::3")

    # A valid changed IPv4 feed must not take effect if IPv6 is invalid.
    feed(4, ["198.51.100.0/24"])
    for invalid in ("not json", '{"cidr":"::/0"}',
                    '{"type":"metadata","records":0}',
                    '{"cidr":"2001:db8:bad::/64"}\n{"type":"metadata","records":2}',
                    '{"cidr":"192.0.2.0/24"}\n{"type":"metadata","records":1}',
                    '{"cidr":"::/0"}\n{"type":"metadata","records":1}'):
        router.succeed("printf %s " + shlex.quote(invalid) + " > /var/lib/feed-fixture/drop_v6.json")
        update(success=False)
        assert sets() == installed
        assert router.succeed("cat /var/lib/spamhaus-drop/feeds.json") == saved
    router.succeed("mv /var/lib/feed-fixture/drop_v6.json /var/lib/feed-fixture/missing")
    update(success=False)
    assert sets() == installed
    assert router.succeed("cat /var/lib/spamhaus-drop/feeds.json") == saved

    # Respect the upstream fetch limit even when a timer follows boot immediately.
    router.succeed("systemctl start spamhaus-drop-update.service")
    assert sets() == installed

    router.succeed("systemctl reload nftables")
    assert sets() == installed
    allow_probes()
    for probe in probes:
        router.fail(probe)

    # Successful refresh removes delisted ranges, and repeated loads converge.
    feed(6, ["2001:db8:feed::/64"])
    update()
    replacement = sets()
    for probe in probes:
        router.succeed(probe)
    for probe in controls:
        router.fail(probe)
    router.succeed("systemctl reload spamhaus-drop; systemctl restart spamhaus-drop")
    assert sets() == replacement

    router.reboot()
    router.wait_for_unit("spamhaus-drop.service")
    assert sets() == replacement
  '';
}
