from __future__ import annotations

import tempfile
import unittest
from pathlib import Path

from ci.check_vivado_route_reports import check_drc, check_timing


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

    def test_rejects_negative_hold_and_unconstrained_output(self) -> None:
        broken = PASS_TIMING.replace("0.050        0.000", "-0.010       -0.010")
        broken = broken.replace("no_output_delay (0)", "no_output_delay (3)")
        with tempfile.TemporaryDirectory() as temp:
            errors = check_timing(self.write(Path(temp), "timing.rpt", broken))
        self.assertTrue(any("hold slack" in error for error in errors), errors)
        self.assertTrue(any("no_output_delay=3" in error for error in errors), errors)

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
