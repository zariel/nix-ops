{ pkgs, sopsModule, ... }:
pkgs.testers.runNixOSTest {
  name = "gateway-policy";
  globalTimeout = 180;
  nodes.router = { lib, ... }: {
    imports = [
      sopsModule
      ./dhcp-dns-secret.nix
      ../systems/gateway/firewall.nix
      ../systems/gateway/dhcp.nix
    ];
    # Client links are created by the test after boot.
    systemd.services.kea-dhcp4-server.wantedBy = lib.mkForce [ ];
    environment.etc."gateway-dhcp.py".source = ./gateway-dhcp.py;
    networking.useDHCP = false;
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
    ];
    # QEMU fixture names replace physical MAC matching; production names and
    # all network/netdev definitions are exercised unchanged.
    systemd.network.links = {
      "10-lan0".matchConfig = lib.mkForce { OriginalName = "eth0"; };
      "10-lan1".matchConfig = lib.mkForce { OriginalName = "eth1"; };
      "10-spare0".matchConfig = lib.mkForce { OriginalName = "eth2"; };
      "10-wan0".matchConfig = lib.mkForce { OriginalName = "eth3"; };
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
    links.succeed("grep 802.3ad /sys/class/net/bond0/bonding/mode")
    links.succeed("test -z \"$(ip -o link show | grep 'bond0.140')\"")
    links.succeed("tc qdisc show dev ifb0 | grep 'cake.*ingress'")
    links.succeed("wg show wg01 peers | wc -l | grep 3")
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

    client("trusted", "bond0.20", "10.1.2.1", "10.1.2.11")
    client("iot", "bond0.40", "10.1.3.1", "10.1.3.14")
    client("guest", "bond0.30", "192.168.2.1", "192.168.2.11")
    client("servers", "bond0.10", "10.1.1.1", "10.1.1.31")
    client("lan", "bond0.100", "10.1.0.1", "10.1.0.22")
    router.succeed("systemctl start kea-dhcp4-server")
    router.wait_for_unit("kea-dhcp4-server.service")
    client("wan", "wan0", "198.18.0.1", "198.18.0.2")
    client("app", "ve-app", "10.5.0.1", "10.5.0.8")
    router.succeed("ip route add default via 198.18.0.2")
    router.wait_until_succeeds("ip netns exec trusted curl -fsS --max-time 2 http://10.1.3.14:8080")
    router.succeed("ip netns exec trusted curl -fsS --max-time 2 http://10.1.1.31:8080")
    router.fail("ip netns exec guest curl -fsS --max-time 2 http://10.1.2.11:8080")
    router.fail("ip netns exec iot curl -fsS --max-time 2 http://10.1.2.11:8080")
    router.fail("ip netns exec wan curl -fsS --max-time 2 http://10.1.1.31:8080")
    router.succeed("ip netns exec guest curl -fsS --max-time 2 http://198.18.0.2:8080")

    for zone in ("trusted", "iot", "servers"):
        router.wait_until_succeeds(f"ip netns exec {zone} curl -fsS --max-time 2 http://10.5.0.8:8080")
    for zone in ("guest", "wan"):
        router.fail(f"ip netns exec {zone} curl -fsS --max-time 2 http://10.5.0.8:8080")

    # Exercise routed DNS interception and both explicit inbound DNAT paths.
    client("transit", "bond0.3001", "10.254.0.0", "10.254.0.1")
    router.succeed("ip netns exec transit ip addr add 172.53.53.53/32 dev lo; ip route add 172.53.53.53/32 via 10.254.0.1")
    router.succeed("ip netns exec transit python -m http.server 53 --bind 172.53.53.53 >/tmp/dns.log 2>&1 &")
    router.wait_until_succeeds("ip netns exec iot curl -fsS --max-time 2 http://1.1.1.1:53")
    router.succeed("ip netns exec app curl -fsS --max-time 2 http://172.53.53.53:53")
    router.succeed("ip netns exec trusted ip addr add 10.1.2.60/24 dev peer")
    router.succeed("ip netns exec trusted python -m http.server 59453 --bind 10.1.2.60 >/tmp/roon.log 2>&1 &")
    router.wait_until_succeeds("ip netns exec wan curl -fsS --max-time 2 http://198.18.0.1:59453")
    router.succeed("ip netns exec transit ip addr add 10.45.0.24/32 dev lo; ip route add 10.45.0.24/32 via 10.254.0.1")
    router.succeed("ip netns exec transit python -m http.server 50413 --bind 10.45.0.24 >/tmp/torrent.log 2>&1 &")
    router.wait_until_succeeds("ip netns exec wan curl -fsS --max-time 2 http://198.18.0.1:50413")
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

    # IPv4 trust does not imply IPv6 trust. Internal ICMPv6 is permitted even
    # across pairs that deny TCP; WAN echo requests remain denied.
    for zone, interface, prefix in (
        ("trusted", "bond0.20", "fd00:20"),
        ("iot", "bond0.40", "fd00:40"),
        ("guest", "bond0.30", "fd00:30"),
        ("servers", "bond0.10", "fd00:10"),
        ("app", "ve-app", "fd00:5"),
        ("transit", "bond0.3001", "fd00:3001"),
        ("wan", "wan0", "2001:db8:1"),
    ):
        router.succeed(f"ip -6 address add {prefix}::1/64 dev {interface} nodad")
        router.succeed(f"ip netns exec {zone} ip -6 address add {prefix}::2/64 dev peer nodad")
        router.succeed(f"ip netns exec {zone} ip -6 route add default via {prefix}::1")
        router.succeed(f"ip netns exec {zone} python -m http.server 8081 --bind :: >/tmp/{zone}-ipv6.log 2>&1 &")

    router.wait_until_succeeds("ip netns exec trusted curl -gfsS --max-time 2 http://[fd00:5::2]:8081")
    router.succeed("ip netns exec iot curl -gfsS --max-time 2 http://[fd00:5::2]:8081")
    router.fail("ip netns exec servers curl -gfsS --max-time 2 http://[fd00:5::2]:8081")
    router.fail("ip netns exec trusted curl -gfsS --max-time 2 http://[fd00:10::2]:8081")
    router.fail("ip netns exec guest curl -gfsS --max-time 2 http://[fd00:20::2]:8081")
    router.succeed("ip netns exec guest ping -6 -c 1 -W 2 fd00:20::2")
    router.fail("ip netns exec wan ping -6 -c 1 -W 2 fd00:20::2")

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
    for zone in ("servers", "trusted", "guest", "iot", "lan"):
        router.succeed(f"ip netns exec {zone} python /etc/gateway-dhcp.py {zone}")
    router.succeed("systemctl reload kea-dhcp4-server")
    router.succeed("systemctl restart kea-dhcp4-server")
    for zone in ("servers", "trusted", "guest", "iot", "lan"):
        router.succeed(f"ip netns exec {zone} python /etc/gateway-dhcp.py {zone}")

    # TFTP data connections traverse the conntrack helper rather than opening
    # an ephemeral UDP range. Serve the boot asset from its native service.
    router.succeed("echo pxe-test > /var/lib/tftpboot/test; chmod 644 /var/lib/tftpboot/test")
    router.succeed("ip netns exec trusted tftp -g -r test -l /tmp/tftp-result 10.254.254.1")
    router.succeed("grep pxe-test /tmp/tftp-result")
    router.succeed("vtysh -c 'show bgp ipv4 unicast summary json' > /tmp/bgp.json")
    bgp = json.loads(router.succeed("cat /tmp/bgp.json"))
    assert set(bgp["peers"]) == {"10.254.0.1", "10.1.1.110", "10.1.1.111", "10.1.1.112"}

    # Reload policy while a TCP connection carries traffic. nft's transaction
    # must neither flush conntrack nor open a fail-open window between commands.
    router.succeed("ip netns exec trusted python -c 'import socket,time; s=socket.create_connection((\"10.1.3.14\",8080)); time.sleep(3); s.sendall(b\"GET / HTTP/1.0\\r\\n\\r\\n\"); assert b\"200 OK\" in s.recv(4096); open(\"/tmp/reload-ok\",\"w\").close()' >/tmp/reload.log 2>&1 &")
    router.sleep(1)
    router.succeed("systemctl reload nftables")
    router.wait_until_succeeds("test -f /tmp/reload-ok")
  '';
}
