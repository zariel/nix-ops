import shlex

def kernel_warning(marker):
    # Netfilter emits real kern.warning records; userspace kmsg writes use LOG_USER.
    gateway.succeed("nft add table inet hardening_probe")
    gateway.succeed("nft 'add chain inet hardening_probe output { type filter hook output priority -10; }'")
    gateway.succeed("nft " + shlex.quote(f'add rule inet hardening_probe output ip daddr 127.0.0.1 icmp type echo-request log prefix "{marker}" level warn'))
    gateway.succeed("ping -c 1 127.0.0.1")
    gateway.succeed("nft delete table inet hardening_probe")


start_all()
gateway.wait_until_succeeds("systemctl is-active keepalived.service")
units = [
    "systemd-networkd", "systemd-resolved", "frr", "keepalived", "bind",
    "kea-dhcp4-server", "kea-dhcp-ddns-server", "atftpd", "avahi-daemon",
    "chronyd", "syslog", "prometheus-node-exporter", "sshd", "gateway-cake",
    "spamhaus-drop", "matchbox", "roon-discovery",
]
for unit in units:
    gateway.wait_for_unit(unit + ".service")
# Observe bound sockets so a wildcard listener cannot satisfy endpoint checks.
listeners = gateway.succeed("ss -H -lntup").splitlines()
for process, port, expected in (
    ("matchbox", 80, {"10.5.0.8:80"}),
    ("atftpd", 69, {"10.5.0.9:69"}),
    ("chronyd", 123, {"10.5.0.10:123"}),
    ("node_exporter", 9100, {"10.5.0.11:9100"}),
    ("named", 53, {"127.0.0.1:53", "10.5.0.53:53"}),
):
    actual = {line.split()[4] for line in listeners if f'("{process}",' in line and line.split()[4].endswith(f":{port}")}
    assert actual == expected, (process, actual, expected)

gateway.wait_until_succeeds("ip -4 addr show dev wan0 | grep '198.18.0.'")
gateway.wait_until_succeeds("ip route show default | grep 'via 198.18.0.1 dev wan0'")
gateway.succeed("test -s /var/lib/frr/pimd.db; hostname -s | grep -x gateway")
gateway.wait_until_succeeds("ip route get 10.45.0.2 | grep 'via 10.254.0.1'")

lan.succeed("ip netns add trusted; ip link add peer link eth1 type vlan id 20; ip link set peer netns trusted; ip -n trusted link set lo up; ip -n trusted link set peer up; ip -n trusted addr add 10.1.2.10/24 dev peer; ip -n trusted route add default via 10.1.2.1")
lan.wait_until_succeeds("ip netns exec trusted curl -fsS --max-time 2 http://10.5.0.8/assets/probe | grep hardened-boot-assets")
lan.succeed("ip netns exec trusted python /etc/gateway-dhcp.py trusted")
lan.succeed("ip netns exec trusted tftp -g -r probe -l /tmp/tftp-probe 10.5.0.9; grep hardened-tftp /tmp/tftp-probe")
_, upload_output = lan.execute("ip netns exec trusted tftp -p -l /tmp/tftp-probe -r forbidden 10.5.0.9 2>&1")
assert "server error:" in upload_output, upload_output
gateway.fail("test -e /var/lib/tftpboot/forbidden")

lan.succeed("ip netns exec trusted python -c " + shlex.quote('import socket; s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM); s.settimeout(3); s.sendto(bytes([0x23])+bytes(47),("10.5.0.10",123)); response=s.recv(512); assert len(response)>=48 and response[0]&7==4'))
gateway.succeed('curl -fsS http://10.5.0.11:9100/metrics | grep "^node_timex_offset_seconds"')

# Verify the live process identity and mount protections through the kernel.
# The Roon relay replaces its start script once Trusted's VRRP address is present.
gateway.wait_until_succeeds("test \"$(cat /proc/$(systemctl show roon-discovery -p MainPID --value)/comm)\" = udp-proxy-2020")
for unit in ("atftpd", "syslog", "roon-discovery"):
    pid = gateway.succeed(f"systemctl show {unit} -p MainPID --value").strip()
    status = gateway.succeed(f"cat /proc/{pid}/status")
    uid = next(line.split()[1] for line in status.splitlines() if line.startswith("Uid:"))
    assert uid != "0", (unit, status)
    gateway.fail(f"nsenter -t {pid} -m -- sh -c 'echo forbidden > /etc/sandbox-probe'")
    capabilities = int(next(line.split()[1] for line in status.splitlines() if line.startswith("CapEff:")), 16)
    assert not capabilities & ((1 << 12) | (1 << 21)), (unit, capabilities)
pid = gateway.succeed("systemctl show matchbox -p MainPID --value").strip()
gateway.fail(f"nsenter -t {pid} -m -- touch /var/lib/matchbox/forbidden")

# The forwarding daemon must still deliver real kernel warnings as a non-root user.
kernel_warning("gateway-hardening-log")
lan.wait_until_succeeds("grep gateway-hardening-log /run/log-collector/messages", timeout=60)

# Preserve administrative privilege transitions and sandboxed Nix builds.
ssh = "ip netns exec trusted ssh -F /dev/null -i /etc/test-ssh-key -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o BatchMode=yes -o LogLevel=ERROR chris@10.1.2.5 "
lan.succeed(ssh + "'sudo -n id -u | grep -x 0'")
lan.succeed(ssh + "'printf uploaded-asset > /var/lib/gateway/matchbox/assets/uploaded; chmod 0644 /var/lib/gateway/matchbox/assets/uploaded'")
lan.succeed("ip netns exec trusted curl -fsS --max-time 2 http://10.5.0.8/assets/uploaded | grep -x uploaded-asset")
lan.succeed(ssh + shlex.quote("nix-build /etc/gateway-build.nix --no-out-link --option sandbox true --option substituters '' --option builders '' > /tmp/build-result 2>/tmp/build-log || { cat /tmp/build-log; exit 1; }"))
output = gateway.succeed("cat /tmp/build-result").strip()
assert output.startswith("/nix/store/") and "\n" not in output
gateway.succeed(f"grep -x sandbox-build {output}")

gateway.fail("runuser -u matchbox -- nix-store --add /etc/hostname")

# A killed application recovers without affecting routing or DHCP.
gateway.succeed("systemctl kill --signal=KILL matchbox.service")
lan.wait_until_succeeds("ip netns exec trusted curl -fsS --max-time 2 http://10.5.0.8/assets/probe | grep hardened-boot-assets")
gateway.succeed("systemctl restart systemd-networkd; systemctl reload nftables; systemctl restart kea-dhcp4-server syslog")
gateway.wait_until_succeeds("ip route show default | grep 'via 198.18.0.1 dev wan0'")
lan.succeed("ip netns exec trusted python /etc/gateway-dhcp.py trusted")
lan.succeed(ssh + "'sudo -n id -u | grep -x 0'")
kernel_warning("gateway-hardening-after-restart")
lan.wait_until_succeeds("grep gateway-hardening-after-restart /run/log-collector/messages")

# Read enforced cgroup limits, not just the unit's configured values.
control_group = gateway.succeed("systemctl show matchbox -p ControlGroup --value").strip()
limit = gateway.succeed(f"cat /sys/fs/cgroup{control_group}/memory.max").strip()
assert limit != "max" and int(limit) <= 256 * 1024 * 1024
quota, period = gateway.succeed(f"cat /sys/fs/cgroup{control_group}/cpu.max").split()
assert quota != "max" and int(quota) <= int(period)
print(gateway.succeed("systemctl --failed --no-pager"))
for unit in units:
    gateway.succeed(f"systemctl is-active {unit}.service")
