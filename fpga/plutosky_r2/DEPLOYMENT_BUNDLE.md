# FRS deployment bundle gate (offline only)

`ci/create_frs_deployment_bundle.py` assembles four files for a later manual
review: `system.bit.bin`, `uImage`, `devicetree.dtb`, and the ARMv7 Go server.
It is a packaging tool only: it never copies files to the board or any mounted
card, loads the FPGA, changes radio settings, or reboots the device. It refuses
to overwrite an existing output directory.

The route input must be the **LIVE-RX** (`FRS_TEST_MODE=0`) artifact directory
from a reviewed Vivado route run, containing `system_top.bit`,
`reports/frs_impl_timing.rpt`, `reports/frs_impl_drc.rpt`,
`build-metadata.txt`, and the route-generated `SHA256SUMS`. The script verifies
those hashes, the Zynq-7020 CLG400 timing target, strictly positive setup and
hold slack, zero timing violations/unconstrained timing checks, and no
critical DRC/errors. The Linux builder emits
`frs-linux-build-manifest.json`; DTB-only output is explicitly rejected. The
kernel must be a valid ARM legacy `uImage` and match the Linux manifest hashes,
and the server must be a 32-bit little-endian ARM ELF.

When a timing-clean route and full kernel build exist, an example invocation is
:

```sh
python3 ci/create_frs_deployment_bundle.py \
  --route-dir /path/to/extracted/live-rx-route-artifact \
  --uimage /path/to/frs-linux-image/uImage \
  --dtb /path/to/frs-linux-image/devicetree.dtb \
  --linux-manifest /path/to/frs-linux-image/frs-linux-build-manifest.json \
  --server /path/to/frs-web-armv7 \
  --output work/frs-deployment-bundle-reviewed-candidate
```

Bootgen is used to turn Vivado's `.bit` into a Zynq FPGA Manager `.bin`; the
builder verifies the swapped sync word `66 55 99 aa` and 8-byte length
alignment expected by the backed-up Linux `zynq-fpga` manager. The checked-in
SD backup names the bitstream `system.bit.bin`, but this does **not** prove
that the existing U-Boot boot script loads that file at startup. Linux
FPGA-manager loading and boot-time selection are distinct paths and require
their own reviewed deployment procedure.

## Current status

No deployable bundle can currently pass the gate. The latest FRS routed
candidate has WNS `+0.775 ns`, but WHS `-1.520 ns`, THS `-20.208 ns`, and 40
hold-failing endpoints. Its `.bit` is rejected even though Vivado wrote it.
The Linux DTB-only build and ARMv7 server can be checked independently, but no
matching FRS `uImage` exists because the ARM cross-compiler is unavailable.
The Linux build manifest records `DTB_ONLY` and is intentionally not
deployable. A format-only Bootgen experiment on a different, non-FRS reference
`.bit` confirmed conversion mechanics; it does not validate an FRS image or
authorize loading that reference image.

The accepted bundle path therefore remains unverified until a fresh FRS
implementation has positive setup/hold slack, passes DRC and timing checks,
and a matching patched Linux kernel and DTB are built. Even then the bundle is
not hardware-validated or itself an instruction to deploy; live load/reboot
must be a later explicit, separately reviewed step.

Run the fail-closed gate tests with:

```sh
python3 -m unittest ci.test_frs_deployment_bundle -v
```
