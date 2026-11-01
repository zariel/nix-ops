"""Exercise DHCP over the wire from a client network namespace."""

import ipaddress
import json
import secrets
import socket
import struct
import sys
from pathlib import Path

zone = sys.argv[1]
prefix, reserved_mac, reserved_ip, ntp, domain = {
    "servers": ("10.1.1", "ac:1f:6b:e5:be:42", "10.1.1.31", True, True),
    "trusted": ("10.1.2", "48:b0:2d:2b:14:03", "10.1.2.50", True, True),
    "guest": ("192.168.2", "64:4b:f0:37:f6:78", "192.168.2.11", False, False),
    "iot": ("10.1.3", "48:b0:2d:2b:14:03", "10.1.3.16", False, True),
    "lan": ("10.1.0", "0c:ea:14:e6:16:d5", "10.1.0.22", True, False),
}[zone]


def exchange(mac, extra=(), requested=None, client_id=b"gateway-test"):
    xid = secrets.randbits(32)
    chaddr = bytes.fromhex(mac.replace(":", ""))
    header = struct.pack("!BBBBIHH", 1, 1, 6, 0, xid, 0, 0x8000)
    header += bytes(16) + chaddr.ljust(16, b"\0") + bytes(192)
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_BINDTODEVICE, b"peer\0")
    sock.bind(("0.0.0.0", 68))
    sock.settimeout(3)

    def packet(kind, options):
        options = [
            (53, bytes([kind])),
            (61, client_id),
            (55, bytes([1, 3, 6, 12, 15, 42, 43, 51, 66, 67])),
        ] + list(options)
        return (
            header
            + b"\x63\x82\x53\x63"
            + b"".join(bytes([code, len(value)]) + value for code, value in options)
            + b"\xff"
        )

    def receive(payload, kind):
        for _ in range(5):
            sock.sendto(payload, ("255.255.255.255", 67))
            while True:
                try:
                    data = sock.recv(4096)
                except TimeoutError:
                    break
                if data[0] != 2 or data[4:8] != struct.pack("!I", xid):
                    continue
                options = {}
                offset = 240
                while offset < len(data):
                    code = data[offset]
                    offset += 1
                    if code == 255:
                        break
                    if code == 0:
                        continue
                    length = data[offset]
                    options[code] = data[offset + 1 : offset + 1 + length]
                    offset += length + 1
                if options.get(53) == bytes([kind]):
                    return data, options
        raise AssertionError(f"No DHCP response for {zone}: {mac}, {extra}")

    try:
        data, options = receive(packet(1, extra), 2)
        address = socket.inet_ntoa(data[16:20])
        if requested is not None:
            assert address == requested, (address, requested)
        data, options = receive(
            packet(
                3, list(extra) + [(50, socket.inet_aton(address)), (54, options[54])]
            ),
            5,
        )
        assert socket.inet_ntoa(data[16:20]) == address
        assert options[3] == socket.inet_aton(prefix + ".1")
        assert options[6] == socket.inet_aton("172.53.53.53")
        assert options[1] == socket.inet_aton("255.255.255.0")
        lifetime = 3600 if zone == "guest" else 28800
        # Kea can reuse a lease with its remaining lifetime during this 180s test.
        assert lifetime - 180 <= struct.unpack("!I", options[51])[0] <= lifetime
        assert options.get(42) == (socket.inet_aton("10.254.254.1") if ntp else None)
        assert options.get(15) == (b"cbannister.casa" if domain else None)
        return address, data[20:24], data[108:236].rstrip(b"\0"), options
    finally:
        sock.close()


# The same MAC has different reservations on trusted and IoT.
exchange(reserved_mac, requested=reserved_ip)

if zone == "servers":
    for arch, user_class, filename, server in [
        (b"\0\0", None, b"undionly.kpxe", "10.1.1.1"),
        (b"\0\x07", None, b"ipxe.efi", "10.1.1.1"),
        (b"\0\x09", None, b"ipxe.efi", "10.1.1.1"),
        (b"\0\0\0\x09", None, b"ipxe.efi", "10.1.1.1"),
        (b"\0\x07", b"iPXE", b"http://10.5.0.8/boot.ipxe", "0.0.0.0"),
        (b"\0\x09", b"\x04iPXE", b"http://10.5.0.8/boot.ipxe", "0.0.0.0"),
    ]:
        extra = [(93, arch)] + ([(77, user_class)] if user_class else [])
        _, next_server, bootfile, _ = exchange(reserved_mac, extra)
        assert next_server == socket.inet_aton(server)
        assert bootfile == filename, (user_class, bootfile)
else:
    _, next_server, bootfile, _ = exchange(
        reserved_mac, [(93, b"\0\x07"), (77, b"iPXE")]
    )
    assert next_server == bytes(4) and bootfile == b""

# Controller discovery must be restricted to management clients identifying as ubnt.
_, _, _, options = exchange(reserved_mac, [(60, b"ubnt")])
assert options.get(43) == (bytes.fromhex("01040a010017") if zone == "lan" else None)
_, _, _, options = exchange(reserved_mac)
assert 43 not in options

# A competing client after restart must not receive an existing dynamic lease.
lease = Path(f"/tmp/dhcp-{zone}.json")
if lease.exists():
    previous = json.loads(lease.read_text())
    other, _, _, _ = exchange("02:00:00:00:00:02")
    assert other != previous
    exchange("02:00:00:00:00:01", requested=previous, client_id=b"changed-client-id")
else:
    address, _, _, _ = exchange("02:00:00:00:00:01")
    assert (
        ipaddress.ip_address(prefix + ".200")
        <= ipaddress.ip_address(address)
        <= ipaddress.ip_address(prefix + ".254")
    )
    lease.write_text(json.dumps(address))
