from __future__ import annotations

import hashlib
import shutil
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from create_frs_deployment_bundle import BundleError, verify_linux_manifest, verify_route, verify_uimage


FAILING_TIMING = """\
| Device       : 7z020-clg400
Timing constraints are not met.
check_timing report
checking no_clock (0)
checking unconstrained_internal_endpoints (0)
checking no_input_delay (0)
checking no_output_delay (0)
checking partial_input_delay (0)
checking partial_output_delay (0)
Design Timing Summary
WNS(ns) TNS(ns) TNS Failing Endpoints TNS Total Endpoints WHS(ns) THS(ns) THS Failing Endpoints THS Total Endpoints WPWS(ns) TPWS(ns) TPWS Failing Endpoints TPWS Total Endpoints
-0.100 -0.200 2 100 -0.500 -2.000 4 100 0.100 0.000 0 100
"""
PASSING_DRC = """\
Report DRC
REPORT SUMMARY
"""


class DeploymentBundleGateTests(unittest.TestCase):
    def test_rejects_latest_known_hold_failing_candidate(self) -> None:
        # Regression guard: write_bitstream completed, but routed hold slack is
        # negative. Use an inline report so clean CI does not depend on ignored
        # local Vivado output. A .bit file alone is never deployable.
        with tempfile.TemporaryDirectory() as tmp:
            route = Path(tmp)
            (route / "reports").mkdir()
            (route / "system_top.bit").write_bytes(b"synthetic routed image")
            (route / "reports/frs_impl_timing.rpt").write_text(FAILING_TIMING)
            (route / "reports/frs_impl_drc.rpt").write_text(PASSING_DRC)
            (route / "build-metadata.txt").write_text(
                "FRS_TEST_MODE=0\nSOURCE_SHA=" + "a" * 40 + "\n"
            )
            sums = []
            for relative in ("system_top.bit", "reports/frs_impl_timing.rpt", "reports/frs_impl_drc.rpt"):
                sums.append(f"{hashlib.sha256((route / relative).read_bytes()).hexdigest()}  {relative}")
            (route / "SHA256SUMS").write_text("\n".join(sums) + "\n")
            with self.assertRaisesRegex(BundleError, "WHS|hold slack|constraints|critical DRC"):
                verify_route(route)

    def test_rejects_missing_route_hash_manifest(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            route = Path(tmp)
            (route / "system_top.bit").write_bytes(b"bit")
            (route / "reports").mkdir()
            (route / "reports/frs_impl_timing.rpt").write_text("timing")
            (route / "reports/frs_impl_drc.rpt").write_text("drc")
            (route / "build-metadata.txt").write_text("FRS_TEST_MODE=0\nSOURCE_SHA=" + "a" * 40 + "\n")
            with self.assertRaisesRegex(BundleError, "SHA256SUMS"):
                verify_route(route)

    def test_rejects_nonmatching_route_image_hash(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            route = Path(tmp)
            (route / "reports").mkdir()
            (route / "system_top.bit").write_bytes(b"changed image")
            (route / "reports/frs_impl_timing.rpt").write_text("timing")
            (route / "reports/frs_impl_drc.rpt").write_text("drc")
            (route / "build-metadata.txt").write_text(
                "FRS_TEST_MODE=0\nSOURCE_SHA=" + "a" * 40 + "\n"
            )
            (route / "SHA256SUMS").write_text(
                f"{'0' * 64}  system_top.bit\n"
                f"{hashlib.sha256(b'timing').hexdigest()}  reports/frs_impl_timing.rpt\n"
                f"{hashlib.sha256(b'drc').hexdigest()}  reports/frs_impl_drc.rpt\n"
            )
            with self.assertRaisesRegex(BundleError, "checksum mismatch"):
                verify_route(route)

    def test_rejects_linux_manifest_that_only_built_dtb(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            uimage = root / "uImage"
            dtb = root / "devicetree.dtb"
            manifest = root / "manifest.json"
            uimage.write_bytes(b"kernel")
            dtb.write_bytes(b"dtb")
            manifest.write_text('{"status":"DTB_ONLY","kernel_built":false}')
            with self.assertRaisesRegex(BundleError, "completed kernel build"):
                verify_linux_manifest(manifest, uimage, dtb)

    def test_rejects_non_uimage_kernel(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            kernel = Path(tmp) / "uImage"
            kernel.write_bytes(b"not an ARM uImage".ljust(80, b"\0"))
            with self.assertRaisesRegex(BundleError, "uImage"):
                verify_uimage(kernel)


if __name__ == "__main__":
    unittest.main()
