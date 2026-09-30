from __future__ import annotations

from pathlib import Path
import unittest


BUILD_SCRIPT = (
    Path(__file__).resolve().parents[1]
    / "fpga/plutosky_r2/build_frs_dma_image.tcl"
)


class VivadoSourcePathCleanupTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.script = BUILD_SCRIPT.read_text(encoding="utf-8")

    def test_stale_timing_constraint_is_removed_before_current_one_is_added(self) -> None:
        lookup = 'set stale_timing_xdcs [get_files -all -quiet -filter {NAME =~ "*clg400_ad936x_provisional_io_timing.xdc"}]'
        remove = "remove_files $stale_timing_xdcs"
        add = "add_files -fileset constrs_1 -norecurse $timing_xdc"

        self.assertIn(lookup, self.script)
        self.assertIn("if {[llength $stale_timing_xdcs]} {", self.script)
        self.assertIn(remove, self.script)
        self.assertLess(self.script.index(lookup), self.script.index(remove))
        self.assertLess(self.script.index(remove), self.script.index(add))
        self.assertIn('set timing_xdc [file join $script_dir clg400_ad936x_provisional_io_timing.xdc]', self.script)

    def test_generated_clock_assertions_read_synthesis_consumed_gen_tree(self) -> None:
        self.assertIn(
            "frs_clg400_frs.gen sources_1 bd system ipshared", self.script
        )
        self.assertIn("system_axi_ad9361_0 system_axi_ad9361_0.xml", self.script)
        self.assertIn('set metadata_reference "../../ipshared/$source_relative"', self.script)
        self.assertNotIn("frs_clg400_frs.ip_user_files bd system ipshared", self.script)
        self.assertIn("Generated AXI_AD9361 sources do not use the required BUFIO RX capture clock", self.script)


if __name__ == "__main__":
    unittest.main()
