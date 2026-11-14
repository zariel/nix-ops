"""Observe UDP delivery independently of the gateway's rule counters."""

from pathlib import Path
import socket
import sys

operation, address, port, *args = sys.argv[1:]
family = socket.AF_INET6 if ":" in address else socket.AF_INET
sock = socket.socket(family, socket.SOCK_DGRAM)
sock.bind((address, int(port)))

if operation == "listen":
    log = Path(args[0])
    log.touch()
    Path(str(log) + ".ready").touch()
    while True:
        payload, _ = sock.recvfrom(4096)
        with log.open("a") as output:
            output.write(payload.decode() + "\n")
elif operation == "send":
    destination, dport, payload = args
    try:
        sock.sendto(payload.encode(), (destination, int(dport)))
    except PermissionError:
        # Local output filtering can report EPERM; the receiver decides delivery.
        pass
else:
    raise ValueError(operation)
