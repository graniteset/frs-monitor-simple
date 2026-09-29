#!/usr/bin/env python3
"""Fail-closed validation and copy of runner-provisioned Vivado inputs."""

from __future__ import annotations

import argparse
import hashlib
import os
from pathlib import Path
import re
import shutil
import sys
import xml.etree.ElementTree as ET


REQUIRED_IPS = (
    "axi_ad9361",
    "axi_dmac",
    "util_axis_fifo",
    "util_cdc",
    "util_rfifo",
    "util_wfifo",
)

# These ImportPath values are provenance paths saved by Vivado in the XPR.
# The project was exported with self-contained $PSRCDIR copies, so these
# absolute-origin paths need not exist on the runner. The copies are compared
# with the selected CLG400 legacy archive (never the newer CLG484 PlutoSky-R2
# project). system.bd is deliberately validated semantically: Vivado 2026.1
# reserializes/upgrades it and the FRS integration starts from this probe copy.
PINNED_LEGACY_IMPORTS = {
    "projects/fmcomms2/zc702/fmcomms2_zc702.srcs/sources_1/bd/system/system.bd": (
        "sources_1/bd/system/system.bd",
        "projects/fmcomms2/zc702/zc702.srcs/sources_1/bd/system/system.bd",
        "678c4bf93ac8d38fada92389acbc9a5e2c3c9d63c18826c6b73f0306a531edf0",
    ),
    "library/common/ad_iobuf.v": (
        "sources_1/imports/AD936X_PL/library/common/ad_iobuf.v",
        "library/common/ad_iobuf.v",
        "6e55a963759780e1edfaca3aea1b83350f9059625813fd2033f9e45dbc142349",
    ),
    "projects/fmcomms2/zc702/fmcomms2_zc702.gen/sources_1/bd/system/hdl/system_wrapper.v": (
        "sources_1/imports/system_wrapper.v",
        "projects/fmcomms2/zc702/zc702.gen/sources_1/bd/system/hdl/system_wrapper.v",
        "a842128369bf0d1117f1822dad130c870b88084b8fa0a9c5ff888f7dcfc1ba46",
    ),
    "projects/fmcomms2/zc702/system_top.v": (
        "sources_1/imports/AD936X_PL/projects/fmcomms2/zc702/system_top.v",
        "projects/fmcomms2/zc702/zc702.srcs/sources_1/imports/AD936X_PL/projects/fmcomms2/zc702/system_top.v",
        "ea57311d3fce308cb11934a7a64db3eac1c3f3873a4fe248717bdc3653e31102",
    ),
    "projects/fmcomms2/zc702/system_constr.xdc": (
        "constrs_1/imports/projects/fmcomms2/zc702/system_constr.xdc",
        "projects/fmcomms2/zc702/zc702.srcs/constrs_1/imports/projects/fmcomms2/zc702/system_constr.xdc",
        "231a0214c33cbf7228eee1e796a0e3fe8dc4edd4083b5ce19ce34473bd6e6b7d",
    ),
    "projects/common/zc702/zc702_system_constr.xdc": (
        "constrs_1/imports/projects/common/zc702/zc702_system_constr.xdc",
        "projects/common/zc702/zc702_system_constr.xdc",
        "a71e28af39af6c8c560beca0b6c3dbb6b10def05c81775f2398a41284553c7bf",
    ),
}


def tree_digest(root: Path) -> str:
    """Stable digest over relative names and file contents; reject symlinks."""
    digest = hashlib.sha256()
    files = sorted(root.rglob("*"), key=lambda path: path.relative_to(root).as_posix())
    for path in files:
        if path.is_symlink():
            raise ValueError(f"staging input contains a symlink: {path}")
        if path.is_dir():
            continue
        if not path.is_file():
            raise ValueError(f"staging input contains a non-regular file: {path}")
        relative = path.relative_to(root).as_posix().encode()
        digest.update(len(relative).to_bytes(8, "big"))
        digest.update(relative)
        digest.update(path.stat().st_size.to_bytes(8, "big"))
        with path.open("rb") as stream:
            for chunk in iter(lambda: stream.read(1024 * 1024), b""):
                digest.update(chunk)
    return digest.hexdigest()


def require_digest(value: str, name: str) -> str:
    value = value.strip().lower()
    if not re.fullmatch(r"[0-9a-f]{64}", value):
        raise ValueError(f"{name} must be a pinned 64-character SHA-256 from runner environment")
    return value


def _expand_project_path(value: str, xpr: Path) -> Path:
    substitutions = {
        "$PPRDIR": xpr.parent,
        "$PSRCDIR": xpr.parent / f"{xpr.stem}.srcs",
        "$PGENDIR": xpr.parent / f"{xpr.stem}.gen",
    }
    for variable, path in substitutions.items():
        value = value.replace(variable, str(path))
    resolved = Path(value)
    if not resolved.is_absolute():
        resolved = xpr.parent / resolved
    return resolved.resolve()


def _normalized_wrapper_digest(path: Path) -> str:
    text = path.read_text(errors="strict")
    lines = [
        line
        for line in text.splitlines()
        if not line.startswith("//Date        :") and not line.startswith("//Host        :")
    ]
    return hashlib.sha256(("\n".join(lines) + "\n").encode()).hexdigest()


def check_project_references(
    xpr: Path,
    legacy_root: Path,
    source_mapping: dict[str, tuple[str, str, str]] = PINNED_LEGACY_IMPORTS,
) -> list[tuple[str, str]]:
    try:
        root = ET.parse(xpr).getroot()
    except ET.ParseError as exc:
        raise ValueError(f"invalid Vivado XPR XML: {exc}") from exc

    part_options = [
        node.attrib.get("Val", "")
        for node in root.iter("Option")
        if node.attrib.get("Name") == "Part"
    ]
    if "xc7z020clg400-2" not in part_options:
        raise ValueError(f"probe XPR is not pinned to xc7z020clg400-2: {part_options}")

    files_by_import: dict[str, Path] = {}
    for file_node in root.iter("File"):
        import_values = [
            node.attrib.get("Val", "")
            for node in file_node.iter("Attr")
            if node.attrib.get("Name") == "ImportPath"
        ]
        if not import_values:
            continue
        if len(import_values) != 1:
            raise ValueError("an XPR file entry has multiple ImportPath provenance values")
        value = import_values[0]
        imported = _expand_project_path(value, xpr)
        alias_root = (xpr.parent.parent / "vendor" / "MyCore_7010_V3" / "AD936X_PL").resolve()
        try:
            relative = imported.relative_to(alias_root).as_posix()
        except ValueError as exc:
            raise ValueError(f"XPR import is outside the expected CLG400 provenance path: {value}") from exc
        if relative in files_by_import:
            raise ValueError(f"XPR repeats import provenance: {relative}")
        local_value = file_node.attrib.get("Path", "")
        if not local_value:
            raise ValueError(f"XPR import has no local File Path: {value}")
        local = _expand_project_path(local_value, xpr)
        if not local.is_file():
            raise ValueError(f"XPR import provenance is stale and its local PSRCDIR copy is missing: {local}")
        files_by_import[relative] = local

    if len(files_by_import) != len(source_mapping):
        raise ValueError(
            f"expected exactly {len(source_mapping)} pinned CLG400 imports; found {len(files_by_import)}"
        )
    if set(files_by_import) != set(source_mapping):
        unknown = sorted(set(files_by_import) - set(source_mapping))
        missing = sorted(set(source_mapping) - set(files_by_import))
        raise ValueError(f"XPR import set mismatch; unknown={unknown}, missing={missing}")

    manifest: list[tuple[str, str]] = []
    for imported_relative, (local_relative, legacy_relative, expected_sha256) in sorted(source_mapping.items()):
        legacy_source = (legacy_root / legacy_relative).resolve(strict=True)
        if not legacy_source.is_file() or legacy_source.is_symlink():
            raise ValueError(f"legacy source is not a regular file: {legacy_source}")
        if imported_relative.endswith("/system_wrapper.v"):
            # The probe's generated wrapper has Vivado's volatile Date/Host
            # provenance lines removed; pin both archive and normalized body.
            legacy_sha256 = hashlib.sha256(legacy_source.read_bytes()).hexdigest()
            normalized_legacy_sha256 = _normalized_wrapper_digest(legacy_source)
            if legacy_sha256 != "d6d6b5247ad481b076ecf3324b3bb0a11d9bf773785998818923620c9a1d8a97" or normalized_legacy_sha256 != expected_sha256:
                raise ValueError(
                    f"legacy archive wrapper source hash mismatch for {legacy_relative}: "
                    f"raw={legacy_sha256}, normalized={normalized_legacy_sha256}"
                )
        else:
            legacy_sha256 = hashlib.sha256(legacy_source.read_bytes()).hexdigest()
        if not imported_relative.endswith("/system_wrapper.v") and legacy_sha256 != expected_sha256:
            raise ValueError(
                f"legacy archive source hash mismatch for {legacy_relative}: "
                f"expected {expected_sha256}, got {legacy_sha256}"
            )
        local = files_by_import[imported_relative]
        expected_local = (xpr.parent / f"{xpr.stem}.srcs" / local_relative).resolve()
        if local != expected_local:
            raise ValueError(f"unexpected local XPR copy for {imported_relative}: {local}")
        if imported_relative.endswith("/system.bd"):
            check_clg400_bd(local)
        elif imported_relative.endswith("/system_wrapper.v"):
            actual_sha256 = _normalized_wrapper_digest(local)
            if actual_sha256 != expected_sha256:
                raise ValueError(f"wrapper source differs from legacy archive content: {local}")
        else:
            actual_sha256 = hashlib.sha256(local.read_bytes()).hexdigest()
            if actual_sha256 != expected_sha256:
                raise ValueError(f"imported local source differs from pinned legacy archive content: {local}")
        manifest.append((imported_relative, expected_sha256))
    return manifest


def check_clg400_bd(system_bd: Path) -> None:
    import json

    try:
        design = json.loads(system_bd.read_text(encoding="utf-8"))["design"]
    except (KeyError, json.JSONDecodeError) as exc:
        raise ValueError(f"invalid block design JSON: {system_bd}") from exc
    info = design.get("design_info", {})
    if info.get("device") != "xc7z020clg400-2":
        raise ValueError(f"block design is not for xc7z020clg400-2: {info.get('device')}")
    components = design.get("components", {})
    required_components = {
        "axi_ad9361",
        "axi_ad9361_adc_dma",
        "util_ad9361_adc_fifo",
        "util_ad9361_adc_pack",
        "axi_hp1_interconnect",
        "sys_ps7",
    }
    if not required_components.issubset(components):
        raise ValueError(f"CLG400 block design is missing required RX components: {sorted(required_components - set(components))}")
    ad9361 = components["axi_ad9361"]
    delay = ad9361.get("parameters", {}).get("ADC_INIT_DELAY", {}).get("value")
    if str(delay) != "23":
        raise ValueError(f"expected CLG400 ADC_INIT_DELAY=23, found {delay!r}")

    bd_dir = system_bd.parent
    xci_paths: list[Path] = []
    for component_name, component in components.items():
        xci_path = component.get("xci_path")
        if not xci_path:
            continue
        xci = bd_dir / Path(xci_path.replace("\\", "/"))
        if not xci.is_file():
            raise ValueError(f"block-design IP instance {component_name} lacks XCI: {xci}")
        xci_paths.append(xci)
    if not xci_paths:
        raise ValueError("block design contains no generated XCI inputs")
    try:
        import json

        ad9361_xci = json.loads(
            (bd_dir / "ip/system_axi_ad9361_0/system_axi_ad9361_0.xci").read_text()
        )["ip_inst"]
    except (OSError, KeyError, json.JSONDecodeError) as exc:
        raise ValueError("cannot validate axi_ad9361 XCI configuration") from exc
    xci_delay = ad9361_xci.get("parameters", {}).get("component_parameters", {}).get("ADC_INIT_DELAY", [{}])[0].get("value")
    if str(xci_delay) != "23":
        raise ValueError(f"expected axi_ad9361 XCI ADC_INIT_DELAY=23, found {xci_delay!r}")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--workspace", required=True, type=Path)
    parser.add_argument("--vendor-project", required=True)
    parser.add_argument("--vendor-sha256", required=True)
    parser.add_argument("--legacy-root", required=True)
    parser.add_argument("--adi-ip-repo", required=True)
    parser.add_argument("--adi-sha256", required=True)
    parser.add_argument("--github-output", required=True, type=Path)
    args = parser.parse_args()

    vendor_project = Path(args.vendor_project).expanduser().resolve(strict=True)
    legacy_root = Path(args.legacy_root).expanduser().resolve(strict=True)
    adi_root = Path(args.adi_ip_repo).expanduser().resolve(strict=True)
    workspace = args.workspace.resolve(strict=True)
    expected_vendor = require_digest(args.vendor_sha256, "FRS_VENDOR_STAGE_SHA256")
    expected_adi = require_digest(args.adi_sha256, "FRS_ADI_IP_REPO_SHA256")

    for name, path in (
        ("FRS_VENDOR_STAGE_ROOT", vendor_project),
        ("FRS_VENDOR_LEGACY_ROOT", legacy_root),
        ("FRS_ADI_IP_REPO", adi_root),
    ):
        if not path.is_dir():
            raise ValueError(f"{name} is not a directory: {path}")
        if path == workspace or workspace in path.parents:
            raise ValueError(f"{name} must be a stable, read-only runner path outside the checkout: {path}")

    actual_vendor = tree_digest(vendor_project)
    actual_adi = tree_digest(adi_root)
    if actual_vendor != expected_vendor:
        raise ValueError(f"vendor tree digest mismatch: expected {expected_vendor}, got {actual_vendor}")
    if actual_adi != expected_adi:
        raise ValueError(f"ADI IP catalog digest mismatch: expected {expected_adi}, got {actual_adi}")

    projects = sorted(vendor_project.rglob("frs_clg400_probe.xpr"))
    if len(projects) != 1:
        raise ValueError(f"vendor staging tree must contain exactly one frs_clg400_probe.xpr; found {len(projects)}")
    source_xpr = projects[0].resolve(strict=True)
    if source_xpr.parent != vendor_project:
        raise ValueError("FRS_VENDOR_STAGE_ROOT must be the project directory containing the XPR")

    for ip in REQUIRED_IPS:
        matches = list(adi_root.rglob(f"{ip}_hw.tcl"))
        if not matches:
            # Some generated ADI catalogs package an IP solely through component.xml.
            matches = list(adi_root.rglob("component.xml"))
            matches = [path for path in matches if path.parent.name == ip]
        if not matches:
            raise ValueError(f"ADI catalog lacks required IP definition: {ip}")

    stage_root = workspace / "work" / "vivado-route-inputs"
    if stage_root.exists():
        raise ValueError(f"refusing to overwrite existing staging destination: {stage_root}")
    stage_root.parent.mkdir(parents=True, exist_ok=True)
    staged_project = stage_root / "project"
    shutil.copytree(vendor_project, staged_project, symlinks=False)
    shutil.copytree(adi_root, stage_root / "adi-ip-repo", symlinks=False)
    staged_xpr = staged_project / "frs_clg400_probe.xpr"
    staged_adi = stage_root / "adi-ip-repo"
    legacy_import_manifest = check_project_references(staged_xpr, legacy_root)

    with args.github_output.open("a", encoding="utf-8") as output:
        output.write(f"STAGED_VENDOR_XPR={staged_xpr}\n")
        output.write(f"STAGED_ADI_IP_REPO={staged_adi}\n")
        output.write(f"VENDOR_INPUT_SHA256={actual_vendor}\n")
        output.write(f"ADI_INPUT_SHA256={actual_adi}\n")
        output.write("LEGACY_IMPORT_SHA256=" + ",".join(digest for _, digest in legacy_import_manifest) + "\n")
    print(f"Vendor stage SHA-256 verified: {actual_vendor}")
    print(f"ADI IP catalog SHA-256 verified: {actual_adi}")
    print(f"Validated {len(legacy_import_manifest)} CLG400 imports against the staged project copies")
    print(f"Staged project: {staged_xpr}")
    print(f"Staged ADI IP catalog: {staged_adi}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError) as exc:
        print(f"Vivado input preflight failed closed: {exc}", file=sys.stderr)
        raise SystemExit(1)
