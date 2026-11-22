import json

start_all()
primary.wait_until_succeeds("systemctl is-active keepalived.service")
primary.wait_for_unit("frr.service")
primary.wait_for_unit("prometheus-node-exporter.service")
primary.succeed("ss -H -lnt | grep -F '10.5.0.11:9100 '")
primary.fail("ss -H -lnt | grep -E '0.0.0.0:9100|\\[::\\]:9100'")
primary.succeed("curl -fsS http://10.5.0.11:9100/metrics | grep '^node_uname_info'")
core.wait_for_unit("frr.service")
core.wait_for_unit("http.service")
backup.wait_for_unit("frr.service")

client.succeed("ip link add trusted link eth1 type vlan id 20; ip link set trusted up")
client.succeed("ip addr add 10.1.2.10/24 dev trusted; ip route add default via 10.1.2.1")
client.succeed("ip -6 addr add fd74:f571:d3bd:20::10/64 dev trusted nodad; ip -6 route add default via fd74:f571:d3bd:20::1")


def owns(machine, interface):
    addresses = json.loads(machine.succeed(f"ip -j -4 addr show dev {interface}"))
    return any(a["local"] == "10.1.2.1" for a in addresses[0]["addr_info"])


def path(next_hop):
    core.wait_until_succeeds(f"ip route get 10.1.2.10 | grep 'via {next_hop} '", timeout=30)
    client.wait_until_succeeds("curl -fsS --connect-timeout 1 --max-time 2 http://10.254.253.53:53", timeout=30)


primary.wait_until_succeeds("ip -4 addr show dev bond0.20 | grep '10.1.2.1/24'")
primary.succeed("ip -4 addr show dev bond0.20 | grep '10.1.2.5/32'")
path("10.254.0.0")
backup.succeed("systemctl start keepalived")
backup.wait_for_unit("keepalived.service")
backup.sleep(3)
assert not owns(backup, "trusted")

# Networkd must preserve keepalived's address when its configuration is reapplied.
primary.succeed("networkctl reload; networkctl reconfigure bond0.20")
assert owns(primary, "bond0.20")
path("10.254.0.0")

# Native transit tracking releases both VIP ownership and BGP origination.
primary.succeed("ip link set bond0.3001 down")
backup.wait_until_succeeds("ip -4 addr show dev trusted | grep '10.1.2.1/24'")
assert not owns(primary, "bond0.20")
path("10.254.0.8")

primary.succeed("ip link set bond0.3001 up")
primary.wait_until_succeeds("vtysh -c 'show bgp ipv4 unicast summary json' | grep Established")
primary.sleep(4)
assert not owns(primary, "bond0.20")
primary.succeed("ip route show 10.1.2.0/24 | grep 'dev bond0.20.*metric 100'")
primary.succeed("ping -I 10.1.2.5 -c 1 -W 2 10.1.2.10")
primary.succeed("systemctl restart frr")
primary.wait_for_unit("frr.service")
path("10.254.0.8")
primary.wait_until_succeeds("vtysh -c 'show bgp ipv4 unicast neighbors 10.254.0.1 advertised-routes json' >/tmp/advertised.json")
advertised = json.loads(primary.succeed("cat /tmp/advertised.json"))
assert "10.1.2.0/24" not in advertised.get("advertisedRoutes", {})


# Roon discovery crosses between Trusted and ROON on UDP 9003 by broadcast and
# by the SOOD group, keeping the original source address and port, so ROCK's
# unicast replies are routed straight back to the client. The relay does not
# depend on which gateway holds Trusted's VRRP /24.
client.succeed("ip netns add roon; ip link add roon link eth1 type vlan id 60; ip link set roon netns roon; ip -n roon link set roon name peer")
client.succeed("ip -n roon link set lo up; ip -n roon link set peer up; ip -n roon addr add 10.1.4.10/24 dev peer; ip -n roon route add default via 10.1.4.1")
udp = "python /etc/gateway-udp.py"
for port in (9003, 9004):
    client.succeed(f"ip netns exec roon {udp} echo 0.0.0.0 {port} /tmp/rock-{port} 239.255.90.90 >/tmp/rock-{port}.log 2>&1 &")
    client.wait_until_succeeds(f"test -f /tmp/rock-{port}.ready")
client.succeed(f"{udp} echo 0.0.0.0 9003 /tmp/trusted-9003 >/tmp/trusted-9003.log 2>&1 &")
client.wait_until_succeeds("test -f /tmp/trusted-9003.ready")


def discovery(label):
    for sport, destination in ((45010, "10.1.2.255"), (45011, "255.255.255.255"), (45012, "239.255.90.90")):
        reply = client.wait_until_succeeds(f"{udp} request 10.1.2.10 {sport} {destination} 9003 {label}-{sport}", timeout=30)
        assert reply.strip() == f"reply-{label}-{sport} 10.1.4.10:9003", reply
        client.succeed(f"grep -x '{label}-{sport} 10.1.2.10' /tmp/rock-9003")
    client.succeed(f"ip netns exec roon {udp} send 10.1.4.10 45013 10.1.4.255 9003 {label}-announce")
    client.wait_until_succeeds(f"grep -x '{label}-announce 10.1.4.10' /tmp/trusted-9003")


assert not owns(primary, "bond0.20")
discovery("backup-vip")

# Intentional handback; the higher priority primary must not preempt on recovery.
backup.succeed("systemctl stop keepalived")
primary.wait_until_succeeds("ip -4 addr show dev bond0.20 | grep '10.1.2.1/24'")
path("10.254.0.0")
backup.succeed("systemctl start keepalived")
backup.sleep(3)
assert not owns(backup, "trusted")
discovery("primary-vip")
client.succeed(f"{udp} send 10.1.2.10 45014 10.1.2.255 9004 other-port")
client.sleep(1)
client.fail("grep other-port /tmp/rock-9004")

# IPv6-only attachments retain their production addresses and OTBR identity.
for namespace, vlan, address in (
    ("thread", 1100, "fd74:f571:d3bd:1060::2"),
    ("matter", 1101, "fd74:f571:d3bd:1061::2"),
    ("iot", 40, "fd74:f571:d3bd:40::2"),
):
    client.succeed(f"ip netns add {namespace}; ip link add {namespace} link eth1 type vlan id {vlan}")
    if namespace == "thread":
        client.succeed("ip link set thread address 0a:92:17:bd:44:6e")
    client.succeed(f"ip link set {namespace} netns {namespace}; ip -n {namespace} link set {namespace} name peer")
    client.succeed(f"ip -n {namespace} link set lo up; ip -n {namespace} link set peer up")
    client.succeed(f"ip -n {namespace} -6 addr add {address}/64 dev peer nodad")
    gateway = address.rsplit("::", 1)[0] + "::1"
    client.succeed(f"ip -n {namespace} -6 route add default via {gateway}")
client.succeed("ip -n thread -6 addr add fd42:dfb5:24e4:1::2/128 dev lo nodad")
client.succeed("ip -n thread -6 addr replace fe80::892:17ff:febd:446e/64 dev peer nodad")
client.succeed("ip -n thread -6 addr add fe80::dead/64 dev peer nodad")

def advertise(namespace="thread", source="fe80::892:17ff:febd:446e", lifetime=120, mac=""):
    client.succeed(f"ip netns exec {namespace} python /etc/gateway-matter.py ra peer {source} {lifetime} {mac}")

# A forged RA cannot supply a route, even with the correct OTBR link-local address.
advertise(mac="0a:92:17:bd:44:6f")
primary.sleep(1)
primary.succeed("test -z \"$(ip -6 route show fd42:dfb5:24e4:1::/64)\"")
advertise(source="fe80::dead")
primary.sleep(1)
primary.succeed("test -z \"$(ip -6 route show fd42:dfb5:24e4:1::/64)\"")
advertise()
primary.wait_until_succeeds("ip -6 route show fd42:dfb5:24e4:1::/64 | grep 'via fe80::892:17ff:febd:446e dev bond0.1100'")
primary.succeed("test -z \"$(ip -6 route show default)\"; test -z \"$(ip -6 route show fd00:dead::/64)\"; test -z \"$(ip -6 route show fd00:beef::/64)\"")
primary.succeed("test -z \"$(ip -6 route show fd42:dfb5:24e4::/48)\"")
primary.fail("ip -6 addr show dev bond0.1100 | grep fd00:dead")
primary.succeed("test $(cat /sys/class/net/bond0.1100/mtu) = 1500")

# Router advertisements on the old IoT path never establish Thread routing.
advertise("iot", mac="0a:92:17:bd:44:6e")
primary.succeed("ip -6 route show fd42:dfb5:24e4:1::/64 | grep bond0.1100")
primary.fail("ip -6 route show fd42:dfb5:24e4:1::/64 | grep bond0.40")

# UDP uses dynamically advertised Matter ports, scoped by endpoint and prefix.
for namespace, address in (
    ("thread", "fd42:dfb5:24e4:1::2"),
    ("thread", "fd74:f571:d3bd:1060::2"),
    ("matter", "fd74:f571:d3bd:1061::2"),
    ("iot", "fd74:f571:d3bd:40::2"),
):
    client.succeed(f"ip netns exec {namespace} python /etc/gateway-matter.py serve {address} >/tmp/{namespace}-udp.log 2>&1 &")
client.succeed("python /etc/gateway-matter.py serve fd74:f571:d3bd:20::10 >/tmp/trusted-udp.log 2>&1 &")
for source, destination in (
    ("matter", "fd42:dfb5:24e4:1::2"),
    ("thread", "fd74:f571:d3bd:1061::2"),
    ("matter", "fd74:f571:d3bd:40::2"),
    ("iot", "fd74:f571:d3bd:1061::2"),
    ("thread", "fd74:f571:d3bd:20::10"),
):
    bind = " fd42:dfb5:24e4:1::2" if source == "thread" else ""
    client.wait_until_succeeds(f"ip netns exec {source} python /etc/gateway-matter.py probe {destination}{bind}")
client.succeed("python /etc/gateway-matter.py probe fd42:dfb5:24e4:1::2")
client.succeed("python /etc/gateway-matter.py probe fd74:f571:d3bd:1060::2")
client.succeed("python /etc/gateway-matter.py probe fd74:f571:d3bd:1061::2")
client.fail("ip netns exec iot python /etc/gateway-matter.py probe fd42:dfb5:24e4:1::2")
client.fail("ip netns exec matter python /etc/gateway-matter.py probe fd74:f571:d3bd:1060::2")
client.succeed("ip -n matter -6 addr add fd74:f571:d3bd:1061::3/64 dev peer nodad")
client.fail("ip netns exec matter python /etc/gateway-matter.py probe fd42:dfb5:24e4:1::2 fd74:f571:d3bd:1061::3")

# Route lifetime and removal belong to RA processing, without a static fallback.
advertise(lifetime=0)
primary.wait_until_succeeds("test -z \"$(ip -6 route show fd42:dfb5:24e4:1::/64)\"")
advertise()
primary.wait_until_succeeds("ip -6 route show fd42:dfb5:24e4:1::/64 | grep bond0.1100")
primary.succeed("networkctl reconfigure bond0.1100")
advertise()
primary.wait_until_succeeds("ip -6 route show fd42:dfb5:24e4:1::/64 | grep bond0.1100")

primary.wait_for_unit("discovery-reflector.service")
matter = "python /etc/gateway-matter.py"
for namespace in ("thread", "matter", "iot"):
    client.succeed(f"ip netns exec {namespace} python /etc/gateway-matter.py mdns-listen peer /tmp/{namespace}-mdns >/tmp/{namespace}-mdns.log 2>&1 &")
    client.wait_until_succeeds(f"test -e /tmp/{namespace}-mdns")
client.succeed("python /etc/gateway-matter.py mdns-announce trusted _meshcop._udp.local")
for namespace in ("thread", "matter", "iot"):
    client.wait_until_succeeds(f"grep -q meshcop /tmp/{namespace}-mdns")
client.succeed("python /etc/gateway-matter.py mdns-announce trusted _unlisted._tcp.local")
client.sleep(2)
for namespace in ("thread", "matter", "iot"):
    client.fail(f"grep -q unlisted /tmp/{namespace}-mdns")

# Apple Home and AirPlay services cross only from IoT devices to Trusted clients.
client.succeed(f"{matter} mdns-listen trusted /tmp/trusted-mdns >/tmp/trusted-mdns.log 2>&1 &")
client.wait_until_succeeds("test -e /tmp/trusted-mdns")
client.succeed(f"ip netns exec iot {matter} mdns-announce peer _airplay._tcp.local")
client.wait_until_succeeds("grep -q _airplay /tmp/trusted-mdns")
client.succeed(f"{matter} mdns-announce trusted _hap._tcp.local")
client.sleep(2)
client.fail("grep -q _hap /tmp/iot-mdns")

# ROON reflects over IPv4, and only the BluOS controller service reaches
# Trusted: the players' AirPlay advertisements stay on ROON.
client.succeed(f"{matter} mdns-listen trusted /tmp/trusted-mdns4 ipv4 >/tmp/trusted-mdns4.log 2>&1 &")
client.wait_until_succeeds("test -e /tmp/trusted-mdns4")
client.succeed(f"ip netns exec roon {matter} mdns-announce peer _airplay._tcp.local ipv4")
client.succeed(f"ip netns exec roon {matter} mdns-announce peer _musc._tcp.local ipv4")
client.wait_until_succeeds("grep -q _musc /tmp/trusted-mdns4")
client.sleep(1)
client.fail("grep -q _airplay /tmp/trusted-mdns4")
primary.succeed("systemctl restart discovery-reflector; networkctl reload")
primary.wait_for_unit("discovery-reflector.service")
primary.fail("journalctl -b -u systemd-networkd -u frr --no-pager | grep -E 'Unknown (key|section|command)|Failed to parse|Invalid configuration'")
