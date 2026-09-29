# FRS Linux kernel and device-tree profile

The custom RTL emits one little-endian 64-bit DMA word per scan frame. Its
fields are protocol fields, not converter samples:

| Bits | Meaning |
| --- | --- |
| 63:62 | Record count; currently `2` |
| 61:42 | Reserved; must be zero |
| 41:21 | Second `{channel[4:0], signed Q1.15 audio[15:0]}` record |
| 20:0 | First `{channel[4:0], signed Q1.15 audio[15:0]}` record |

`0001-cf-axi-adc-frs-payload-iio.patch` is an opt-in kernel-source patch for
the staged ADI Linux 5.15 source. The RX-only device-tree overlay
`frs-rx-only.dtso` targets the exact Pluto-derived device tree from the
read-only SD backup at `work/backups/plutosky_sd_2026-09-26/devicetree.dtb`.
It marks
the AXI ADC IIO device as carrying FRS words, sets the AD936x interface tuning
mode to `1` (tune RX, skip TX), raises TX attenuation to the driver maximum,
and disables the TX DDS IIO core and its DMA endpoint. The overlay does not
change the normal RX port, clock, or RX tuning configuration.

The custom kernel reports a `frs-audio` IIO device with one unsigned,
64-real-bit, 64-storage-bit little-endian `generic_data` scan channel. Its
libiio channel ID is `data0` (type `data`, scan index `0`);
`frs_record_pair` is its channel label from `extend_name`, not the channel ID.
Use `iio_readdev ... frs-audio data0` and verify target naming with
`iio_info` before deployment.

The source patch and overlay are not yet installed on the board. They do not
change DMA ownership or the FPGA stream; the patch makes IIO metadata truthful
for the 64-bit FRS words emitted by the matching FRS bitstream. The stock
`cf-ad9361-lpc` scan is ordinary IQ and must never be fed into the FRS decoder.

## RX-only safety

The ADI driver has no device-tree property that powers down the TX synthesizer
at probe. The overlay therefore removes the Linux TX DDS/DMA controls, requests
maximum TX attenuation (89.75 dB), and enables the driver's documented
`adi,tx-lo-powerdown-managed-enable` behavior, but this is not by itself a
hardware TX inhibit. Before any RF test, explicitly power down the TX LO using
the driver's supported IIO `powerdown` channel control after Linux has booted.
For the usual `ad9361-phy` device name, the verified driver ABI is:

```sh
found=0
for d in /sys/bus/iio/devices/iio:device*; do
  [ -r "$d/name" ] && [ "$(cat "$d/name")" = ad9361-phy ] || continue
  found=1
  if ! printf '1\n' > "$d/out_altvoltage1_TX_LO_powerdown" ||
     [ "$(cat "$d/out_altvoltage1_TX_LO_powerdown")" != 1 ]; then
    echo 'TX LO powerdown failed; refusing RX-only startup' >&2
    exit 1
  fi
  break
done
test "$found" = 1 || { echo 'AD9361 PHY not found; refusing RX-only startup' >&2; exit 1; }
```

This writes the ADI-supported TX LO powerdown control; it is volatile and must
be applied on every boot. The backed-up root filesystem's `S98autostart`
sources `/mnt/jffs2/autorun.sh` during startup, so the command can later be
added to that existing hook before starting the FRS server; do not overwrite
any existing autorun content. The snippet intentionally fails if the PHY or
attribute is missing, so the server must be started only after a successful
powerdown. No such hook has been installed on the board. The Buildroot
configuration needed to reproduce its ramdisk is absent, so this deliverable
does not rebuild or replace the ramdisk. Do not transmit; this RX-only profile
is for receive validation, not a certified RF interlock.

## Apply and inspect

The reproducible build driver archives the tracked Linux source into a fresh
ignored `work/` directory, applies the kernel patch only to that copy, extracts
the exact `.config` embedded in the SD-backup `uImage`, builds a merged FRS
DTB, and (if the ARM cross-compiler is available) builds a Linux `uImage`.
It does not rebuild U-Boot, `BOOT.bin`, the ramdisk, or write any storage
device. From the repository root:

```sh
bash fpga/plutosky_r2/linux/build_frs_kernel.sh
```

The vendor Buildroot tree expects an `arm-linux-gnueabihf-` compiler under
`work/vendor_plutosky_r2/src/buildroot/output/host/bin`. If the toolchain is
elsewhere, set `CROSS_COMPILE=/path/to/arm-linux-gnueabihf-`. To validate just
the patch/config extraction and DT overlay when no cross-compiler is installed:

```sh
FRS_DTB_ONLY=1 bash fpga/plutosky_r2/linux/build_frs_kernel.sh
```

By default the SD-backup files are read from
`work/backups/plutosky_sd_2026-09-26/`; override only with
`FRS_BOOT_FILES=/path/to/read-only/backup` if needed. The script also verifies
that the staged Linux source is clean. Outputs stay under
`work/frs-linux-image-<UTC timestamp>/`; review and copy
individual artifacts manually only after validating them. The expected SD
boot filenames remain `uImage`, `devicetree.dtb`, and `uramdisk.image.gz` as
specified by the SD-backup `uEnv.txt`. This process only produces the first two;
it leaves the existing ramdisk and `BOOT.bin` unchanged.

For a standalone patch applicability check from the repository root:

```sh
git -C work/vendor_plutosky_r2/src/linux apply --check --directory=src/linux \
  "$PWD/fpga/plutosky_r2/linux/0001-cf-axi-adc-frs-payload-iio.patch"
```

The build script performs that check, applies the patch only to an archived
copy, and validates the merged DTB. `frs-ad9361-iio.dtsi` is retained as the
equivalent node fragment for a future source-DTS integration; the current
script applies `frs-rx-only.dtso` to the exact SD-backup DTB instead. Never
patch the staged vendor checkout in place or alter the SD image as part of
this step.

## ABI note

The current IIO generic channel encoding is unsigned 64-bit storage. The
packed word contains signed audio subfields; userspace must decode it using
the FRS word protocol. `web_go` already validates the count/reserved bits and
decodes those subfields. The scan element is a byte transport container, not
a scalar sensor measurement.
