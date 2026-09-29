from __future__ import annotations

import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
ADD_SOURCES = (ROOT / "fpga/plutosky_r2/add_frs_sources.tcl").read_text(
    encoding="utf-8"
)
BUILD = (ROOT / "fpga/plutosky_r2/build_frs_dma_image.tcl").read_text(
    encoding="utf-8"
)


class VivadoSourcePathCleanupTests(unittest.TestCase):
    def test_owned_source_and_coefficient_paths_are_replaced_before_adding(self) -> None:
        cleanup = ADD_SOURCES.index("remove_files -fileset sources_1 $existing")
        add_sources = ADD_SOURCES.index("add_files -norecurse -fileset sources_1 $source_paths")
        add_coefficients = ADD_SOURCES.index("add_files -norecurse -fileset sources_1 $coeff_paths")
        self.assertLess(cleanup, add_sources)
        self.assertLess(cleanup, add_coefficients)
        self.assertIn("[concat $rtl_rel $coeff_rel]", ADD_SOURCES)
        self.assertIn("[file tail $existing_name]", ADD_SOURCES)

    def test_stale_timing_constraint_is_removed_before_current_one_is_added(self) -> None:
        cleanup = BUILD.index("remove_files -fileset constrs_1 $existing_xdc")
        add_timing = BUILD.index("add_files -fileset constrs_1 -norecurse $timing_xdc")
        self.assertLess(cleanup, add_timing)
        self.assertIn("[file tail [get_property NAME $existing_xdc]]", BUILD)


if __name__ == "__main__":
    unittest.main()
