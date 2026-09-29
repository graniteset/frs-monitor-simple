#!/usr/bin/env bash
set -euo pipefail

# Build only the custom FRS Linux kernel + device tree in an ignored work dir.
# Never writes the SD card, staged vendor tree, U-Boot, or BOOT.bin.

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd -- "$script_dir/../../.." && pwd)
vendor_root=${FRS_VENDOR_ROOT:-"$repo_root/work/vendor_plutosky_r2"}
boot_files=${FRS_BOOT_FILES:-"$repo_root/work/backups/plutosky_sd_2026-09-26"}
cross_compile=${CROSS_COMPILE:-"$vendor_root/src/buildroot/output/host/bin/arm-linux-gnueabihf-"}
dtc_bin=${DTC:-"$(command -v dtc || true)"}
fdtoverlay_bin=${FDTOVERLAY:-"$(command -v fdtoverlay || true)"}
jobs=${JOBS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || printf '2')}

for path in "$vendor_root/.git" "$vendor_root/src/linux/Makefile" \
	"$boot_files/uImage" "$boot_files/devicetree.dtb" "$script_dir/0001-cf-axi-adc-frs-payload-iio.patch" \
	"$script_dir/frs-rx-only.dtso"; do
	if [[ ! -e "$path" ]]; then
		printf 'Required input missing: %s\n' "$path" >&2
		exit 2
	fi
done

if [[ -z "$dtc_bin" || -z "$fdtoverlay_bin" ]]; then
	printf 'Need dtc and fdtoverlay on PATH.\n' >&2
	exit 2
fi
build_kernel=1
if [[ ! -x "${cross_compile}gcc" ]]; then
	if [[ ${FRS_DTB_ONLY:-0} == 1 ]]; then
		build_kernel=0
		printf 'ARM cross compiler unavailable; will validate patch/config/DT only.\n' >&2
	else
	printf 'ARM Linux cross compiler not found: %s\n' "${cross_compile}gcc" >&2
	printf 'Build/provide the vendor arm-linux-gnueabihf toolchain, then set CROSS_COMPILE.\n' >&2
	exit 2
	fi
fi

vendor_clean=$(git -C "$vendor_root" status --porcelain -- src/linux)
if [[ -n "$vendor_clean" ]]; then
	printf 'Refusing non-clean staged Linux source (read-only source expected):\n%s\n' "$vendor_clean" >&2
	exit 2
fi

stamp=$(date -u +%Y%m%dT%H%M%SZ)
build_root="$repo_root/work/frs-linux-image-$stamp"
if [[ -e "$build_root" ]]; then
	printf 'Build path already exists: %s\n' "$build_root" >&2
	exit 2
fi
mkdir -p "$build_root/source"

# Archive only the tracked Linux source, not the huge vendor repository. This
# makes the source copy deterministic and guarantees the staged tree stays
# untouched. Patch paths in the vendor repository are rooted at src/linux.
git -C "$vendor_root" archive --format=tar HEAD src/linux | tar -xf - -C "$build_root/source"
git -C "$build_root/source" init -q
git -C "$build_root/source" add src/linux
git -C "$build_root/source" -c user.name=FRS-build -c user.email=frs-build.invalid commit -qm 'Disposable vendor Linux baseline'
git -C "$build_root/source" apply --check --directory=src/linux \
	"$script_dir/0001-cf-axi-adc-frs-payload-iio.patch"
git -C "$build_root/source" apply --directory=src/linux \
	"$script_dir/0001-cf-axi-adc-frs-payload-iio.patch"

linux_src="$build_root/source/src/linux"
config_file="$build_root/stock-kernel.config"
bash "$linux_src/scripts/extract-ikconfig" "$boot_files/uImage" > "$config_file"
if ! grep -q '^CONFIG_IKCONFIG=y$' "$config_file"; then
	printf 'Could not extract embedded Linux config from stock uImage.\n' >&2
	exit 2
fi

# Keep build products out of the source tree; copy the exact embedded config.
kernel_out="$build_root/kernel-out"
mkdir -p "$kernel_out"
cp "$config_file" "$kernel_out/.config"
if [[ $build_kernel == 1 ]]; then
	make -C "$linux_src" O="$kernel_out" ARCH=arm \
		CROSS_COMPILE="$cross_compile" olddefconfig
fi
cp "$kernel_out/.config" "$build_root/effective-kernel.config"
if ! cmp -s "$build_root/stock-kernel.config" "$build_root/effective-kernel.config"; then
	printf 'Kernel config changed during olddefconfig; refusing to build with drift. Diff follows:\n' >&2
	diff -u "$build_root/stock-kernel.config" "$build_root/effective-kernel.config" >&2 || true
	exit 2
fi
for required_config in CONFIG_FPGA CONFIG_FPGA_MGR_ZYNQ_FPGA CONFIG_IIO CONFIG_IIO_BUFFER CONFIG_IIO_BUFFER_DMA; do
	if ! grep -qx "${required_config}=y" "$build_root/effective-kernel.config"; then
		printf 'Required kernel option is not enabled: %s=y\n' "$required_config" >&2
		exit 2
	fi
done

dt_overlay="$build_root/frs-rx-only.dtbo"
dtb_out="$build_root/devicetree.dtb"
"$dtc_bin" -@ -I dts -O dtb -o "$dt_overlay" "$script_dir/frs-rx-only.dtso"
"$fdtoverlay_bin" -i "$boot_files/devicetree.dtb" -o "$dtb_out" "$dt_overlay"

# Fail early if the overlay was accepted syntactically but missed a node.
fdtget_bin=${FDTGET:-"$(command -v fdtget || true)"}
if [[ -z "$fdtget_bin" ]]; then
	printf 'Need fdtget on PATH to validate the merged DTB.\n' >&2
	exit 2
fi
"$fdtget_bin" -p "$dtb_out" /fpga-axi@0/cf-ad9361-lpc@79020000 | grep -qx 'graniteset,frs-packed-audio-v1'
"$fdtget_bin" -t s "$dtb_out" /fpga-axi@0/cf-ad9361-dds-core-lpc@79024000 status | grep -qx disabled
"$fdtget_bin" -t s "$dtb_out" /fpga-axi@0/dma@7c420000 status | grep -qx disabled
[[ $("$fdtget_bin" -t i "$dtb_out" /amba/spi@e0006000/ad9361-phy@0 adi,digital-interface-tune-skip-mode) == "1" ]]
[[ $("$fdtget_bin" -t i "$dtb_out" /amba/spi@e0006000/ad9361-phy@0 adi,tx-attenuation-mdB) == "89750" ]]

if [[ $build_kernel == 1 ]]; then
	make -C "$linux_src" O="$kernel_out" ARCH=arm \
		CROSS_COMPILE="$cross_compile" -j"$jobs" uImage UIMAGE_LOADADDR=0x8000
	cp "$kernel_out/arch/arm/boot/uImage" "$build_root/uImage"
else
	printf 'Skipping uImage build because FRS_DTB_ONLY=1 and no ARM cross compiler was found.\n'
fi

printf '\nFRS kernel/DT outputs are in %s\n' "$build_root"
if [[ $build_kernel == 1 ]]; then
	printf '  uImage       (replace only the kernel file after review)\n'
fi
printf '  devicetree.dtb (replace only the DTB after review)\n'
printf '  stock-kernel.config and effective-kernel.config\n'
printf 'Board-backup uramdisk.image.gz and BOOT.bin were not changed or rebuilt.\n'
printf 'TX LO still requires runtime powerdown before RF testing; see linux/README.md.\n'

# Machine-readable input for the offline deployment-bundle gate. A DTB-only
# run is explicitly non-deployable and has no kernel hash.
python3 - "$build_root" "$build_kernel" "$script_dir/0001-cf-axi-adc-frs-payload-iio.patch" "$vendor_root" <<'PY'
import hashlib
import json
import pathlib
import subprocess
import sys

build_root = pathlib.Path(sys.argv[1])
kernel_built = sys.argv[2] == "1"
patch = pathlib.Path(sys.argv[3])
vendor_root = pathlib.Path(sys.argv[4])

def digest(path):
    h = hashlib.sha256()
    with path.open("rb") as src:
        for block in iter(lambda: src.read(1024 * 1024), b""):
            h.update(block)
    return h.hexdigest()

doc = {
    "status": "PASS" if kernel_built else "DTB_ONLY",
    "kernel_built": kernel_built,
    "kernel_patch_applied": True,
    "dtb_sha256": digest(build_root / "devicetree.dtb"),
    "kernel_patch_sha256": digest(patch),
    "kernel_config_sha256": digest(build_root / "effective-kernel.config"),
    "required_kernel_config": {
        "CONFIG_FPGA": "y",
        "CONFIG_FPGA_MGR_ZYNQ_FPGA": "y",
        "CONFIG_IIO": "y",
        "CONFIG_IIO_BUFFER": "y",
        "CONFIG_IIO_BUFFER_DMA": "y",
    },
    "source_commit": subprocess.check_output(
        ["git", "-C", str(vendor_root), "rev-parse", "HEAD"], text=True
    ).strip(),
}
if kernel_built:
    doc["uimage_sha256"] = digest(build_root / "uImage")
(build_root / "frs-linux-build-manifest.json").write_text(
    json.dumps(doc, indent=2, sort_keys=True) + "\n", encoding="utf-8"
)
PY
printf '  frs-linux-build-manifest.json (DTB_ONLY is not deployable)\n'
