"""Observe UDP delivery independently of the gateway's rule counters."""

from pathlib import Path
import socket
import sys

operation, address, port, *args = sys.argv[1:]
family = socket.AF_INET6 if ":" in address else socket.AF_INET
sock = socket.socket(family, socket.SOCK_DGRAM)
sock.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
sock.bind((address, int(port)))

if operation in ("listen", "echo"):
    # Each line records the payload; echo also records the source address and
    # replies from the bound socket to the sender.
    log = Path(args[0])
    for group in args[1:]:
        # Join IPv4 groups on the interface of the route towards them.
        sock.setsockopt(socket.IPPROTO_IP, socket.IP_ADD_MEMBERSHIP, socket.inet_aton(group) + bytes(4))
    log.touch()
    Path(str(log) + ".ready").touch()
    while True:
        payload, source = sock.recvfrom(4096)
        with log.open("a") as output:
            output.write(payload.decode() + (f" {source[0]}" if operation == "echo" else "") + "\n")
        if operation == "echo":
            sock.sendto(b"reply-" + payload, source)
elif operation in ("send", "request"):
    destination, dport, payload = args
    try:
        sock.sendto(payload.encode(), (destination, int(dport)))
    except PermissionError:
        # Local output filtering can report EPERM; the receiver decides delivery.
        pass
    if operation == "request":
        sock.settimeout(5)
        # A broadcast also reaches this host's own listeners; wait for a remote reply.
        reply, source = sock.recvfrom(4096)
        while source[0] == address:
            reply, source = sock.recvfrom(4096)
        print(f"{reply.decode()} {source[0]}:{source[1]}")
else:
    raise ValueError(operation)
