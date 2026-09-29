#!/usr/bin/env python3
"""Create honest, non-deployable HIL evidence for the checked-out source commit."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def source_hashes(repo: Path) -> dict[str, str]:
    paths: set[Path] = set()
    for dirname in ("fpga", "web_go"):
        root = repo / dirname
        if root.is_dir():
            paths.update(
                path
                for path in root.rglob("*")
                if path.is_file()
                and "__pycache__" not in path.parts
                and path.suffix != ".pyc"
            )
    return {path.relative_to(repo).as_posix(): sha256(path) for path in sorted(paths)}


def go_version() -> str:
    try:
        result = subprocess.run(
            ["go", "version"], check=True, capture_output=True, text=True
        )
    except (OSError, subprocess.CalledProcessError):
        return "unavailable"
    return result.stdout.strip()


def write_manifest(repo: Path, output: Path, binary: Path | None) -> dict:
    output.mkdir(parents=True, exist_ok=True)
    profile_dir = output / "profiles"
    profile_dir.mkdir(exist_ok=True)

    evidence_dir = output / "dsp-evidence"
    evidence_dir.mkdir(exist_ok=False)
    for dirname in ("fpga", "web_go"):
        source_dir = repo / dirname
        if source_dir.is_dir():
            shutil.copytree(
                source_dir,
                evidence_dir / dirname,
                ignore=shutil.ignore_patterns("__pycache__", "*.pyc"),
            )

    sources = source_hashes(repo)
    binary_info = None
    if binary is not None and binary.is_file():
        binary_info = {
            "path": binary.relative_to(output).as_posix(),
            "sha256": sha256(binary),
            "target": "linux/arm GOARM=7 CGO_ENABLED=0",
            "deployable": False,
            "reason": "Candidate server binary only; exact board Linux ABI and service setup are unverified.",
        }

    timing_policy = {
        "status": "not_evaluated_for_this_commit",
        "deploy_gate": "blocked",
        "required_evidence": (
            "A routed Vivado report tied to this exact commit and TEST_MODE profile, "
            "with setup WNS >= 0 ns, hold WHS >= 0 ns, and zero failing endpoints."
        ),
        "note": (
            "Synthesis/OOC timing is insufficient. No routed report is consumed by "
            "this hosted preflight, so it cannot declare either profile timing-safe."
        ),
    }
    common = {
        "schema_version": 1,
        "repository": os.environ.get("GITHUB_REPOSITORY", "local"),
        "ref": os.environ.get("GITHUB_REF", "local"),
        "commit": os.environ.get("GITHUB_SHA") or _git_commit(repo),
        "run_id": os.environ.get("GITHUB_RUN_ID", "local"),
        "target_part_assumption": "xc7z020clg400-2",
        "board_identity_confirmed_in_this_job": False,
        "test_results": {
            "fpga_regression": os.environ.get("FPGA_TEST_RESULT", "not_run"),
            "go_test": os.environ.get("GO_TEST_RESULT", "not_run"),
            "go_vet": os.environ.get("GO_VET_RESULT", "not_run"),
            "go_armv7_build": os.environ.get("GO_BUILD_RESULT", "not_run"),
            "go_toolchain": go_version(),
        },
        "source_sha256": sources,
        "go_armv7_server": binary_info,
        "dma_abi": {
            "status": "RTL_and_Go_decoder_contract; not observed on board in this job",
            "word_bytes": 8,
            "byte_order": "little-endian",
            "record_count": {"bits": "63:62", "expected": 2},
            "reserved_bits": {"bits": "61:42", "expected": 0},
            "record_0_bits": "20:0",
            "record_1_bits": "41:21",
            "record_layout": "channel_id[4:0] followed by signed Q1.15 mono audio[15:0]",
            "note": (
                "The stock cf-ad9361-lpc IIO metadata still describes IQ channels; "
                "do not interpret its records as FRS audio without a matching driver/ABI."
            ),
        },
        "timing": timing_policy,
        "hardware_access": "none in the hosted preflight job",
        "deployment": {
            "deployable": False,
            "sd_write": False,
            "reboot": False,
            "fpga_manager_programming": False,
            "recovery_path_demonstrated": False,
        },
    }
    profiles = []
    for label, test_mode, description in (
        ("live-ad9363", 0, "Live AD9363 receive input"),
        ("synthetic-iq", 1, "FPGA-generated synthetic IQ input"),
    ):
        profile = {
            "profile": label,
            "description": description,
            "frs_test_mode": test_mode,
            "bitstream": None,
            "boot_files": [],
            "build_status": "not_built",
            "deployable": False,
            "timing": timing_policy,
            "blockers": [
                "This hosted job has no Vivado/vendor project checkout and does not build a bitstream.",
                "No routed timing report for this exact commit/profile was consumed.",
                "Board transport, runtime test-source control, and recovery have not been cleared.",
            ],
        }
        profile_path = profile_dir / f"{label}_TEST_MODE_{test_mode}.json"
        profile_path.write_text(json.dumps(profile, indent=2, sort_keys=True) + "\n")
        profiles.append(profile)

    manifest = {**common, "fpga_profiles": profiles}
    manifest_path = output / "build-manifest.json"
    manifest_path.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")

    sums_path = output / "SHA256SUMS"
    with sums_path.open("w", encoding="utf-8") as stream:
        for relative, digest in sorted(sources.items()):
            stream.write(f"{digest}  dsp-evidence/{relative}\n")
        if binary_info:
            stream.write(f"{binary_info['sha256']}  {binary_info['path']}\n")
        for profile in profiles:
            path = profile_dir / f"{profile['profile']}_TEST_MODE_{profile['frs_test_mode']}.json"
            stream.write(f"{sha256(path)}  {path.relative_to(output).as_posix()}\n")
        stream.write(f"{sha256(manifest_path)}  build-manifest.json\n")
    return manifest


def _git_commit(repo: Path) -> str:
    try:
        result = subprocess.run(
            ["git", "rev-parse", "HEAD"],
            cwd=repo,
            check=True,
            capture_output=True,
            text=True,
        )
    except (OSError, subprocess.CalledProcessError):
        return "unknown"
    return result.stdout.strip()


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", type=Path, default=Path.cwd())
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--arm-binary", type=Path)
    args = parser.parse_args(argv)
    repo = args.repo.resolve()
    output = args.output.resolve()
    binary = args.arm_binary.resolve() if args.arm_binary else None
    manifest = write_manifest(repo, output, binary)
    print(f"Wrote non-deployable HIL manifest for {manifest['commit']}: {output}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
