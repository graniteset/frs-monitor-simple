#!/usr/bin/env python3
"""Fail-closed parser/gate for Vivado routed timing and DRC reports."""

from __future__ import annotations

import argparse
from pathlib import Path
import re
import sys


TIMING_COLUMNS = re.compile(
    r"WNS\(ns\)\s+TNS\(ns\)\s+TNS Failing Endpoints\s+TNS Total Endpoints\s+"
    r"WHS\(ns\)\s+THS\(ns\)\s+THS Failing Endpoints\s+THS Total Endpoints"
)
NUMBERS = re.compile(r"[-+]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][-+]?\d+)?")


def check_timing(path: Path) -> list[str]:
    text = path.read_text(errors="replace")
    errors: list[str] = []
    if "Design Timing Summary" not in text or "Timing constraints are met." not in text:
        errors.append("Vivado did not report that timing constraints are met")

    section_start = text.find("Design Timing Summary")
    summary = text[section_start:] if section_start >= 0 else ""
    header = TIMING_COLUMNS.search(summary)
    if not header:
        errors.append("could not parse the Design Timing Summary WNS/TNS/WHS/THS columns")
    else:
        tail = summary[header.end():]
        for line in tail.splitlines():
            values = NUMBERS.findall(line)
            # Expected 12 numeric cells: eight setup/hold values then pulse-width cells.
            if len(values) >= 12:
                try:
                    wns, tns = float(values[0]), float(values[1])
                    tns_failing = int(values[2])
                    whs, ths = float(values[4]), float(values[5])
                    ths_failing = int(values[6])
                except ValueError:
                    continue
                if wns < 0:
                    errors.append(f"routed worst setup slack is negative: {wns:.3f} ns")
                if whs < 0:
                    errors.append(f"routed worst hold slack is negative: {whs:.3f} ns")
                if abs(tns) > 1e-12 or tns_failing != 0:
                    errors.append(f"routed setup violations remain: TNS={tns:g} ns, endpoints={tns_failing}")
                if abs(ths) > 1e-12 or ths_failing != 0:
                    errors.append(f"routed hold violations remain: THS={ths:g} ns, endpoints={ths_failing}")
                break
        else:
            errors.append("could not parse the Design Timing Summary data row")

    # Do not silently accept partially/unconstrained I/O or unconstrained internal paths.
    checks = (
        "no_clock",
        "unconstrained_internal_endpoints",
        "no_input_delay",
        "no_output_delay",
        "partial_input_delay",
        "partial_output_delay",
    )
    for check in checks:
        match = re.search(rf"checking {re.escape(check)}\s*\((\d+)\)", text)
        if not match:
            errors.append(f"timing report does not include check_timing result for {check}")
        elif int(match.group(1)) != 0:
            errors.append(f"unreviewed/unconstrained timing paths: {check}={match.group(1)}")
    return errors


def check_drc(path: Path) -> list[str]:
    text = path.read_text(errors="replace")
    if "Report DRC" not in text or "REPORT SUMMARY" not in text:
        return ["Vivado DRC report is missing its report summary"]
    errors: list[str] = []
    for line in text.splitlines():
        if not re.search(r"\|\s*(?:Critical Warning|Error)\s*\|", line, re.IGNORECASE):
            continue
        if re.search(r"\|\s*(?:Critical Warning|Error)\s*\|\s*[^|]+\|\s*(\d+)", line, re.IGNORECASE):
            count = int(re.search(r"\|\s*(?:Critical Warning|Error)\s*\|\s*[^|]+\|\s*(\d+)", line, re.IGNORECASE).group(1))
            if count:
                errors.append(f"critical DRC/error severity remains: {line.strip()}")
        elif re.search(r"\|\s*(?:Critical Warning|Error)\s*\|", line, re.IGNORECASE):
            errors.append(f"unparseable critical DRC/error row: {line.strip()}")
    return errors


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--timing", required=True, type=Path)
    parser.add_argument("--drc", required=True, type=Path)
    parser.add_argument("--summary", required=True, type=Path)
    args = parser.parse_args()
    failures = []
    for label, path in (("timing", args.timing), ("DRC", args.drc)):
        if not path.is_file() or path.stat().st_size == 0:
            failures.append(f"required {label} report missing or empty: {path}")
    if not failures:
        failures.extend(check_timing(args.timing))
        failures.extend(check_drc(args.drc))

    args.summary.parent.mkdir(parents=True, exist_ok=True)
    lines = ["FRS routed build acceptance gate", "", "PASS" if not failures else "FAIL"]
    lines.extend(f"- {failure}" for failure in failures)
    args.summary.write_text("\n".join(lines) + "\n", encoding="utf-8")
    print("\n".join(lines))
    return 0 if not failures else 1


if __name__ == "__main__":
    raise SystemExit(main())
