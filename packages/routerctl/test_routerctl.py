"""Exercise the public CLI's validation and subprocess reporting contract."""

import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


class Reports(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.bin = Path(self.directory.name)
        self.environment = dict(os.environ, PATH=str(self.bin))

    def executable(self, name, code):
        executable = self.bin / name
        executable.write_text(f"#!{sys.executable}\n" + code)
        executable.chmod(0o755)

    def cli(self, *arguments):
        return subprocess.run(
            [sys.executable, str(Path(__file__).with_name("routerctl.py")), "--json", *arguments],
            env=self.environment, text=True, capture_output=True, timeout=15,
        )

    def test_failure(self):
        self.executable("nft", "import sys\nprint('inspection denied', file=sys.stderr)\nsys.exit(7)\n")
        result = self.cli("firewall")
        report = json.loads(result.stdout)

        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(report["incomplete"])
        self.assertEqual(report["results"][0]["returncode"], 7)
        self.assertIn("inspection denied", report["results"][0]["output"])

    def test_limit(self):
        self.executable("nft", "import sys\nsys.stdout.write('x' * (3 * 1024 * 1024))\n")
        result = self.cli("firewall")
        report = json.loads(result.stdout)

        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(report["incomplete"])
        self.assertTrue(report["results"][0]["truncated"])
        self.assertEqual(len(report["results"][0]["output"]), 2 * 1024 * 1024)

    def test_timeout(self):
        self.executable("nft", "import time\nprint('waiting', flush=True)\ntime.sleep(60)\n")
        result = self.cli("firewall")
        report = json.loads(result.stdout)

        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(report["incomplete"])
        self.assertTrue(report["results"][0]["timed_out"])
        self.assertIn("waiting", report["results"][0]["output"])

    def test_target(self):
        marker = self.bin / "executed"
        self.executable("vtysh", f"from pathlib import Path\nPath({str(marker)!r}).touch()\n")

        for target in ("10.0.0.1; clear bgp *", "10.0.0.1\nclear bgp *", "fe80::1%eth0"):
            with self.subTest(target=target):
                result = self.cli("bgp-neighbors", target)
                self.assertEqual(result.returncode, 2)
                self.assertFalse(marker.exists())


if __name__ == "__main__":
    unittest.main()
