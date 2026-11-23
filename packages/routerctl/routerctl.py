"""Inspect the gateway's firewall, NAT, routing and multicast state."""

import argparse
from datetime import datetime, timezone
import ipaddress
import json
import os
import shlex
import signal
import subprocess
import sys
import threading
import time


def vty(command):
    return ["vtysh", "-c", command]


REPORTS = {
    "firewall": {
        "title": "Firewall rules and counters",
        "note": "Live rules, handles and counters across all tables. Set contents are omitted. Counters reset when their rules are replaced.",
        "commands": [["nft", "-a", "-n", "-t", "list", "ruleset"]],
    },
    "nat": {
        "title": "NAT rules and translations",
        "note": "NAT rule counters count the first packet of each new connection, not all translated traffic. Conntrack shows original and reply tuples and per-direction accounting for connections created after accounting was enabled.",
        "commands": [
            ["nft", "-a", "-n", "list", "chain", "inet", "gateway", "prerouting"],
            ["nft", "-a", "-n", "list", "chain", "inet", "gateway", "postrouting"],
            ["conntrack", "-L", "-f", "ipv4", "--any-nat", "-o", "extended"],
            ["conntrack", "-L", "-f", "ipv6", "--any-nat", "-o", "extended"],
        ],
    },
    "connections": {
        "title": "Connection tracking",
        "note": "Connection count, capacity, per-CPU kernel statistics and current flows. Accounting applies to newly created connections.",
        "commands": [
            ["sysctl", "net.netfilter.nf_conntrack_count", "net.netfilter.nf_conntrack_max"],
            ["conntrack", "-S"],
            ["conntrack", "-L", "-f", "ipv4", "-o", "extended"],
            ["conntrack", "-L", "-f", "ipv6", "-o", "extended"],
        ],
    },
    "bgp": {
        "title": "BGP summary",
        "note": "FRR peer state and prefix counts for configured address families.",
        "commands": [vty("show bgp summary")],
    },
    "bgp-neighbors": {
        "title": "BGP neighbors",
        "note": "Session details, timers and capabilities. Optionally select a neighbor by IP address.",
        "target": "Optional neighbor IP address",
        "commands": [vty("show bgp neighbors")],
    },
    "bgp-prefixes": {
        "title": "BGP prefixes",
        "note": "FRR IPv4 and IPv6 unicast routing tables, including alternative paths.",
        "commands": [vty("show bgp ipv4 unicast"), vty("show bgp ipv6 unicast")],
    },
    "bgp-route": {
        "title": "BGP route lookup",
        "note": "Use an IP address for a longest-prefix lookup, or a CIDR prefix for an exact lookup.",
        "target": "IP address or CIDR prefix",
        "required": True,
    },
    "routes": {
        "title": "Kernel routes and policy rules",
        "note": "All kernel routing tables and policy rules. Compare these with the BGP RIB when diagnosing forwarding.",
        "commands": [
            ["ip", "-4", "route", "show", "table", "all"],
            ["ip", "-6", "route", "show", "table", "all"],
            ["ip", "-4", "rule", "show"],
            ["ip", "-6", "rule", "show"],
        ],
    },
    "route": {
        "title": "Kernel route lookup",
        "note": "The kernel's selected path and source address for a gateway-originated packet to this IP.",
        "target": "Destination IP address",
        "required": True,
    },
    "igmp": {
        "title": "IGMP membership and statistics",
        "note": "IPv4 querier interfaces, groups, sources and protocol counters from FRR.",
        "commands": [vty(f"show ip igmp {view}") for view in ("interface", "groups", "sources", "statistics")],
    },
    "mld": {
        "title": "MLD membership and statistics",
        "note": "IPv6 querier interfaces, groups, joins and protocol counters from FRR.",
        "commands": [vty(f"show ipv6 mld {view}") for view in ("interface detail", "groups", "joins", "statistics")],
    },
    "pim": {
        "title": "PIM neighbors and state",
        "note": "IPv4 and IPv6 PIM interfaces, neighbors, upstreams and forwarding state.",
        "commands": [vty(f"show {family} pim {view}") for family in ("ip", "ipv6")
                     for view in ("interface", "neighbor", "upstream", "state")],
    },
    "multicast": {
        "title": "Multicast routes and counters",
        "note": "FRR multicast forwarding counters alongside the kernel multicast routing cache.",
        "commands": [vty("show ip mroute count"), vty("show ipv6 mroute count"),
                     ["ip", "-s", "mroute", "show"], ["ip", "-6", "-s", "mroute", "show"]],
    },
    "links": {
        "title": "Interfaces, addresses and neighbors",
        "note": "Kernel link counters, addresses and IPv4/IPv6 neighbor caches.",
        "commands": [["ip", "-s", "-d", "link", "show"], ["ip", "-br", "address", "show"],
                     ["ip", "-4", "neighbor", "show"], ["ip", "-6", "neighbor", "show"]],
    },
    "qos": {
        "title": "Queueing and shaping statistics",
        "note": "Queue counters, drops and CAKE statistics from the kernel traffic-control layer.",
        "commands": [["tc", "-s", "qdisc", "show"]],
    },
    "vrrp": {
        "title": "Gateway VIP ownership",
        "note": "The floating 10.1.2.1/24 and 10.1.1.1/24 addresses indicate local VIP ownership. Keepalived process state alone does not imply MASTER.",
        "commands": [["ip", "-4", "address", "show", "dev", "bond0.20"],
                     ["ip", "-4", "address", "show", "dev", "bond0.10"],
                     ["systemctl", "show", "keepalived.service", "-p", "ActiveState", "-p", "SubState"]],
    },
}


def commands(name, target):
    if name not in REPORTS:
        raise ValueError("Unknown report")
    report = REPORTS[name]
    if report.get("required") and not target:
        raise ValueError(report["target"] + " is required")
    if target:
        if "target" not in report:
            raise ValueError("This report does not accept a target")
        if "%" in target:
            raise ValueError("Use an IP address without a scope identifier")
        address = (ipaddress.ip_network(target, strict=False)
                   if name == "bgp-route" and "/" in target else ipaddress.ip_address(target))
        family = address.version
        if name == "route":
            return [["ip", f"-{family}", "route", "get", str(address)]]
        if name == "bgp-neighbors":
            return [vty(f"show bgp neighbors {address}")]
        return [vty(f"show bgp ipv{family} unicast {address}")]
    return report["commands"]


def run(argv, timeout, limit):
    started = time.monotonic()
    timed_out = threading.Event()
    environment = dict(os.environ, LC_ALL="C", SYSTEMD_PAGER="cat", VTYSH_PAGER="cat")
    try:
        with subprocess.Popen(argv, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                              env=environment) as process:
            def expire():
                if process.poll() is None:
                    timed_out.set()
                    process.kill()

            # Bound both native command runtime and captured output, including
            # large conntrack tables. No caller-supplied text reaches a shell.
            timer = threading.Timer(timeout, expire)
            timer.start()
            try:
                data = process.stdout.read(limit + 1)
                truncated = len(data) > limit
                if truncated:
                    process.kill()
                process.wait()
            finally:
                timer.cancel()
                if process.poll() is None:
                    process.kill()
        return {
            "command": shlex.join(argv), "output": data[:limit].decode(errors="replace"),
            "returncode": process.returncode, "timed_out": timed_out.is_set(),
            "truncated": truncated, "seconds": round(time.monotonic() - started, 3),
        }
    except OSError as error:
        return {"command": shlex.join(argv), "output": str(error), "returncode": 127,
                "timed_out": False, "truncated": False, "seconds": 0}


def collect(name, target=""):
    argv_list = commands(name, target)
    deadline = time.monotonic() + 20
    remaining = 2 * 1024 * 1024
    results = []
    for argv in argv_list:
        result = run(argv, max(0.1, min(5, deadline - time.monotonic())), remaining)
        results.append(result)
        remaining -= len(result["output"].encode())
        if result["truncated"] or remaining <= 0:
            break
    incomplete = len(results) != len(argv_list) or any(
        r["returncode"] or r["timed_out"] or r["truncated"] for r in results
    )
    return {"report": name, "target": target, "title": REPORTS[name]["title"], "note": REPORTS[name]["note"],
            "sampled_at": datetime.now(timezone.utc).isoformat(), "incomplete": bool(incomplete), "results": results}


def main():
    parser = argparse.ArgumentParser(prog="routerctl", description=__doc__)
    parser.add_argument("report", choices=["list", *REPORTS], nargs="?", default="list")
    parser.add_argument("target", nargs="?", default="")
    parser.add_argument("--json", action="store_true", help="emit a structured report")
    args = parser.parse_args()
    if args.report == "list":
        if args.target:
            parser.error("list does not accept a target")
        if args.json:
            print(json.dumps([{"name": name, **{k: v for k, v in report.items() if k != "commands"}}
                              for name, report in REPORTS.items()]))
        else:
            for name, report in REPORTS.items():
                target = f" — {report['target']}" if "target" in report else ""
                print(f"{name:16} {report['title']}{target}")
    else:
        try:
            report = collect(args.report, args.target)
        except ValueError as error:
            parser.error(str(error))
        if args.json:
            print(json.dumps(report))
        else:
            print(f"{report['title']} — {report['sampled_at']}\n{report['note']}")
            for result in report["results"]:
                print(f"\n$ {result['command']}\n{result['output']}", end="\n")
                if result["returncode"] or result["timed_out"] or result["truncated"]:
                    print(f"[exit {result['returncode']}; timed out: {result['timed_out']}; truncated: {result['truncated']}]")
        return int(report["incomplete"])
    return 0


if __name__ == "__main__":
    signal.signal(signal.SIGPIPE, signal.SIG_DFL)
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        sys.exit(130)
