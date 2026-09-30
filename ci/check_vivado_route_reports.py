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
EXPECTED_NO_OUTPUT_DELAY_CONTROLS = {"enable", "txnrx"}
EXPECTED_CLOCK_OUTPUT = "tx_clk_out_p"
EXPECTED_FEEDBACK_CLOCK = "tx_fb_clk"


def _section(text: str, heading: str) -> tuple[int, str] | None:
    """Return a numbered check_timing section's count and body, fail-closed."""
    matches = list(
        re.finditer(
            rf"(?m)^\s*\d+\.\s+checking {re.escape(heading)}\s*\((\d+)\)\s*$",
            text,
        )
    )
    # Vivado prints each result once in the table of contents and once with details.
    if len(matches) != 2:
        return None
    toc_count, detail_count = (int(match.group(1)) for match in matches)
    if toc_count != detail_count:
        return None
    next_section = re.search(r"(?m)^\s*\d+\.\s+checking ", text[matches[1].end():])
    end = matches[1].end() + next_section.start() if next_section else len(text)
    return detail_count, text[matches[1].end():end]


def _listed_ports(section: str, category: str) -> tuple[int, set[str]] | None:
    """Parse a Vivado check_timing category and the port names below it."""
    header = re.compile(
        rf"(?m)^\s*There (?:are|is) (\d+) ports? {re.escape(category)}[^\n]*\n"
    )
    matches = list(header.finditer(section))
    if len(matches) != 1:
        return None
    count = int(matches[0].group(1))
    ports: set[str] = set()
    for line in section[matches[0].end():].splitlines():
        value = line.strip()
        if not value:
            if ports:
                break
            continue
        # Port names in this section are bare identifiers, one per line.
        if not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*(?:\[[0-9]+\])?", value):
            break
        ports.add(value)
    return count, ports


def _has_generated_feedback_clock(timing_text: str, constraints_path: Path | None) -> bool:
    """Require agreement between checked-in XDC and Vivado's routed clock report."""
    if constraints_path is None or not constraints_path.is_file():
        return False
    constraints = constraints_path.read_text(errors="replace")
    # Strip comments and Tcl line continuations before matching the exact intended
    # generated-clock relation. A different source, target, clock name, or edge
    # relationship must not be silently classified as this exception.
    constraints = re.sub(r"(?m)#.*$", "", constraints).replace("\\\n", " ")
    expected = re.compile(
        r"(?m)^\s*create_generated_clock\s+-name\s+tx_fb_clk\s+"
        r"-source\s+\[get_ports\s+rx_clk_in_p\]\s+-divide_by\s+1\s+"
        r"-invert\s+\[get_ports\s+tx_clk_out_p\]\s*$"
    )
    if len(expected.findall(constraints)) != 1:
        return False

    clock_summary = re.search(
        r"(?ms)^\| Clock Summary\s*\n.*?^\| Intra Clock Table", timing_text
    )
    if not clock_summary:
        return False
    lines = clock_summary.group(0).splitlines()
    parent_rows = [line for line in lines if re.match(r"^rx_clk\s+\{", line)]
    child_rows = [line for line in lines if re.match(r"^\s+tx_fb_clk\s+\{", line)]
    if len(parent_rows) != 1 or len(child_rows) != 1:
        return False

    parent = re.match(
        r"^rx_clk\s+\{([\d.]+)\s+([\d.]+)\}\s+([\d.]+)", parent_rows[0]
    )
    child = re.match(
        r"^\s+tx_fb_clk\s+\{([\d.]+)\s+([\d.]+)\}\s+([\d.]+)", child_rows[0]
    )
    if not parent or not child:
        return False
    p_rise, p_fall, p_period = map(float, parent.groups())
    c_rise, c_fall, c_period = map(float, child.groups())
    tolerance = 0.002  # Vivado XDC/report time values are quantized to 1 ps.
    return (
        abs(c_period - p_period) <= tolerance
        and abs(c_rise - (p_fall - p_rise)) <= tolerance
        and abs(c_fall - p_period) <= tolerance
    )


def check_output_delay_exceptions(
    timing_text: str, constraints_path: Path | None = None
) -> tuple[list[str], list[str]]:
    """Gate the only approved no-output-delay cases; return errors and notes."""
    errors: list[str] = []
    notes: list[str] = []
    section_result = _section(timing_text, "no_output_delay")
    if section_result is None:
        return ["timing report does not include a parseable check_timing result for no_output_delay"], notes
    count, section = section_result
    plain = _listed_ports(section, "with no output delay specified")
    clocked = _listed_ports(section, "with no output delay but with a timing clock defined on it or propagating through it")
    false_path = _listed_ports(section, r"with no output delay but user has a false path constraint")
    if plain is None or clocked is None or false_path is None:
        return ["could not parse all no_output_delay port categories; refusing undocumented exceptions"], notes

    plain_count, plain_ports = plain
    clocked_count, clocked_ports = clocked
    false_count, false_ports = false_path
    for label, declared, ports in (
        ("plain output", plain_count, plain_ports),
        ("clocked output", clocked_count, clocked_ports),
        ("false-path output", false_count, false_ports),
    ):
        if declared != len(ports):
            errors.append(
                f"no_output_delay {label} count does not match its listed ports: "
                f"count={declared}, listed={len(ports)}"
            )
    if count != plain_count + clocked_count + false_count:
        errors.append(
            f"no_output_delay count mismatch: check_timing={count}, listed={plain_count + clocked_count + false_count}"
        )
    if count == 0 and not errors:
        return errors, notes
    if plain_ports != EXPECTED_NO_OUTPUT_DELAY_CONTROLS:
        errors.append(
            "unreviewed outputs without output delay: "
            + (", ".join(sorted(plain_ports)) or "none")
            + "; expected only enable and txnrx"
        )
    if false_count or false_ports:
        errors.append("no_output_delay includes ports accepted only because of false-path constraints")
    if clocked_ports != {EXPECTED_CLOCK_OUTPUT}:
        errors.append(
            "unreviewed outputs with a timing clock but no output delay: "
            + (", ".join(sorted(clocked_ports)) or "none")
            + f"; expected only {EXPECTED_CLOCK_OUTPUT}"
        )
    elif not _has_generated_feedback_clock(timing_text, constraints_path):
        errors.append(
            f"{EXPECTED_CLOCK_OUTPUT} is not verified as the generated inverted {EXPECTED_FEEDBACK_CLOCK} from rx_clk_in_p"
        )
    elif not errors:
        notes.append(
            f"documented no-output-delay exceptions: enable and txnrx (non-data controls); "
            f"{EXPECTED_CLOCK_OUTPUT} (generated inverted {EXPECTED_FEEDBACK_CLOCK})"
        )
    return errors, notes


def check_timing(path: Path, constraints_path: Path | None = None) -> list[str]:
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
        "partial_input_delay",
        "partial_output_delay",
    )
    for check in checks:
        match = re.search(rf"checking {re.escape(check)}\s*\((\d+)\)", text)
        if not match:
            errors.append(f"timing report does not include check_timing result for {check}")
        elif int(match.group(1)) != 0:
            errors.append(f"unreviewed/unconstrained timing paths: {check}={match.group(1)}")
    output_errors, _ = check_output_delay_exceptions(text, constraints_path)
    errors.extend(output_errors)
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
    parser.add_argument("--constraints", type=Path)
    parser.add_argument("--summary", required=True, type=Path)
    args = parser.parse_args()
    failures = []
    for label, path in (("timing", args.timing), ("DRC", args.drc)):
        if not path.is_file() or path.stat().st_size == 0:
            failures.append(f"required {label} report missing or empty: {path}")
    if not failures:
        failures.extend(check_timing(args.timing, args.constraints))
        failures.extend(check_drc(args.drc))
    timing_notes: list[str] = []
    if args.timing.is_file():
        _, timing_notes = check_output_delay_exceptions(
            args.timing.read_text(errors="replace"), args.constraints
        )

    args.summary.parent.mkdir(parents=True, exist_ok=True)
    lines = ["FRS routed build acceptance gate", "", "PASS" if not failures else "FAIL"]
    lines.extend(f"- {failure}" for failure in failures)
    lines.extend(f"- {note}" for note in timing_notes)
    args.summary.write_text("\n".join(lines) + "\n", encoding="utf-8")
    print("\n".join(lines))
    return 0 if not failures else 1


if __name__ == "__main__":
    raise SystemExit(main())
