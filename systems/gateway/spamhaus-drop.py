"""Install the official Spamhaus DROP feeds as one nftables transaction."""

import fcntl
import ipaddress
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import urllib.request


def networks(feed, version):
    records = [json.loads(line) for line in feed.splitlines() if line.strip()]
    if not records or records[-1].get("type") != "metadata":
        raise ValueError(f"IPv{version} feed is missing metadata")

    metadata = records.pop()
    if not records or metadata["records"] != len(records):
        raise ValueError(f"IPv{version} feed is empty or incomplete")

    result = []
    for record in records:
        network = ipaddress.ip_network(record["cidr"])
        if network.version != version or network.prefixlen == 0:
            raise ValueError(f"Invalid IPv{version} DROP network: {network}")
        result.append(str(network))
    return result


def install(template, feeds):
    rules = template
    for version, placeholder in ((4, "@IPV4@"), (6, "@IPV6@")):
        entries = networks(feeds[str(version)], version) if feeds else []
        elements = "elements = { " + ", ".join(entries) + " }" if entries else ""
        rules = rules.replace(placeholder, elements)

    # Replace only our table, atomically, so readers never see partial lists.
    subprocess.run(["nft", "-f", "-"], input=rules, text=True, check=True)


def main():
    template = Path(sys.argv[1]).read_text()
    mode = sys.argv[2]
    state = Path("/var/lib/spamhaus-drop")
    cache = state / "feeds.json"

    # Boot restoration and refresh share ownership of the table and cache.
    with (state / "lock").open("w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        if mode == "restore":
            install(template, json.loads(cache.read_text()) if cache.exists() else {})
            return
        if mode != "update":
            raise ValueError(f"Unknown mode: {mode}")

        # Spamhaus requires automated downloads to be at least an hour apart.
        attempted = state / "last-attempt"
        if attempted.exists() and time.time() - attempted.stat().st_mtime < 3600:
            print("Spamhaus DROP was checked within the last hour; skipping")
            return
        attempted.touch()

        base = os.environ["SPAMHAUS_URL_BASE"].rstrip("/")
        feeds = {}
        for version in (4, 6):
            request = urllib.request.Request(
                f"{base}/drop_v{version}.json", headers={"User-Agent": "gateway-spamhaus-drop"}
            )
            with urllib.request.urlopen(request, timeout=30) as response:
                data = response.read(8 * 1024 * 1024 + 1)
            if len(data) > 8 * 1024 * 1024:
                raise ValueError(f"IPv{version} feed exceeds size limit")
            feeds[str(version)] = data.decode("utf-8")

        # Keep the original metadata, including Spamhaus's date and copyright.
        with tempfile.NamedTemporaryFile(mode="w", dir=state, delete=False) as pending:
            pending_path = Path(pending.name)
            try:
                json.dump(feeds, pending)
                pending.flush()
                os.fsync(pending.fileno())
                install(template, feeds)
                os.replace(pending_path, cache)
                directory = os.open(state, os.O_RDONLY | os.O_DIRECTORY)
                try:
                    os.fsync(directory)
                finally:
                    os.close(directory)
            finally:
                pending_path.unlink(missing_ok=True)


if __name__ == "__main__":
    main()
