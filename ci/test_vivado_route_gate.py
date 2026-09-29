from __future__ import annotations

import tempfile
import unittest
from pathlib import Path

from ci.check_vivado_route_reports import check_drc, check_output_delay_exceptions, check_timing


PASS_TIMING = """\
Design Timing Summary
    WNS(ns)      TNS(ns)  TNS Failing Endpoints  TNS Total Endpoints      WHS(ns)      THS(ns)  THS Failing Endpoints  THS Total Endpoints     WPWS(ns)     TPWS(ns)  TPWS Failing Endpoints  TPWS Total Endpoints
    -------      -------  ---------------------  -------------------      -------      -------  ---------------------  -------------------     --------     --------  ----------------------  --------------------
      0.100        0.000                      0                 10000        0.050        0.000                      0                10000        0.200        0.000                       0                 10000
Timing constraints are met.
1. checking no_clock (0)
2. checking unconstrained_internal_endpoints (0)
3. checking no_input_delay (0)
4. checking no_output_delay (0)
5. checking partial_input_delay (0)
6. checking partial_output_delay (0)

4. checking no_output_delay (0)
-------------------------------
 There are 0 ports with no output delay specified. (HIGH)

 There are 0 ports with no output delay but with a timing clock defined on it or propagating through it (LOW)

 There are 0 ports with no output delay but user has a false path constraint
"""

TIMING_WITH_DOCUMENTED_EXCEPTIONS = PASS_TIMING.replace(
    "no_output_delay (0)", "no_output_delay (3)"
).replace(
    "There are 0 ports with no output delay specified. (HIGH)",
    "There are 2 ports with no output delay specified. (HIGH)\n\nenable\ntxnrx",
).replace(
    "There are 0 ports with no output delay but with a timing clock defined on it or propagating through it (LOW)",
    "There is 1 port with no output delay but with a timing clock defined on it or propagating through it (LOW)\n\ntx_clk_out_p",
).replace(
    "Timing constraints are met.",
    "Timing constraints are met.\n\n"
    "| Clock Summary\n| -------------\n"
    "Clock              Waveform(ns)         Period(ns)      Frequency(MHz)\n"
    "-----              ------------         ----------      --------------\n"
    "rx_clk             {0.000 19.531}       39.063          25.600\n"
    "  tx_fb_clk        {19.531 39.063}      39.063          25.600\n\n"
    "| Intra Clock Table",
)

PASS_CONSTRAINTS = """\
# expected source-synchronous AD9363 feedback clock
create_generated_clock -name tx_fb_clk -source [get_ports rx_clk_in_p] \\
  -divide_by 1 -invert [get_ports tx_clk_out_p]
"""

PASS_DRC = """\
Report DRC
1. REPORT SUMMARY
| Rule | Severity | Description | Checks |
|------|----------|-------------|--------|
| LUTAR-1 | Warning | harmless warning | 1 |
"""


class VivadoRouteGateTests(unittest.TestCase):
    def write(self, root: Path, name: str, text: str) -> Path:
        path = root / name
        path.write_text(text, encoding="utf-8")
        return path

    def test_accepts_positive_slack_zero_violations_and_constrained_paths(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            self.assertEqual(check_timing(self.write(root, "timing.rpt", PASS_TIMING)), [])

    def test_accepts_only_the_documented_control_and_generated_feedback_clock_outputs(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            timing = self.write(root, "timing.rpt", TIMING_WITH_DOCUMENTED_EXCEPTIONS)
            constraints = self.write(root, "timing.xdc", PASS_CONSTRAINTS)
            self.assertEqual(check_timing(timing, constraints), [])
            errors, notes = check_output_delay_exceptions(timing.read_text(), constraints)
            self.assertEqual(errors, [])
            self.assertTrue(any("enable and txnrx" in note and "tx_fb_clk" in note for note in notes), notes)

    def test_rejects_any_additional_unconstrained_output(self) -> None:
        broken = TIMING_WITH_DOCUMENTED_EXCEPTIONS.replace(
            "enable\ntxnrx", "enable\ntxnrx\nfrs_audio_out"
        ).replace("no_output_delay (3)", "no_output_delay (4)")
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            errors = check_timing(
                self.write(root, "timing.rpt", broken),
                self.write(root, "timing.xdc", PASS_CONSTRAINTS),
            )
        self.assertTrue(any("frs_audio_out" in error for error in errors), errors)

    def test_rejects_another_unconstrained_output_with_a_clock(self) -> None:
        broken = TIMING_WITH_DOCUMENTED_EXCEPTIONS.replace(
            "tx_clk_out_p", "mystery_clock_out"
        )
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            errors = check_timing(
                self.write(root, "timing.rpt", broken),
                self.write(root, "timing.xdc", PASS_CONSTRAINTS),
            )
        self.assertTrue(any("mystery_clock_out" in error for error in errors), errors)

    def test_rejects_feedback_clock_exception_without_matching_generated_clock_constraint(self) -> None:
        wrong_xdc = PASS_CONSTRAINTS.replace("-invert [get_ports tx_clk_out_p]", "[get_ports tx_clk_out_p]")
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            errors = check_timing(
                self.write(root, "timing.rpt", TIMING_WITH_DOCUMENTED_EXCEPTIONS),
                self.write(root, "timing.xdc", wrong_xdc),
            )
        self.assertTrue(any("not verified as the generated inverted tx_fb_clk" in error for error in errors), errors)

    def test_rejects_feedback_clock_exception_if_report_does_not_show_rx_inverted_waveform(self) -> None:
        wrong_timing = TIMING_WITH_DOCUMENTED_EXCEPTIONS.replace(
            "{19.531 39.063}      39.063", "{0.000 19.531}       39.063"
        )
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            errors = check_timing(
                self.write(root, "timing.rpt", wrong_timing),
                self.write(root, "timing.xdc", PASS_CONSTRAINTS),
            )
        self.assertTrue(any("not verified as the generated inverted tx_fb_clk" in error for error in errors), errors)

    def test_rejects_unconstrained_outputs_exempted_by_false_path(self) -> None:
        broken = TIMING_WITH_DOCUMENTED_EXCEPTIONS.replace(
            "There are 0 ports with no output delay but user has a false path constraint",
            "There is 1 port with no output delay but user has a false path constraint\n\nunsafe_output",
        ).replace("no_output_delay (3)", "no_output_delay (4)")
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            errors = check_timing(
                self.write(root, "timing.rpt", broken),
                self.write(root, "timing.xdc", PASS_CONSTRAINTS),
            )
        self.assertTrue(any("false-path" in error for error in errors), errors)

    def test_rejects_negative_hold_and_unconstrained_output(self) -> None:
        broken = PASS_TIMING.replace("0.050        0.000", "-0.010       -0.010")
        broken = broken.replace("no_output_delay (0)", "no_output_delay (3)")
        with tempfile.TemporaryDirectory() as temp:
            errors = check_timing(self.write(Path(temp), "timing.rpt", broken))
        self.assertTrue(any("hold slack" in error for error in errors), errors)
        self.assertTrue(any("no_output_delay count mismatch" in error for error in errors), errors)

    def test_rejects_critical_drc_and_errors(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            path = self.write(
                Path(temp),
                "drc.rpt",
                PASS_DRC.replace(
                    "| LUTAR-1 | Warning | harmless warning | 1 |",
                    "| RULE-1 | Critical Warning | must be reviewed | 1 |",
                ),
            )
            self.assertTrue(check_drc(path))

    def test_rejects_missing_or_unparseable_summary(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            errors = check_timing(self.write(Path(temp), "timing.rpt", "no timing data"))
        self.assertTrue(errors)


if __name__ == "__main__":
    unittest.main()
