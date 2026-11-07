import json

start_all()
primary.wait_until_succeeds("systemctl is-active keepalived.service")
primary.wait_for_unit("frr.service")
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
    client.wait_until_succeeds("curl -fsS --connect-timeout 1 --max-time 2 http://172.53.53.53:53", timeout=30)


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

# Intentional handback; the higher priority primary must not preempt on recovery.
backup.succeed("systemctl stop keepalived")
primary.wait_until_succeeds("ip -4 addr show dev bond0.20 | grep '10.1.2.1/24'")
path("10.254.0.0")
backup.succeed("systemctl start keepalived")
backup.sleep(3)
assert not owns(backup, "trusted")
