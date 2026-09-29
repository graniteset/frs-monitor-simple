#!/usr/bin/env python3
"""Build a guarded, offline PlutoSky FRS deployment bundle.

This tool never writes to a device. It accepts only a reviewed LIVE-RX Vivado
route artifact whose checksums and timing/DRC reports pass, plus a matched
kernel/DT manifest and ARMv7 server. The output is just a directory/archive
for a later, separately reviewed deployment step.
"""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import re
import shutil
import struct
import subprocess
import sys
import tempfile
import zlib

from check_vivado_route_reports import check_drc, check_timing


SYNC = bytes.fromhex("665599aa")
FRS_DTB_PROPERTY = "graniteset,frs-packed-audio-v1"
PLUTO_MODEL = "Analog Devices PlutoSDR Rev.C (Z7020/AD9363)"


class BundleError(RuntimeError):
    pass


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def read_checksums(route_dir: Path) -> dict[str, str]:
    sums_path = route_dir / "SHA256SUMS"
    if not sums_path.is_file():
        raise BundleError(f"missing route artifact checksum manifest: {sums_path}")
    entries: dict[str, str] = {}
    for line in sums_path.read_text(encoding="utf-8").splitlines():
        match = re.fullmatch(r"([0-9a-fA-F]{64})  (.+)", line)
        if not match:
            raise BundleError(f"malformed checksum line in {sums_path}: {line!r}")
        digest, relpath = match.groups()
        entries[relpath] = digest.lower()
    return entries


def verify_route(route_dir: Path) -> tuple[Path, Path, Path, dict[str, str]]:
    bit = route_dir / "system_top.bit"
    timing = route_dir / "reports/frs_impl_timing.rpt"
    drc = route_dir / "reports/frs_impl_drc.rpt"
    metadata = route_dir / "build-metadata.txt"
    for path in (bit, timing, drc, metadata):
        if not path.is_file() or path.stat().st_size == 0:
            raise BundleError(f"required route artifact missing/empty: {path}")

    sums = read_checksums(route_dir)
    for path in (bit, timing, drc):
        relpath = path.relative_to(route_dir).as_posix()
        expected = sums.get(relpath)
        actual = sha256(path)
        if expected is None:
            raise BundleError(f"route SHA256SUMS does not cover {relpath}")
        if expected != actual:
            raise BundleError(f"route checksum mismatch for {relpath}")

    fields: dict[str, str] = {}
    for line in metadata.read_text(encoding="utf-8").splitlines():
        if "=" in line:
            key, value = line.split("=", 1)
            fields[key.strip()] = value.strip()
    if fields.get("FRS_TEST_MODE") != "0":
        raise BundleError("route artifact is not the LIVE-RX profile (FRS_TEST_MODE=0)")
    source_sha = fields.get("SOURCE_SHA", "")
    if not re.fullmatch(r"[0-9a-fA-F]{40}", source_sha):
        raise BundleError("route build metadata is missing a full source commit SHA")
    if not re.search(r"\| Device\s*:\s*7z020-clg400\s*$", timing.read_text(errors="replace"), re.M):
        raise BundleError("timing report is not for the PlutoSky 7z020-clg400 target")

    failures = check_timing(timing) + check_drc(drc)
    text = timing.read_text(errors="replace")
    section = text.find("Design Timing Summary")
    summary = text[section:] if section >= 0 else ""
    header = re.search(
        r"WNS\(ns\)\s+TNS\(ns\)\s+TNS Failing Endpoints\s+TNS Total Endpoints\s+"
        r"WHS\(ns\)\s+THS\(ns\)\s+THS Failing Endpoints\s+THS Total Endpoints",
        summary,
    )
    values = None
    if header:
        for line in summary[header.end():].splitlines():
            nums = re.findall(r"[-+]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][-+]?\d+)?", line)
            if len(nums) >= 12:
                values = nums
                break
    if values is None:
        failures.append("could not independently parse routed setup/hold slack")
    else:
        wns, whs = float(values[0]), float(values[4])
        if wns <= 0:
            failures.append(f"deployment requires strictly positive WNS; got {wns:.3f} ns")
        if whs <= 0:
            failures.append(f"deployment requires strictly positive WHS; got {whs:.3f} ns")
    if failures:
        raise BundleError("route evidence rejected:\n  - " + "\n  - ".join(failures))
    return bit, timing, drc, fields


def verify_uimage(path: Path) -> dict[str, int]:
    data = path.read_bytes()
    if len(data) < 64:
        raise BundleError("kernel is too short to be a U-Boot legacy uImage")
    magic, hcrc, timestamp, size, load, entry, dcrc = struct.unpack(">7I", data[:28])
    if magic != 0x27051956:
        raise BundleError("kernel does not have the U-Boot legacy uImage magic")
    os_id, arch, image_type, compression = data[28:32]
    header = bytearray(data[:64])
    header[4:8] = b"\0\0\0\0"
    if zlib.crc32(header) & 0xFFFFFFFF != hcrc:
        raise BundleError("uImage header CRC is invalid")
    payload = data[64:]
    if len(payload) != size or zlib.crc32(payload) & 0xFFFFFFFF != dcrc:
        raise BundleError("uImage payload size/CRC is invalid")
    if arch != 2:
        raise BundleError(f"uImage is not ARM (architecture id {arch})")
    return {"payload_size": size, "load_address": load, "entry_point": entry, "arch": arch,
            "os": os_id, "image_type": image_type, "compression": compression}


def verify_arm_elf(path: Path) -> dict[str, str | int]:
    data = path.read_bytes()
    if len(data) < 20 or data[:4] != b"\x7fELF":
        raise BundleError("server binary is not ELF")
    elf_class, endian = data[4], data[5]
    if elf_class != 1 or endian != 1:
        raise BundleError("server must be a 32-bit little-endian ARM executable")
    machine = struct.unpack_from("<H", data, 18)[0]
    if machine != 40:
        raise BundleError(f"server ELF machine is not ARM (e_machine={machine})")
    return {"class": "ELF32", "machine": "ARM", "machine_id": machine}


def verify_dtb(path: Path, fdtget: str) -> None:
    data = path.read_bytes()
    if len(data) < 8 or data[:4] != bytes.fromhex("d00dfeed"):
        raise BundleError("DTB lacks the flattened-device-tree magic")
    model = subprocess.run([fdtget, "-t", "s", str(path), "/", "model"], check=True,
                           text=True, capture_output=True).stdout.strip()
    if model != PLUTO_MODEL:
        raise BundleError(f"DTB model mismatch: expected {PLUTO_MODEL!r}, got {model!r}")
    prop = subprocess.run([fdtget, "-p", str(path), "/fpga-axi@0/cf-ad9361-lpc@79020000"],
                          check=True, text=True, capture_output=True).stdout.splitlines()
    if FRS_DTB_PROPERTY not in prop:
        raise BundleError(f"DTB is missing required FRS property {FRS_DTB_PROPERTY}")


def verify_linux_manifest(path: Path, uimage: Path, dtb: Path) -> dict:
    try:
        doc = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise BundleError(f"cannot read Linux build manifest: {exc}") from exc
    if (doc.get("status") != "PASS" or doc.get("kernel_built") is not True
            or doc.get("kernel_patch_applied") is not True):
        raise BundleError("Linux manifest does not attest a completed kernel build")
    for key, artifact in (("uimage_sha256", uimage), ("dtb_sha256", dtb)):
        if doc.get(key) != sha256(artifact):
            raise BundleError(f"Linux manifest {key} does not match {artifact}")
    for key in ("kernel_config_sha256", "kernel_patch_sha256", "source_commit"):
        if not isinstance(doc.get(key), str) or not doc[key]:
            raise BundleError(f"Linux manifest is missing {key}")
    for key in ("kernel_config_sha256", "kernel_patch_sha256"):
        if not re.fullmatch(r"[0-9a-f]{64}", doc[key]):
            raise BundleError(f"Linux manifest has an invalid {key}")
    if not re.fullmatch(r"[0-9a-fA-F]{40}", doc["source_commit"]):
        raise BundleError("Linux manifest source_commit is not a full commit SHA")
    required_config = {
        "CONFIG_FPGA": "y", "CONFIG_FPGA_MGR_ZYNQ_FPGA": "y",
        "CONFIG_IIO": "y", "CONFIG_IIO_BUFFER": "y", "CONFIG_IIO_BUFFER_DMA": "y",
    }
    if doc.get("required_kernel_config") != required_config:
        raise BundleError("Linux manifest lacks required FPGA-manager/IIO config attestation")
    return doc


def convert_bit(bootgen: str, bit: Path, tempdir: Path) -> Path:
    tempdir = tempdir.resolve()
    bit = bit.resolve()
    staged_bit = tempdir / "system_top.bit"
    shutil.copyfile(bit, staged_bit)
    bif = tempdir / "system_top.bif"
    bif.write_text("all: { system_top.bit }\n", encoding="ascii")
    subprocess.run([bootgen, "-arch", "zynq", "-image", str(bif), "-process_bitstream", "bin"],
                   cwd=tempdir, check=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    output = tempdir / "system_top.bit.bin"
    if not output.is_file() or output.stat().st_size == 0:
        raise BundleError("Bootgen did not produce system_top.bit.bin")
    raw = output.read_bytes()
    sync_offsets = [i for i in range(0, len(raw) - 3, 4) if raw[i:i + 4] == SYNC]
    if not sync_offsets:
        raise BundleError("Bootgen .bin lacks Zynq FPGA Manager swapped sync word 66 55 99 aa")
    if len(raw) % 8:
        raise BundleError("Bootgen output length is not 8-byte aligned for the Zynq FPGA manager")
    return output


def build(args: argparse.Namespace) -> dict:
    route_dir = args.route_dir.resolve()
    bit, timing, drc, route_metadata = verify_route(route_dir)
    for path in (args.uimage, args.dtb, args.server, args.linux_manifest):
        if not path.is_file() or path.stat().st_size == 0:
            raise BundleError(f"required Linux/server artifact missing/empty: {path}")
    kernel_info = verify_uimage(args.uimage)
    server_info = verify_arm_elf(args.server)
    verify_dtb(args.dtb, args.fdtget)
    linux_manifest = verify_linux_manifest(args.linux_manifest, args.uimage, args.dtb)
    out = args.output.resolve()
    if out.exists():
        raise BundleError(f"refusing to overwrite existing output: {out}")
    out.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".frs-bundle-stage-", dir=out.parent) as temporary:
        staging = Path(temporary)
        bootgen_dir = staging / "bootgen"
        bootgen_dir.mkdir()
        converted = convert_bit(args.bootgen, bit, bootgen_dir)
        artifacts = {
            "system.bit.bin": converted,
            "uImage": args.uimage,
            "devicetree.dtb": args.dtb,
            "frs-web-armv7": args.server,
        }
        for name, source in artifacts.items():
            shutil.copyfile(source, staging / name)
        payload_bytes = (staging / "system.bit.bin").read_bytes()
        sync_offset = next(i for i in range(0, len(payload_bytes) - 3, 4)
                           if payload_bytes[i:i + 4] == SYNC)
        manifest = {
            "format": "frs-plutosky-r2-deployment-bundle-v1",
            "deployment_ready": False,
            "device_write_performed": False,
            "hardware_validation_performed": False,
            "target": "PlutoSky R2 / Zynq-7020 CLG400 / AD9363 (assumed board profile)",
            "route_source_sha": route_metadata["SOURCE_SHA"],
            "route_artifacts": {name: sha256(route_dir / name) for name in (
                "system_top.bit", "reports/frs_impl_timing.rpt", "reports/frs_impl_drc.rpt")},
            "linux_build_manifest": linux_manifest,
            "artifacts": {name: sha256(staging / name) for name in sorted(artifacts)},
            "kernel_uimage": kernel_info,
            "server_elf": server_info,
            "fpga_manager_format": {
                "source": "Vivado .bit processed by Bootgen -arch zynq -process_bitstream bin",
                "required_swapped_sync_hex": SYNC.hex(),
                "sync_word_aligned_offset": sync_offset,
                "byte_length": len(payload_bytes),
            },
        }
        (staging / "manifest.json").write_text(
            json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8"
        )
        with (staging / "SHA256SUMS").open("w", encoding="ascii") as stream:
            for path in sorted(staging.iterdir()):
                if path.is_file() and path.name != "SHA256SUMS":
                    stream.write(f"{sha256(path)}  {path.name}\n")
        staging.rename(out)
    return manifest


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--route-dir", required=True, type=Path)
    parser.add_argument("--uimage", required=True, type=Path)
    parser.add_argument("--dtb", required=True, type=Path)
    parser.add_argument("--server", required=True, type=Path)
    parser.add_argument("--linux-manifest", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--bootgen", default="bootgen")
    parser.add_argument("--fdtget", default="fdtget")
    args = parser.parse_args()
    try:
        manifest = build(args)
    except (BundleError, OSError, subprocess.CalledProcessError) as exc:
        print(f"FRS bundle refused: {exc}", file=sys.stderr)
        return 1
    print(f"Created offline artifact bundle at {args.output.resolve()}")
    print("Not booted, copied to storage, or tested on hardware.")
    print(f"Validated route source commit: {manifest['route_source_sha']}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
