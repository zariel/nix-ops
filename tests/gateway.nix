{ pkgs, sopsModule, ... }:
pkgs.testers.runNixOSTest {
  name = "gateway-policy";
  globalTimeout = 360;
  nodes.router = { lib, ... }: {
    imports = [
      sopsModule
      ./dhcp-dns-secret.nix
      ../systems/gateway/hardening.nix
      ../systems/gateway/firewall.nix
      ../systems/gateway/dhcp.nix
    ];
    # Client links are created by the test after boot.
    systemd.services.kea-dhcp4-server.wantedBy = lib.mkForce [ ];
    environment.etc."gateway-dhcp.py".source = ./gateway-dhcp.py;
    environment.etc."gateway-udp.py".source = ./gateway-udp.py;
    networking.useDHCP = false;
    # Packet fixtures own mDNS sockets.
    services.resolved.settings.Resolve.MulticastDNS = false;
    boot.kernel.sysctl."net.ipv4.ip_forward" = 1;
    boot.kernel.sysctl."net.ipv6.conf.all.forwarding" = 1;
    boot.kernel.sysctl."net.ipv4.conf.all.rp_filter" = 0;
    services.frr = {
      bgpd.enable = true;
      pimd.enable = true;
      pim6d.enable = true;
      config = builtins.readFile ../systems/gateway/frr.conf;
    };
    environment.systemPackages = [
      pkgs.iproute2
      pkgs.iputils
      pkgs.curl
      pkgs.python3
      pkgs.busybox
      pkgs.conntrack-tools
    ];
    virtualisation.memorySize = 1536;
  };
  nodes.links = { lib, ... }: {
    imports = [
      ../systems/gateway/network.nix
      ../systems/gateway/qos.nix
    ];
    virtualisation.vlans = [
      1
      2
      3
      4
    ];
    # QEMU fixture names replace physical MAC matching; production names and
    # all network/netdev definitions are exercised unchanged.
    systemd.network.links = {
      "10-lan0".matchConfig = lib.mkForce { OriginalName = "eth0"; };
      "10-lan1".matchConfig = lib.mkForce { OriginalName = "eth1"; };
      "10-spare0".matchConfig = lib.mkForce { OriginalName = "eth2"; };
      "10-wan0".matchConfig = lib.mkForce { OriginalName = "eth3"; };
      "10-rescue0".matchConfig = lib.mkForce { OriginalName = "eth4"; };
    };
    systemd.services.systemd-networkd.after = [ "systemd-tmpfiles-setup.service" ];
    systemd.network.netdevs."20-wg01".wireguardConfig.PrivateKeyFile = "/var/lib/gateway/wireguard.key";
    systemd.tmpfiles.rules = [
      "d /var/lib/gateway 0750 root systemd-network -"
      # Public test fixture only; production key is provisioned outside the store.
      "f /var/lib/gateway/wireguard.key 0640 root systemd-network - AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQE="
    ];
    environment.systemPackages = [
      pkgs.iproute2
      pkgs.wireguard-tools
    ];
  };
  testScript = ''
    import json
    start_all()
    links.wait_for_unit("systemd-networkd.service")
    links.wait_for_unit("gateway-cake.service")
    links.wait_until_succeeds("ip link show wg01", timeout=30)
    links.succeed("ip -d link show bond0.3001 | grep 'id 3001'")
    # ROON is IPv4-only, unlike IoT on the same bond.
    links.wait_until_succeeds("ip -4 addr show dev bond0.60 | grep 10.1.4.1/24", timeout=30)
    links.wait_until_succeeds("ip -6 addr show dev bond0.40 | grep fe80::", timeout=30)
    links.succeed("test -z \"$(ip -6 addr show dev bond0.60)\"; test \"$(cat /proc/sys/net/ipv6/conf/bond0.60/forwarding)\" = 0")
    links.succeed("grep 802.3ad /sys/class/net/bond0/bonding/mode")
    links.succeed("test -z \"$(ip -o link show | grep 'bond0.140')\"")
    links.succeed("tc qdisc show dev ifb0 | grep 'cake.*bandwidth 900Mbit.*ingress'")
    links.succeed("wg show wg01 peers | wc -l | grep 3")
    # The OOB port lives only in its VRF: the main table never learns the OOB
    # prefix from it, and sshd can accept connections through it.
    links.wait_until_succeeds("ip -4 addr show dev rescue0 | grep 10.1.254.50/24", timeout=30)
    links.succeed("ip -d link show rescue0 | grep -q 'master vrf-oob'")
    links.succeed("ip route show vrf vrf-oob | grep -q '^default via 10.1.254.1 dev rescue0'")
    links.succeed("test -z \"$(ip route show table main 10.1.254.0/24)\"")
    links.succeed("test \"$(cat /proc/sys/net/ipv4/tcp_l3mdev_accept)\" = 1")
    links.fail("journalctl -b -u systemd-networkd --no-pager | grep -E 'Unknown (key|section)|Failed to parse|Failed to read|Invalid argument'")
    links.succeed("networkctl reload")
    links.succeed("ip link show bond0.3001; wg show wg01")
    router.wait_for_unit("nftables.service")
    router.wait_for_unit("atftpd.service")
    router.wait_for_unit("frr.service")
    router.succeed("ip address add 10.254.254.1/32 dev lo")

    # Real packets through the migrated input/forward/output chains. Each namespace
    # is a client on a different zone; nothing is connected to the physical LAN.
    def client(name, interface, gateway, address):
        router.succeed(f"ip netns add {name}")
        router.succeed(f"ip link add {interface} type veth peer name peer")
        router.succeed(f"ip link set peer netns {name}")
        router.succeed(f"ip address add {gateway}/24 dev {interface}")
        router.succeed(f"ip link set {interface} up")
        router.succeed(f"ip netns exec {name} ip link set lo up")
        router.succeed(f"ip netns exec {name} ip link set peer up")
        router.succeed(f"ip netns exec {name} ip address add {address}/24 dev peer")
        router.succeed(f"ip netns exec {name} ip route add default via {gateway}")
        router.succeed(f"ip netns exec {name} python -m http.server 8080 --bind {address} >/tmp/{name}.log 2>&1 &")
        # Later probes expect this fixture to be listening.
        router.wait_until_succeeds(f"ip netns exec {name} ss -H -ltn sport = :8080 | grep -q .")

    client("trusted", "bond0.20", "10.1.2.1", "10.1.2.11")
    client("iot", "bond0.40", "10.1.3.1", "10.1.3.14")
    client("roon", "bond0.60", "10.1.4.1", "10.1.4.10")
    client("guest", "bond0.30", "192.168.2.1", "192.168.2.11")
    client("servers", "bond0.10", "10.1.1.1", "10.1.1.31")
    client("lan", "bond0.100", "10.1.0.1", "10.1.0.22")
    router.succeed("systemctl start kea-dhcp4-server")
    router.wait_for_unit("kea-dhcp4-server.service")
    client("wan", "wan0", "198.18.0.1", "198.18.0.2")
    router.succeed("ip route add default via 198.18.0.2")
    router.wait_until_succeeds("ip netns exec trusted curl -fsS --max-time 2 http://10.1.3.14:8080")
    router.succeed("ip netns exec trusted curl -fsS --max-time 2 http://10.1.1.31:8080")
    router.fail("ip netns exec guest curl -fsS --max-time 2 http://10.1.2.11:8080")
    router.fail("ip netns exec iot curl -fsS --max-time 2 http://10.1.2.11:8080")
    router.fail("ip netns exec wan curl -fsS --max-time 2 http://10.1.1.31:8080")
    router.succeed("ip netns exec guest curl -fsS --max-time 2 http://198.18.0.2:8080")

    # Exercise DNS migration, outbound restrictions, and inbound DNAT.
    client("transit", "bond0.3001", "10.254.0.0", "10.254.0.1")
    router.succeed("ip netns exec transit ip addr add 172.53.53.53/32 dev lo; ip route add 172.53.53.53/32 via 10.254.0.1")
    router.succeed("mkdir -p /tmp/dns-legacy /tmp/dns-preferred; echo legacy > /tmp/dns-legacy/identity; echo preferred > /tmp/dns-preferred/identity")
    router.succeed("ip netns exec transit python -m http.server 53 --bind 172.53.53.53 --directory /tmp/dns-legacy >/tmp/dns.log 2>&1 &")
    router.succeed("ip netns exec transit ip addr add 10.254.253.53/32 dev lo; ip route add 10.254.253.53/32 via 10.254.0.1")
    router.succeed("ip netns exec transit python -m http.server 53 --bind 10.254.253.53 --directory /tmp/dns-preferred >/tmp/dns-new.log 2>&1 &")
    for zone in ("trusted", "iot", "guest", "servers", "lan"):
        router.wait_until_succeeds(f"ip netns exec {zone} curl -fsS --max-time 2 http://10.254.253.53:53/identity | grep -x preferred")
        router.succeed(f"ip netns exec {zone} curl -fsS --max-time 2 http://172.53.53.53:53/identity | grep -x legacy")
    for zone in ("trusted", "iot"):
        router.succeed(f"ip netns exec {zone} curl -fsS --max-time 2 http://1.1.1.1:53/identity | grep -x preferred")
    router.fail("curl -fsS --max-time 2 http://198.18.0.2:8080")
    router.succeed("ip netns exec wan python -m http.server 443 --bind 198.18.0.2 >/tmp/wan-https.log 2>&1 &")
    router.wait_until_succeeds("curl -fsS --max-time 2 http://198.18.0.2:443")
    router.succeed("ip netns exec wan python -m http.server 853 --bind 198.18.0.2 >/tmp/dot.log 2>&1 &")
    router.wait_until_succeeds("ip netns exec guest curl -fsS --max-time 2 http://198.18.0.2:853")
    for zone in ("trusted", "iot"):
        router.fail(f"ip netns exec {zone} curl -fsS --max-time 2 http://198.18.0.2:853")
        router.succeed(f"ip netns exec {zone} curl -fsS --max-time 2 http://198.18.0.2:8080")

    # Trusted clients, including WireGuard peers, reach every ROON device on any
    # port. Other zones and WAN do not; public ARC access stays closed.
    router.succeed("ip netns exec roon ip addr add 10.1.4.11/24 dev peer")
    router.succeed("ip netns exec roon python -m http.server 59453 --bind 10.1.4.10 >/tmp/rock-arc.log 2>&1 &")
    router.succeed("ip netns exec roon python -m http.server 8080 --bind 10.1.4.11 >/tmp/player.log 2>&1 &")
    router.succeed("ip netns exec trusted ip addr add 10.0.11.5/32 dev peer; ip route add 10.0.11.5/32 dev bond0.20")
    for source in ("10.1.2.11", "10.0.11.5"):
        for target in ("10.1.4.10:59453", "10.1.4.10:8080", "10.1.4.11:8080"):
            router.wait_until_succeeds(f"ip netns exec trusted curl --interface {source} -fsS --max-time 2 http://{target}")
    router.succeed("ip netns exec trusted ip addr del 10.0.11.5/32 dev peer; ip route del 10.0.11.5/32 dev bond0.20")
    for zone in ("iot", "guest", "servers", "lan", "wan"):
        router.fail(f"ip netns exec {zone} curl -fsS --max-time 2 http://10.1.4.10:59453")
    router.fail("ip netns exec wan curl -fsS --max-time 2 http://198.18.0.1:59453")

    # ROON reaches the resolver VIP, ROCK's music library and web services only.
    router.succeed("ip netns exec transit ip addr add 10.254.1.101/32 dev lo; ip route add 10.254.1.101/32 via 10.254.0.1")
    for port in (445, 8080):
        router.succeed(f"ip netns exec transit python -m http.server {port} --bind 10.254.1.101 >/tmp/storage-{port}.log 2>&1 &")
    router.wait_until_succeeds("ip netns exec roon curl --interface 10.1.4.10 -fsS --max-time 2 http://10.254.1.101:445")
    router.fail("ip netns exec roon curl --interface 10.1.4.11 -fsS --max-time 2 http://10.254.1.101:445")
    router.fail("ip netns exec roon curl --interface 10.1.4.10 -fsS --max-time 2 http://10.254.1.101:8080")
    router.succeed("ip netns exec roon curl -fsS --max-time 2 http://10.254.253.53:53/identity | grep -x preferred")
    router.fail("ip netns exec roon curl -fsS --max-time 2 http://172.53.53.53:53/identity")
    router.succeed("ip netns exec roon curl -fsS --max-time 2 http://198.18.0.2:443")
    router.fail("ip netns exec roon curl -fsS --max-time 2 http://198.18.0.2:8080")
    for address in ("10.1.2.11", "10.1.3.14", "10.1.1.31", "10.1.0.22"):
        router.fail(f"ip netns exec roon curl -fsS --max-time 2 http://{address}:8080")

    # Pings follow zone trust; restricted zones may ping only the gateway.
    zone_gateways = {"trusted": "10.1.2.1", "iot": "10.1.3.1", "roon": "10.1.4.1", "guest": "192.168.2.1", "servers": "10.1.1.1", "lan": "10.1.0.1", "transit": "10.254.0.0"}
    for zone, gateway in zone_gateways.items():
        router.succeed(f"ip netns exec {zone} ping -c 1 -W 2 {gateway}")
    router.fail("ip netns exec wan ping -c 1 -W 2 198.18.0.1")
    for address in ("10.1.2.11", "10.1.3.14", "10.1.4.10", "192.168.2.11", "10.1.1.31", "10.1.0.22", "10.254.0.1", "198.18.0.2"):
        router.succeed(f"ping -c 1 -W 2 {address}")
    for zone, address in (
        ("trusted", "10.1.3.14"), ("trusted", "10.1.4.10"), ("trusted", "192.168.2.11"), ("trusted", "10.1.0.22"),
        ("lan", "10.1.1.31"), ("servers", "10.1.2.11"), ("servers", "10.1.3.14"), ("transit", "10.1.2.11"), ("transit", "10.1.0.22"),
    ):
        router.succeed(f"ip netns exec {zone} ping -c 1 -W 2 {address}")
    for zone, address in (
        ("roon", "10.1.2.11"), ("iot", "10.1.2.11"), ("guest", "10.1.3.14"), ("lan", "10.1.2.11"),
        ("servers", "10.1.4.10"), ("servers", "10.1.0.22"), ("transit", "10.1.4.10"), ("wan", "10.1.2.11"),
    ):
        router.fail(f"ip netns exec {zone} ping -c 1 -W 2 {address}")

    # New pings to the gateway are limited to 10/second with a burst of 20;
    # pings through it are not. Conntrack accepts the later echo requests of an
    # answered ping, so each probe is a separate ping with its own identifier.
    def answered(zone, address):
        output = router.succeed(f"seq 100 | xargs -P 100 -I{{}} ip netns exec {zone} sh -c 'ping -c 1 -W 2 {address} >/dev/null && echo answered' || true")
        return output.split().count("answered")
    limited = answered("roon", "10.1.4.1")
    assert 15 <= limited <= 70, limited
    assert answered("trusted", "10.1.3.14") == 100

    router.succeed("ip netns exec transit ip addr add 10.45.0.24/32 dev lo; ip route add 10.45.0.24/32 via 10.254.0.1")
    router.succeed("ip netns exec transit python -m http.server 50413 --bind 10.45.0.24 >/tmp/torrent.log 2>&1 &")
    router.wait_until_succeeds("ip netns exec wan curl -fsS --max-time 2 http://198.18.0.1:50413")
    router.fail("ip netns exec wan curl -fsS --max-time 2 http://10.45.0.24:50413")
    router.succeed("ip netns exec wan ip addr add 1.0.1.1/32 dev lo; ip route add 1.0.1.1/32 via 198.18.0.2")
    router.fail("ip netns exec wan curl --interface 1.0.1.1 -fsS --max-time 2 http://198.18.0.1:50413")

    # Routed scanner access is limited to pods and the printer's TCP ports.
    router.succeed("ip netns exec trusted ip addr add 10.1.2.70/24 dev peer")
    router.succeed("ip netns exec transit ip addr add 172.20.0.10/32 dev lo; ip route add 172.20.0.0/16 via 10.254.0.1")
    for port in (443, 54921, 444):
        router.succeed(f"ip netns exec trusted python -m http.server {port} --bind 10.1.2.70 >/tmp/scanner-{port}.log 2>&1 &")
    for port in (443, 54921):
        router.wait_until_succeeds(f"ip netns exec transit curl --interface 172.20.0.10 -fsS --max-time 2 http://10.1.2.70:{port}")
    router.fail("ip netns exec transit curl --interface 172.20.0.10 -fsS --max-time 2 http://10.1.2.70:444")
    router.fail("ip netns exec transit curl --interface 10.254.0.1 -fsS --max-time 2 http://10.1.2.70:443")

    # Certificate uploads and the UniFi controller must be reachable only from routed pods.
    for zone, address in (("lan", "10.1.0.23"), ("servers", "10.1.1.30")):
        router.succeed(f"ip netns exec {zone} ip addr add {address}/24 dev peer")
        router.succeed(f"ip netns exec {zone} python -m http.server 443 --bind {address} >/tmp/https-{address}.log 2>&1 &")
        router.wait_until_succeeds(f"ip netns exec transit curl --interface 172.20.0.10 -fsS --max-time 2 http://{address}:443")
        router.fail(f"ip netns exec transit curl --interface 10.254.0.1 -fsS --max-time 2 http://{address}:443")

    # IPv4 trust does not imply IPv6 trust. Internal ICMPv6 is permitted even
    # across pairs that deny TCP; WAN echo requests remain denied.
    # Keep fixture prefixes distinct from the harness eth1 subnet (2001:db8:1::/64).
    for zone, interface, prefix in (
        ("trusted", "bond0.20", "fd00:20"),
        ("iot", "bond0.40", "fd00:40"),
        ("roon", "bond0.60", "fd00:60"),
        ("guest", "bond0.30", "fd00:30"),
        ("servers", "bond0.10", "fd00:10"),
        ("transit", "bond0.3001", "fd00:3001"),
        ("wan", "wan0", "2001:db8:ffff"),
    ):
        router.succeed(f"ip -6 address add {prefix}::1/64 dev {interface} nodad")
        router.succeed(f"ip netns exec {zone} ip -6 address add {prefix}::2/64 dev peer nodad")
        router.succeed(f"ip netns exec {zone} ip -6 route add default via {prefix}::1")
        router.succeed(f"ip netns exec {zone} python -m http.server 8081 --bind :: >/tmp/{zone}-ipv6.log 2>&1 &")

    router.fail("ip netns exec trusted curl -gfsS --max-time 2 http://[fd00:10::2]:8081")
    router.fail("ip netns exec guest curl -gfsS --max-time 2 http://[fd00:20::2]:8081")
    # ROON is IPv4-only, so even ICMPv6 to and from it is denied.
    router.fail("ip netns exec trusted ping -6 -c 1 -W 2 fd00:60::2")
    router.fail("ip netns exec roon ping -6 -c 1 -W 2 fd00:20::2")
    router.succeed("ip netns exec guest ping -6 -c 1 -W 2 fd00:20::2")
    router.fail("ip netns exec wan ping -6 -c 1 -W 2 fd00:20::2")

    # The mDNS reflector uses packet sockets, so the firewall keeps no mDNS
    # allowances: unicast from port 5353 is filtered like any other UDP.
    # Keep fixture prefixes distinct from the harness eth1 subnet (2001:db8:1::/64).
    for zone, interface, prefix in (("thread", "bond0.1100", "fd00:1100"), ("matter", "bond0.1101", "fd00:1101")):
        router.succeed(f"ip netns add {zone}; ip link add {interface} type veth peer name peer; ip link set peer netns {zone}; ip link set {interface} up")
        router.succeed(f"ip -n {zone} link set lo up; ip -n {zone} link set peer up")
        router.succeed(f"ip -6 addr add {prefix}::1/64 dev {interface} nodad; ip -n {zone} -6 addr add {prefix}::2/64 dev peer nodad")

    def udp_server(namespace, address, port, log_path):
        command = f"python /etc/gateway-udp.py listen {address} {port} {log_path}"
        if namespace:
            command = f"ip netns exec {namespace} {command}"
        router.succeed(f"{command} >/tmp/udp-server.log 2>&1 &")
        router.wait_until_succeeds(f"test -f {log_path}.ready")

    def udp_packet(namespace, source, sport, destination, dport, payload):
        command = f"python /etc/gateway-udp.py send {source} {sport} {destination} {dport} {payload}"
        router.succeed(f"ip netns exec {namespace} {command}" if namespace else command)

    for zone, gateway, client_address in (("trusted", "10.1.2.1", "10.1.2.11"), ("iot", "fd00:40::1", "fd00:40::2"), ("thread", "fd00:1100::1", "fd00:1100::2")):
        for namespace, source, destination in ((zone, client_address, gateway), (None, gateway, client_address)):
            receiver = None if namespace else zone
            log_path = f"/tmp/mdns-{zone}-{namespace or 'router'}"
            udp_server(receiver, destination, 45002, log_path)
            udp_packet(namespace, source, 5353, destination, 45002, "mdns-reply")
    router.sleep(1)
    router.fail("grep -h mdns-reply /tmp/mdns-*-* | grep -q .")
    # Control: the same Trusted path delivers a permitted service.
    udp_server(None, "10.1.2.1", 51820, "/tmp/mdns-control")
    udp_packet("trusted", "10.1.2.11", 45003, "10.1.2.1", 51820, "control")
    router.wait_until_succeeds("grep -x control /tmp/mdns-control")

    # TCP and UDP encrypted DNS are denied on WAN for both address families.
    for address in ("198.18.0.2", "2001:db8:ffff::2"):
        log_path = "/tmp/dot-" + ("v6" if ":" in address else "v4")
        udp_server("wan", address, 853, log_path)
        for zone in ("trusted", "iot"):
            source = ("fd00:20::2" if zone == "trusted" else "fd00:40::2") if ":" in address else ("10.1.2.11" if zone == "trusted" else "10.1.3.14")
            udp_packet(zone, source, 45003, address, 853, "blocked-dot")
        control_log = log_path + "-control"
        udp_server("wan", address, 45004, control_log)
        for zone in ("trusted", "iot"):
            source = ("fd00:20::2" if zone == "trusted" else "fd00:40::2") if ":" in address else ("10.1.2.11" if zone == "trusted" else "10.1.3.14")
            udp_packet(zone, source, 45003, address, 45004, zone)
            router.wait_until_succeeds(f"grep -x {zone} {control_log}")
        router.fail(f"grep -x blocked-dot {log_path}")
    router.succeed("ip netns exec wan python -m http.server 853 --bind 2001:db8:ffff::2 >/tmp/dot-v6-tcp.log 2>&1 &")
    router.wait_until_succeeds("ip netns exec wan curl -gfsS --max-time 2 http://[2001:db8:ffff::2]:853")
    for zone in ("trusted", "iot"):
        router.succeed(f"ip netns exec {zone} curl -gfsS --max-time 2 http://[2001:db8:ffff::2]:8081")
        router.fail(f"ip netns exec {zone} curl -gfsS --max-time 2 http://[2001:db8:ffff::2]:853")

    # Relayed discovery carries the client's source address, so ROCK's replies
    # arrive unsolicited; only its discovery socket may send them.
    udp_server("trusted", "10.1.2.11", 45005, "/tmp/roon-replies")
    udp_packet("roon", "10.1.4.10", 9003, "10.1.2.11", 45005, "rock-reply")
    router.wait_until_succeeds("grep -x rock-reply /tmp/roon-replies")
    udp_packet("roon", "10.1.4.10", 9004, "10.1.2.11", 45005, "wrong-port")
    udp_packet("roon", "10.1.4.11", 9003, "10.1.2.11", 45005, "not-rock")
    # Trusted clients may also query ROCK's discovery port directly.
    udp_server("roon", "10.1.4.10", 9003, "/tmp/roon-discovery")
    udp_packet("trusted", "10.1.2.11", 45006, "10.1.4.10", 9003, "trusted-query")
    router.wait_until_succeeds("grep -x trusted-query /tmp/roon-discovery")
    udp_packet("iot", "10.1.3.14", 45006, "10.1.4.10", 9003, "iot-query")
    router.sleep(1)
    router.fail("grep -E 'wrong-port|not-rock' /tmp/roon-replies")
    router.fail("grep -x iot-query /tmp/roon-discovery")

    # Thread routing belongs to its infrastructure VLAN, never an IoT next hop.
    router.succeed("ip netns exec iot ip -6 address add fd42:dfb5:24e4:1::2/64 dev peer nodad")
    router.succeed("ip -6 route add fd42:dfb5:24e4:1::/64 via fd00:40::2")
    router.fail("ip netns exec trusted curl -gfsS --max-time 2 http://[fd00:40::2]:8081")
    router.fail("ip netns exec trusted curl -gfsS --max-time 2 http://[fd42:dfb5:24e4:1::2]:8081")
    router.succeed("python -m http.server 8081 --bind :: >/tmp/router-ipv6.log 2>&1 &")
    router.wait_until_succeeds("ip netns exec transit curl -gfsS --max-time 2 http://[fd00:3001::1]:8081")
    router.fail("ip netns exec guest curl -gfsS --max-time 2 http://[fd00:30::1]:8081")

    # Check reservations, pool options, vendor discovery and boot selection
    # through actual DHCP exchanges, then repeat after reloading and restarting.
    for zone in ("servers", "trusted", "guest", "iot", "roon", "lan"):
        router.succeed(f"ip netns exec {zone} python /etc/gateway-dhcp.py {zone}")
    router.succeed("systemctl reload kea-dhcp4-server")
    router.succeed("systemctl restart kea-dhcp4-server")
    for zone in ("servers", "trusted", "guest", "iot", "roon", "lan"):
        router.succeed(f"ip netns exec {zone} python /etc/gateway-dhcp.py {zone}")

    # TFTP data connections traverse the conntrack helper rather than opening
    # an ephemeral UDP range. Serve the boot asset from its native service.
    router.succeed("echo pxe-test > /var/lib/tftpboot/test; chmod 644 /var/lib/tftpboot/test")
    router.succeed("ip netns exec trusted tftp -g -r test -l /tmp/tftp-result 10.5.0.9")
    router.succeed("grep pxe-test /tmp/tftp-result")
    router.succeed("vtysh -c 'show bgp ipv4 unicast summary json' > /tmp/bgp.json")
    bgp = json.loads(router.succeed("cat /tmp/bgp.json"))
    assert set(bgp["peers"]) == {"10.254.0.1", "10.1.1.110", "10.1.1.111", "10.1.1.112"}

    # Trusted LAN clients reach OOB devices behind the core; WireGuard peers,
    # although in the same zone, do not.
    router.succeed("ip netns exec transit ip addr add 10.1.254.10/32 dev lo; ip route add 10.1.254.0/24 via 10.254.0.1")
    router.succeed("ip netns exec transit python -m http.server 8443 --bind 10.1.254.10 >/tmp/oob.log 2>&1 &")
    router.wait_until_succeeds("ip netns exec transit ss -H -ltn sport = :8443 | grep -q .")
    client("wireguard", "wg01", "10.0.11.1", "10.0.11.4")
    router.succeed("ip netns exec trusted curl -fsS --max-time 2 http://10.1.254.10:8443")
    router.fail("ip netns exec wireguard curl -fsS --max-time 2 http://10.1.254.10:8443")

    # The OOB port is host-only. A namespace standing in for Beefchunk reaches
    # SSH on the gateway through vrf-oob, but no other local service, and the
    # gateway forwards nothing for it. The listener on port 22 stands in for
    # sshd, bound in the default VRF as sshd is.
    router.succeed("sysctl -w net.ipv4.tcp_l3mdev_accept=1")
    router.succeed("ip link add vrf-oob type vrf table 1254; ip link set vrf-oob up")
    router.succeed("ip netns add oob; ip link add rescue0 type veth peer name peer; ip link set peer netns oob")
    router.succeed("ip link set rescue0 master vrf-oob; ip address add 10.1.254.50/24 dev rescue0; ip link set rescue0 up")
    router.succeed("ip route add default via 10.1.254.1 vrf vrf-oob")
    router.succeed("ip netns exec oob ip link set lo up; ip netns exec oob ip link set peer up")
    router.succeed("ip netns exec oob ip address add 10.1.254.1/24 dev peer")
    router.succeed("ip netns exec oob ip route add 10.1.0.0/16 via 10.1.254.50")
    for port in (22, 8082):
        router.succeed(f"python -m http.server {port} --bind 0.0.0.0 >/tmp/oob-{port}.log 2>&1 &")
        router.wait_until_succeeds(f"ss -H -ltn sport = :{port} | grep -q .")
    router.succeed("ip netns exec oob curl -fsS --max-time 2 http://10.1.254.50:22")
    router.fail("ip netns exec oob curl -fsS --max-time 2 http://10.1.254.50:8082")
    router.fail("ip netns exec oob curl -fsS --max-time 2 http://10.1.2.11:8080")

    # Reload policy while a TCP connection carries traffic. nft's transaction
    # must neither flush conntrack nor open a fail-open window between commands.
    router.succeed("ip netns exec trusted python -c 'import socket,time; s=socket.create_connection((\"10.1.3.14\",8080)); time.sleep(3); s.sendall(b\"GET / HTTP/1.0\\r\\n\\r\\n\"); assert b\"200 OK\" in s.recv(4096); open(\"/tmp/reload-ok\",\"w\").close()' >/tmp/reload.log 2>&1 &")
    router.sleep(1)
    router.succeed("systemctl reload nftables")
    router.wait_until_succeeds("test -f /tmp/reload-ok")
  '';
}
