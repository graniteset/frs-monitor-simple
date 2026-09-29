import json
from pathlib import Path
import tempfile
import unittest

from ci.create_sdr_hil_manifest import write_manifest


class HILManifestTests(unittest.TestCase):
    def test_profiles_are_fail_closed_without_routed_reports(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            (root / "fpga").mkdir()
            (root / "fpga/core.sv").write_text("module core; endmodule\n")
            (root / "web_go").mkdir()
            (root / "web_go/go.mod").write_text("module sample\n")
            output = root / "artifacts"
            manifest = write_manifest(root, output, None)

            self.assertEqual(
                [(item["profile"], item["frs_test_mode"]) for item in manifest["fpga_profiles"]],
                [("live-ad9363", 0), ("synthetic-iq", 1)],
            )
            for item in manifest["fpga_profiles"]:
                self.assertIsNone(item["bitstream"])
                self.assertFalse(item["deployable"])
                self.assertEqual(item["timing"]["status"], "not_evaluated_for_this_commit")
                self.assertEqual(item["timing"]["deploy_gate"], "blocked")
            self.assertFalse(manifest["deployment"]["sd_write"])
            self.assertFalse(manifest["deployment"]["reboot"])
            self.assertTrue((output / "SHA256SUMS").is_file())

    def test_arm_binary_is_hashed_but_not_marked_deployable(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            (root / "fpga").mkdir()
            (root / "web_go").mkdir()
            output = root / "artifacts"
            binary = output / "armv7/frs-web-armv7"
            binary.parent.mkdir(parents=True)
            binary.write_bytes(b"candidate binary")
            manifest = write_manifest(root, output, binary)
            info = manifest["go_armv7_server"]
            self.assertFalse(info["deployable"])
            self.assertEqual(len(info["sha256"]), 64)
            self.assertIn("GOARM=7", info["target"])


if __name__ == "__main__":
    unittest.main()
