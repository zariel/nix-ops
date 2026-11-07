"""Acquire, renew, and release leases through the DHCP wire protocol."""

import json
import secrets
import socket
import struct
import subprocess
import sys
from pathlib import Path

action, mac, hostname, state = sys.argv[1:]
state = Path(state)
subprocess.run(["ip", "link", "set", "peer", "address", mac], check=True)
chaddr = bytes.fromhex(mac.replace(":", ""))
xid = secrets.randbits(32)
header = struct.pack("!BBBBIHH", 1, 1, 6, 0, xid, 0, 0x8000)
header += bytes(16) + chaddr.ljust(16, b"\0") + bytes(192)
sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
sock.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
sock.setsockopt(socket.SOL_SOCKET, socket.SO_BINDTODEVICE, b"peer\0")
sock.bind(("0.0.0.0", 68))
sock.settimeout(2)


def packet(kind, options):
    options = [(53, bytes([kind]))] + options
    if hostname != "-":
        options.append((12, hostname.encode()))
    return (
        header
        + b"\x63\x82\x53\x63"
        + b"".join(bytes([code, len(value)]) + value for code, value in options)
        + b"\xff"
    )


def exchange(kind, options, expected):
    for _ in range(5):
        sock.sendto(packet(kind, options), ("255.255.255.255", 67))
        while True:
            try:
                data = sock.recv(4096)
            except TimeoutError:
                break
            if data[0] != 2 or data[4:8] != struct.pack("!I", xid):
                continue
            parsed = {}
            offset = 240
            while offset < len(data):
                code = data[offset]
                offset += 1
                if code == 255:
                    break
                if code == 0:
                    continue
                length = data[offset]
                parsed[code] = data[offset + 1 : offset + 1 + length]
                offset += length + 1
            if parsed.get(53) == bytes([expected]):
                return socket.inet_ntoa(data[16:20]), parsed[54]
    raise AssertionError(f"No DHCP response to message {kind}")


if action in ("release", "renew"):
    lease = json.loads(state.read_text())
    header = header[:12] + socket.inet_aton(lease["ip"]) + header[16:]
    if action == "release":
        # DHCPRELEASE identifies the lease through ciaddr and has no reply.
        sock.sendto(
            packet(7, [(54, socket.inet_aton(lease["server"]))]),
            ("255.255.255.255", 67),
        )
    else:
        subprocess.run(["ip", "address", "replace", f"{lease['ip']}/24", "dev", "peer"], check=True)
        address, _ = exchange(3, [], 5)
        assert address == lease["ip"], (address, lease)
        print(address)
else:
    requested = []
    if state.exists():
        requested = [(50, socket.inet_aton(json.loads(state.read_text())["ip"]))]
    address, server = exchange(1, requested, 2)
    address, server = exchange(3, [(50, socket.inet_aton(address)), (54, server)], 5)
    state.write_text(json.dumps({"ip": address, "server": socket.inet_ntoa(server)}))
    subprocess.run(["ip", "address", "replace", f"{address}/24", "dev", "peer"], check=True)
    print(address)
