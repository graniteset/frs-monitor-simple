from __future__ import annotations

import subprocess
import tempfile
import unittest
from pathlib import Path


REPO = Path(__file__).resolve().parents[1]
PATCH_TCL = REPO / "fpga/plutosky_r2/apply_clg400_bufio_capture.tcl"


class Clg400BufioPatchTests(unittest.TestCase):
    def make_adi_fixture(
        self, root: Path, *, modern_header: bool = False, prepatched: bool = False
    ) -> tuple[Path, bytes, bytes]:
        catalog = root / "work" / "adi-source"
        clock = catalog / "xilinx/common/ad_data_clk.v"
        lvds = catalog / "axi_ad9361/xilinx/axi_ad9361_lvds_if.v"
        clock.parent.mkdir(parents=True)
        lvds.parent.mkdir(parents=True)
        if prepatched:
            clock_declaration = """module ad_data_clk #(
  parameter SINGLE_ENDED = 0
) (
  input clk_in_p,
  input clk_in_n,
  output clk,
  output clk_io
);
  wire clk_ibuf_s;
  IBUFDS i_rx_clk_ibuf (
    .I (clk_in_p),
    .IB (clk_in_n),
    .O (clk_ibuf_s));
  BUFIO i_rx_clk_bufio (
    .I (clk_ibuf_s),
    .O (clk_io));
  BUFG i_clk_gbuf (
    .I (clk_ibuf_s),
    .O (clk));
endmodule
"""
        elif modern_header:
            clock_declaration = """module ad_data_clk #(
  parameter SINGLE_ENDED = 0
) (
  input clk_in_p,
  input clk_in_n,
  output clk
);
  wire clk_ibuf_s;
  IBUFGDS i_rx_clk_ibuf (
    .I (clk_in_p),
    .IB (clk_in_n),
    .O (clk_ibuf_s));
  BUFG i_clk_gbuf (
    .I (clk_ibuf_s),
    .O (clk));
endmodule
"""
        else:
            clock_declaration = """module ad_data_clk (
  input clk_in_p,
  input clk_in_n,
  output              clk);
  generate
  if (SINGLE_ENDED == 1) begin
  IBUFG i_rx_clk_ibuf (
    .I (clk_in_p),
    .O (clk_ibuf_s));
  end else begin
  IBUFGDS i_rx_clk_ibuf (
    .I (clk_in_p),
    .IB (clk_in_n),
    .O (clk_ibuf_s));
  end
  endgenerate

  BUFG i_clk_gbuf (
    .I (clk_ibuf_s),
    .O (clk));
endmodule
"""
        clock.write_text(
            clock_declaration,
            encoding="utf-8",
        )
        lvds.write_text(
            """module axi_ad9361_lvds_if;
  wire                locked_s;
  ad_data_in i_rx_data (
    .rx_clk (l_clk),
    .data (rx_data));
  ad_data_in i_rx_frame (
    .rx_clk (l_clk),
    .data (rx_frame));
  ad_data_clk i_clk (
    .clk (l_clk));
  end else begin
    assign l_clk = clk;
  end
endmodule
""",
            encoding="utf-8",
        )
        return catalog, clock.read_bytes(), lvds.read_bytes()

    def run_patch(self, catalog: Path, work_root: Path) -> Path:
        # Tcl paths in our temporary directories contain no quote characters.
        script = (
            f"source {{{PATCH_TCL}}}\n"
            f"if {{[catch {{frs_make_clg400_bufio_catalog {{{catalog}}} {{{work_root}}}}} path]}} {{puts stderr $path; exit 1}}\n"
            "puts $path\n"
        )
        result = subprocess.run(
            ["tclsh"], input=script, text=True, capture_output=True, check=False
        )
        self.assertEqual(result.returncode, 0, result.stderr or result.stdout)
        return Path(result.stdout.strip().splitlines()[-1])

    def test_creates_bufio_overlay_and_preserves_staged_catalog(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            work = root / "work"
            catalog, original_clock, original_lvds = self.make_adi_fixture(root)
            overlay = self.run_patch(catalog, work)

            patched_clock = (overlay / "xilinx/common/ad_data_clk.v").read_text()
            patched_lvds = (overlay / "axi_ad9361/xilinx/axi_ad9361_lvds_if.v").read_text()
            self.assertIn("BUFIO i_rx_clk_bufio", patched_clock)
            self.assertIn("output              clk_io", patched_clock)
            self.assertNotIn("IBUFGDS i_rx_clk_ibuf", patched_clock)
            self.assertEqual(patched_lvds.count(".rx_clk (l_clk_io)"), 2)
            self.assertIn(".clk_io (l_clk_io)", patched_lvds)
            self.assertIn("assign l_clk_io = clk", patched_lvds)
            self.assertEqual((catalog / "xilinx/common/ad_data_clk.v").read_bytes(), original_clock)
            self.assertEqual(
                (catalog / "axi_ad9361/xilinx/axi_ad9361_lvds_if.v").read_bytes(),
                original_lvds,
            )

    def test_handles_current_plutosky_split_line_port_declaration(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            work = root / "work"
            catalog, _, _ = self.make_adi_fixture(root, modern_header=True)
            overlay = self.run_patch(catalog, work)
            clock = (overlay / "xilinx/common/ad_data_clk.v").read_text()
            self.assertIn("  output clk,\n  output              clk_io\n);", clock)
            self.assertIn("BUFIO i_rx_clk_bufio", clock)

    def test_accepts_and_preserves_an_already_patched_staged_catalog(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            work = root / "work"
            catalog, _, _ = self.make_adi_fixture(root, prepatched=True)
            original_clock = (catalog / "xilinx/common/ad_data_clk.v").read_bytes()
            overlay = self.run_patch(catalog, work)
            patched_clock = overlay / "xilinx/common/ad_data_clk.v"
            self.assertEqual(patched_clock.read_bytes(), original_clock)
            self.assertEqual((catalog / "xilinx/common/ad_data_clk.v").read_bytes(), original_clock)

    def test_rejects_unexpected_adi_source_layout_without_mutating_it(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            work = root / "work"
            catalog = work / "adi-source"
            catalog.mkdir(parents=True)
            result = subprocess.run(
                ["tclsh"],
                input=(
                    f"source {{{PATCH_TCL}}}\n"
                    f"if {{[catch {{frs_make_clg400_bufio_catalog {{{catalog}}} {{{work}}}}} message]}} {{puts stderr $message; exit 1}}\n"
                ),
                text=True,
                capture_output=True,
                check=False,
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("Required ADI source is missing", result.stderr)
            self.assertFalse(list(work.glob("adi_ip_bufio_*")))


if __name__ == "__main__":
    unittest.main()
