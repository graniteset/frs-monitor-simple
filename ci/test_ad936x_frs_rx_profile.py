#!/usr/bin/env python3
"""Safety tests for the temporary AD936x RX-profile wrapper (mock IIO only)."""

import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
WRAPPER = ROOT / "ci" / "with_ad936x_frs_rx_profile.sh"
INITIAL = {
    "ad9361-phy/altvoltage0/frequency": "2400000000",
    "ad9361-phy/voltage0/sampling_frequency": "30720000",
    "ad9361-phy/voltage0/rf_bandwidth": "18000000",
    "ad9361-phy/voltage0/gain_control_mode": "slow_attack",
    "ad9361-phy/voltage0/hardwaregain": "12.000000",
}


MOCK_IIO_ATTR = r'''#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
args = sys.argv[1:]
flags = []
while args and args[0] in ("-q", "-i", "-o", "-s"):
    flags.append(args.pop(0))
if not args or args.pop(0) != "-u": raise SystemExit("bad option syntax")
uri = args.pop(0)
if not uri: raise SystemExit("missing URI")
while args and args[0] in ("-q", "-i", "-o", "-s"):
    flags.append(args.pop(0))
kind = args.pop(0)
if kind == "-d":
    device, attr = args.pop(0), args.pop(0)
    key = f"{device}/{attr}"
elif kind == "-c":
    device, channel, attr = args.pop(0), args.pop(0), args.pop(0)
    if channel == "voltage0" and "-i" not in flags:
        raise SystemExit("voltage0 is ambiguous without input-channel filter")
    key = f"{device}/{channel}/{attr}"
else:
    raise SystemExit("expected -d or -c")
if len(args) > 1: raise SystemExit("too many arguments")
state_path, log_path = Path(os.environ["MOCK_IIO_STATE"]), Path(os.environ["MOCK_IIO_LOG"])
state = json.loads(state_path.read_text())
log = json.loads(log_path.read_text())
if args:
    state[key] = args[0]
    log.append(["write", key, args[0], flags])
    state_path.write_text(json.dumps(state))
else:
    log.append(["read", key])
    print(state[key])
log_path.write_text(json.dumps(log))
'''


class Ad936xProfileTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.tmpdir = Path(self.tmp.name)
        self.bin = self.tmpdir / "bin"
        self.bin.mkdir()
        fake_attr = self.bin / "iio_attr"
        fake_attr.write_text(MOCK_IIO_ATTR)
        fake_attr.chmod(0o755)
        fake_readdev = self.bin / "iio_readdev"
        fake_readdev.write_text("#!/bin/sh\nexit 0\n")
        fake_readdev.chmod(0o755)
        self.state = self.tmpdir / "state.json"
        self.log = self.tmpdir / "log.json"
        self.state.write_text(json.dumps(INITIAL))
        self.log.write_text("[]")
        self.env = os.environ.copy()
        self.env.update({
            "PATH": f"{self.bin}:{self.env['PATH']}",
            "MOCK_IIO_STATE": str(self.state),
            "MOCK_IIO_LOG": str(self.log),
        })

    def run_wrapper(self, *args):
        return subprocess.run(
            [str(WRAPPER), "--uri", "usb:", *args],
            env=self.env, text=True, capture_output=True, check=False,
        )

    def test_read_only_preflight_does_not_write(self):
        result = self.run_wrapper("--", sys.executable, "-c", "pass")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(self.state.read_text()), INITIAL)
        log = json.loads(self.log.read_text())
        self.assertTrue(log)
        self.assertFalse(any(item[0] == "write" for item in log))
        self.assertIn("slow_attack", result.stdout)

    def test_apply_runs_command_and_restores_radio_settings(self):
        result = self.run_wrapper("--apply", "--", sys.executable, "-c", "pass")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(self.state.read_text()), INITIAL)
        writes = [item[1:] for item in json.loads(self.log.read_text()) if item[0] == "write"]
        self.assertEqual(writes, [
            ["ad9361-phy/voltage0/rf_bandwidth", "5600000", ["-i", "-q"]],
            ["ad9361-phy/voltage0/sampling_frequency", "6400000", ["-i", "-q"]],
            ["ad9361-phy/altvoltage0/frequency", "465125000", ["-q"]],
            ["ad9361-phy/voltage0/sampling_frequency", "30720000", ["-i", "-q"]],
            ["ad9361-phy/voltage0/rf_bandwidth", "18000000", ["-i", "-q"]],
            ["ad9361-phy/altvoltage0/frequency", "2400000000", ["-q"]],
        ])
        self.assertFalse(any("gain_control_mode" in item[0] or "hardwaregain" in item[0]
                             for item in writes))

    def test_command_failure_still_restores_radio_settings(self):
        result = self.run_wrapper(
            "--apply", "--", sys.executable, "-c", "raise SystemExit(7)"
        )
        self.assertEqual(result.returncode, 7, result.stderr)
        self.assertEqual(json.loads(self.state.read_text()), INITIAL)
        self.assertIn("restored and verified", result.stderr)


if __name__ == "__main__":
    unittest.main()
