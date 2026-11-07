"""Send independent wire probes for the gateway's Matter/Thread contracts."""

import ipaddress
from pathlib import Path
import socket
import struct
import sys


def ra(interface, source, lifetime, mac=None):
    from scapy.all import Ether, IPv6, ICMPv6ND_RA, Raw, get_if_hwaddr, sendp

    # Include unrelated PIO, MTU, and route options to challenge the RA oracle.
    pio = struct.pack("!BBBBIII16s", 3, 4, 64, 0xC0, 3600, 1800, 0,
                      ipaddress.IPv6Address("fd00:dead::").packed)
    mtu = struct.pack("!BBHI", 5, 1, 0, 1280)
    route = struct.pack("!BBBBI8s", 24, 2, 64, 0, lifetime,
                        ipaddress.IPv6Address("fd42:dfb5:24e4:1::").packed[:8])
    unrelated = struct.pack("!BBBBI8s", 24, 2, 64, 0, 120,
                            ipaddress.IPv6Address("fd00:beef::").packed[:8])
    wide = struct.pack("!BBBBI8s", 24, 2, 48, 0, 120,
                       ipaddress.IPv6Address("fd42:dfb5:24e4::").packed[:8])
    default = struct.pack("!BBBBI", 24, 1, 0, 0, 120)
    # Forge identities on the wire without changing the fixture's addresses.
    packet = (
        Ether(src=mac or get_if_hwaddr(interface), dst="33:33:00:00:00:01")
        / IPv6(src=source, dst="ff02::1", hlim=255)
        / ICMPv6ND_RA(chlim=64, routerlifetime=1800)
        / Raw(pio + mtu + route + unrelated + wide + default)
    )
    sendp(packet, iface=interface, verbose=False)


def serve(address):
    sock = socket.socket(socket.AF_INET6, socket.SOCK_DGRAM)
    sock.bind((address, 45001))
    while True:
        data, peer = sock.recvfrom(4096)
        sock.sendto(data, peer)


def probe(address, source=None):
    sock = socket.socket(socket.AF_INET6, socket.SOCK_DGRAM)
    sock.settimeout(2)
    if source:
        sock.bind((source, 0))
    sock.sendto(b"matter-probe", (address, 45001))
    assert sock.recv(4096) == b"matter-probe"


def mdns_socket(interface):
    index = socket.if_nametoindex(interface)
    sock = socket.socket(socket.AF_INET6, socket.SOCK_DGRAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_BINDTODEVICE, interface.encode())
    sock.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_MULTICAST_IF, index)
    sock.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_MULTICAST_HOPS, 255)
    sock.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_JOIN_GROUP,
                    socket.inet_pton(socket.AF_INET6, "ff02::fb") + struct.pack("@I", index))
    sock.bind(("::", 5353))
    return sock, index


def mdns_listen(interface, log):
    sock, _ = mdns_socket(interface)
    Path(log).touch()
    while True:
        data, _ = sock.recvfrom(4096)
        with open(log, "a") as output:
            output.write(repr(data) + "\n")


def mdns_announce(interface, service):
    sock, index = mdns_socket(interface)
    name = b"".join(bytes([len(part)]) + part.encode() for part in service.split(".")) + b"\0"
    target = b"\x05probe" + name
    packet = (struct.pack("!6H", 0, 0x8400, 0, 1, 0, 0) + name
              + struct.pack("!HHIH", 12, 1, 120, len(target)) + target)
    sock.sendto(packet, ("ff02::fb", 5353, 0, index))


if __name__ == "__main__":
    operation, *args = sys.argv[1:]
    if operation == "ra":
        ra(args[0], args[1], int(args[2]), *args[3:])
    elif operation == "serve":
        serve(*args)
    elif operation == "probe":
        probe(*args)
    elif operation == "mdns-listen":
        mdns_listen(*args)
    elif operation == "mdns-announce":
        mdns_announce(*args)
    else:
        raise ValueError(operation)
