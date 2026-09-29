# PlutoSky 7020 CLG400 integration notes

## Selected base project

The board marking provided by the user includes `CLG400ABX`, identifying the
CLG400 package (but not, by itself, the complete speed-grade/device ordering
code). The older vendor 7020 project is now the best hardware basis: its
Vivado XPR and block design target `xc7z020clg400-2`. The inspected archive is
staged outside Git under `work/vendor/plutosky_7020_legacy/`.

Do **not** use the newer PlutoSky R2 project's constraints or bitstream for
this board. That project targets `xc7z020clg484-2`; its AD9363 pin map differs
materially from CLG400. The SD image boots and identifies as
`Analog Devices PlutoSDR Rev.C (Z7020/AD9363)`, but its firmware files do not
hash-match the checked vendor repository snapshot. The image is therefore
not yet proven to come from either source project.

The CLG400 project archive is a Vivado 2021.1 project, while this workstation
has Vivado 2026.1. A scratch-copy migration has now successfully upgraded its
20 project IP instances, validated the primary block design, generated the BD
targets, and synthesized the original board-level `system_top`. This confirms
that the current tool can build the staged copy; it does not prove that a
2026.1-generated image is board-compatible. The archive and SD card remain
untouched. Confirm the full FPGA ordering code from its package/device ID
before making or loading a board bitstream.

Vivado 2026.1 inspection confirmed the project part and top as
`xc7z020clg400-2` / `system_top`. The XPR references the original
`F:/FPGA_Code/MyCore_7010_V3/...` workspace for ADI/GHDL IP repositories.
ADI IP definitions were rebuilt into an isolated catalog from the staged
source tree, then registered only in a disposable project copy. The packaged
DMA initially missed its `sync_event` dependency; including that source in the
local package resolved the OOC synth failure. Keep the catalog and all
upgrades in a disposable build copy; do not repair the archived source
in-place.

The reproducible scratch-project driver is
`fpga/plutosky_r2/synth_vendor_copy.tcl`. It requires `FRS_VENDOR_XPR` to name
only a `work/.../frs_clg400_probe.xpr` copy and `FRS_ADI_IP_REPO` to point at
the staged ADI catalog. It generates targets and synthesizes `system_top`,
writing reports under that copy. The latest run produced 14,084 LUTs, 19,225
registers, 4 BRAM tiles, and 28 DSP48E1 slices. Synthesis timing reports
positive WNS of 0.464 ns (worst constrained clock group: `rx_clk`, 250 MHz).
These pre-placement numbers are an initial baseline only—not routed timing,
power, bitstream validation, or proof that the inherited ZC702-derived pin
constraints match the physical board. Several unused HDMI/IIC/GPIO/SPI
constraints in the generic ZC702 file still report unmatched ports, so the
constraints and package pin map must be reconciled before implementation.

## Reproducible first hardware-mapping check

From the repository root, run:

```sh
/opt/Xilinx/2026.1/Vivado/bin/vivado -mode batch -nolog -nojournal \
  -source fpga/plutosky_r2/ooc_synth.tcl
```

This synthesizes the existing `frs_receive_core` out-of-context for
`xc7z020clg400-2`, with a provisional 100 MHz core clock and the tested 6.4
MS/s valid-pacing contract. Generated reports/checkpoint go under ignored
`work/frs_plutosky_r2_ooc/`. This measures generic mapping against the target
part, but it is **not** the vendor project build, place-and-route, bitstream,
timing closure, or hardware validation. The OOC clock is an assumption pending
inspection of the generated CLG400 clock tree.

The script overrides all six coefficient/mapping-file parameters with
absolute workspace paths, so synthesis does not depend on the `.runs/synth_1`
working directory. Vivado documents `$readmemh` lookup as dependent on the
working/launch directory when an HDL filename is relative; see the
[memory initialization guidance](https://docs.amd.com/r/en-US/ug901-vivado-synthesis/Loading-Memory-Contents-With-File-I/O-Tasks).

## Observed vendor receive datapath

The CLG400 block design instantiates `axi_ad9361` and connects its 16-bit
`adc_data_i0/q0`, `adc_valid_i0/q0`, and `adc_enable_i0/q0` user ports to an
ADI asynchronous FIFO, packer, and `axi_ad9361_adc_dma` into PS DDR. It reports
FIFO overflow back to the radio core. Unlike a project variant previously
assumed, the inspected CLG400 block design has no `rx_fir_decimator` in this
path. Preserve the original RX-to-DMA path during initial DSP integration.

The current FRS core accepts signed 12-bit complex samples with `s_valid` /
`s_ready`; it scales the values to Q1.15 internally. Its DSP design/test
contract uses 6.4 MS/s accepted input samples and a 100 MHz processing clock.
The CLG400 ADI `ad_datafmt` stage accepts 12-bit converter codes and emits
16-bit words. Source tracing of the Pluto project, IP defaults, `ad_datafmt`,
and Linux `ad9361_conv` initialization resolves the configured format:
sign-extension is enabled, offset-binary conversion is disabled, and the
output is `{{4{raw[11]}}, raw[11:0]}`—12-bit two's-complement, sign-extended
to 16 bits. `fpga/frs_ad9361_rx_adapter.sv` extracts the low 12 bits with
`OFFSET_BINARY_INPUT=0`, requires matching I/Q valid and enable pairs, and
flags a valid sample if a non-backpressurable consumer is not ready. It adds
no buffer or clock-domain crossing. This confirms the source-level data
format, not a post-programming hardware capture. The Linux-selected sample
rate still needs hardware readback; `l_clk` frequency alone is not the IQ
sample cadence. The project metadata currently labels the AD9361 `l_clk` net
as 100 MHz, while the top-level XDC constrains external `rx_clk_in_p` to
4.000 ns (250 MHz). Treat that mismatch as unresolved vendor-project
configuration, not proof of the runtime I/Q rate.

## Safe next integration steps

1. Reconcile the inherited board constraints and pin map in a disposable
   vendor-project copy, then record the exact `axi_ad9361` parameters, runtime
   `adc_valid` cadence, and FIFO/cpack parameters. The configured ADC data
   signedness/format is source-verified above; hardware capture remains.
2. Use an isolated wrapper in parallel with the existing RX-to-DMA path. Add
   the deterministic IQ test source as the first stream source; select it
   without interrupting the AD9363 capture/DMA path. Validate source pacing,
   reset, and expected output against the portable RTL tests.
3. Before connecting radio samples, prove the full core accepts the configured
   real sample cadence without `s_ready` stalls or DDC/PFB overrun. The
   AD9363 stream cannot be backpressured. If stalls are possible, design and
   verify a FIFO plus an explicit overflow counter/status path; do not wire
   `s_ready` back to the ADC or silently discard samples.
4. Only after that, integrate an AXI-Lite threshold/control register and
   an audio output path (DMA or bounded FIFO to PS). Neither is present in the
   current `frs_receive_core` boundary.
5. Run full vendor synthesis/implementation, inspect utilization and timing,
   then program hardware for incremental capture tests.

The core's serialized output is 21 bits (`{channel[4:0], signed_audio[15:0}`)
at `m_audio_valid` / `m_audio_ready`. A production stream needs a documented
packing/clocking contract for the ARM-side DMA consumer. This integration
milestone deliberately does not invent that contract or alter the vendor BD.

## Added integration seam

`frs_plutosky_r2_stream.sv` (legacy module name) wraps the existing IQ test source, a source mux,
and `frs_receive_core`. It accepts a *buffered/elastic* signed-12-bit radio
stream, normalizes both radio IQ and the Q1.15 test source to one Q1.15 mux
format, then converts back to the core's signed-12-bit input domain. It is not
connected to the AD9361 or the BD and contains no FIFO. Never connect its
`radio_ready` directly to AD9361: it is the backpressure input for a future
FIFO/adapter only. The quick Icarus self-check uses a stub core to isolate the
wrapper contract; it checks mapping, output tagging, mux hold, and downstream
stall behavior, not DSP correctness.

Source `add_frs_sources.tcl` from the vendor CLG400 project to add
the wrapper, RTL, and coefficient memories to `sources_1`. It intentionally
does not change the block design or existing RX/DMA path. When placing the
wrapper as a module reference, set its parameters `DDC_TAPS`, `NCO_TAPS`,
`BAND1_MAP`, `BAND2_MAP`, `PFB_TAPS`, and `AUDIO_TAPS` to absolute paths to the
matching files under this checkout. This is necessary because Vivado runs
synthesis from a generated run directory; merely adding a `.memh` file to the
project does not rewrite the relative strings passed to `$readmemh`.

## Automated Vivado OOC checks

`.github/workflows/vivado-ooc.yml` is deliberately **manual-only**. Start it
from **Actions → Vivado OOC synthesis → Run workflow**, selecting the reviewed
repository branch/commit from the branch picker. It uploads the Vivado log,
journal, any timing/utilization reports produced, and checkpoint as a 30-day
artifact, even when synthesis fails. A negative worst setup slack fails the
job after reports are summarized; the artifact upload still runs. This is
still an OOC estimate, not a placed-and-routed board timing result. The Tcl
also writes `power_estimate.rpt` with Vivado's vectorless switching
propagation. With no SAIF/activity trace and no placed board design, that
number is an initial comparison aid rather than validated power consumption.
The manual Vivado run on `main` (run `36434583480`, commit
`c8113509c0b699c9be663c66cd2436fd5f863315`) completed successfully with
Vivado 2026.1 and the CLG400 part. It reported positive OOC setup slack
(`+3.917 ns`), zero failing synchronous endpoints, 3,514 LUTs, 4,740
registers, 22 BRAM tiles, 43 DSP slices, and a vectorless total on-chip power
estimate of `0.212 W`. These are synthesis-only OOC figures: there is no
placement/routing, SAIF activity, vendor block-design integration, or board
measurement, so they do not establish timing closure or expected device
power. The report artifact is available from the GitHub Actions run.

The workflow requires a self-hosted GitHub Actions runner on a machine with
Vivado 2026.1, Zynq-7000 device support, and a working license. In the
repository's **Settings → Actions → Runners**, add a Linux x64 runner and give
it the custom label `vivado`; the workflow targets `[self-hosted, Linux, X64,
vivado]`. Configure a GitHub Actions environment named `vivado-ooc` with
required reviewer approval and deployment branch restrictions for the
reviewed branches you intend to permit. If Vivado is installed in a different
location, update `VIVADO_BIN` in the workflow. Run the agent as the Linux
account that can access the licensed Vivado installation.

Keep the desktop runner offline between intentional builds: do not install or
enable the runner as a persistent service. Dispatch the workflow from the
Actions page on a reviewed branch, approve the `vivado-ooc` environment if
prompted, then start the runner interactively from its setup directory with
`./run.sh`. The job will remain queued until the runner is online. After the
job completes (or is cancelled), stop it with Ctrl-C. Check that the runner is
offline in **Settings → Actions → Runners** before leaving the machine. Never
select an unreviewed branch; this job executes repository Tcl on the host.

For safety, this licensed desktop runner is deliberately **not** used for
`push` or `pull_request` events. A public repository can receive untrusted
code from forks, and self-hosted runners expose the host to code executed by a
job. The hosted open-source simulation/lint workflow remains automatic; Vivado
runs only after an intentional manual dispatch from reviewed repository code.

## SDR hardware-in-loop workflow

`.github/workflows/sdr-hil.yml` is a separate, manual-only HIL workflow. Its
preflight job runs the FPGA regression on a GitHub-hosted runner and uploads the
log, a SHA-256 manifest, and a portable DSP evidence archive (RTL,
coefficients, and fixed vectors). These are **not bootable** artifacts: the
workflow does not create a board bitstream or modify the SD card. An optional
`probe_board` dispatch input enables a read-only SSH inventory on the booted
board after preflight passes. It checks the direct USB route, SSH host key,
device-tree model, kernel, and IIO inventory, then captures 4096 complex RX
samples from the existing `cf-ad9361-lpc` path and checks the expected 16384
bytes. The raw capture stays in a temporary local file and is deleted after
the check; only its byte count and hash appear in the uploaded report. The
deploy/reboot job remains hard-disabled in YAML.

The hosted preflight also cross-builds and uploads a Linux ARMv7 Go server
candidate, runs its unit tests and `go vet`, and writes separate
`TEST_MODE=0` (live) and `TEST_MODE=1` (synthetic-IQ) manifests. These manifests
are explicitly non-deployable: the hosted job does not have the staged vendor
Vivado checkout, does not build either bitstream, and does not consume a routed
timing report tied to the exact commit/profile. A candidate Go executable is
not evidence that the target Linux ABI, service setup, or DMA ABI has been
validated. `SHA256SUMS` covers copied RTL/Go source, the server candidate,
profile manifests, and the top-level manifest.

For the inventory job, use the existing on-demand runner with the `vivado`
label. Its user needs a dedicated SSH private key at
`$HOME/.ssh/frs_sdr_ci` and a pinned board host key at
`$HOME/.ssh/frs_sdr_known_hosts`. The matching public key must be authorized
for `root` on the board. The host USB interface must be configured as
`192.168.2.10/24`, with a direct route to board `192.168.2.1`. The script
requires the route through `enp0s20f0u5` and uses passwordless SSH only. It
does not invoke a shell command that writes to the device. Configure the
`sdr-hardware` environment with required approval and reviewed branch
restrictions before dispatching with `probe_board=true`.

Treat this inventory probe as exclusive access to the receiver: it opens the
existing RX DMA/IIO buffer briefly. Before dispatch, stop the desktop monitor
and any other process using the PlutoSky IIO device, and ensure nobody else is
actively receiving from it. Do not start a Vivado/FPGA-manager operation or
other board workflow at the same time. The job makes no board changes, but a
concurrent IIO consumer could steal samples or make the bounded capture fail.
The runner must be manually started only for the approved run and stopped
afterward; it stays offline between runs.

### Temporary live-FRS RX profile

`ci/with_ad936x_frs_rx_profile.sh` is a host-side guard-railed wrapper for a
later live-radio/web test. Its default is read-only: it reads the current RX
LO, sample rate, RF bandwidth, gain-control mode, and RX hardware gain, then
prints the proposed FRS profile. Only the explicit `--apply` mode writes radio
attributes. It sets RX LO to 465.125 MHz, the RTL-validated 6.4 MS/s input
rate, and 5.6 MHz RF bandwidth (covering the full 462.55–467.725 MHz FRS
range); it leaves gain mode/gain untouched. It starts the command after `--`
with `FRS_IIO_URI` exported and restores/reads back the original LO, rate, and
bandwidth when that command exits or receives Ctrl-C/TERM. A restoration
failure is reported as a failing exit status.

The wrapper uses libiio's `iio_attr` command interface: `-c DEVICE CHANNEL
ATTR [VALUE]` for channel attrs such as `altvoltage0/frequency`,
`voltage0/sampling_frequency`, and `voltage0/rf_bandwidth`. The final `VALUE`
writes; omitting it reads. For the `voltage0` attributes it also passes
`-i/--input-channel`, because the AD936x context has both RX and TX channels
named `voltage0`; without that filter the CLI returns duplicate values and a
write could affect both directions. The connected board's live read-only
inventory and helper preflight confirmed these RX attributes. The helper
refuses to proceed if its initial reads fail or any requested write does not
read back exactly.

Example, after a reviewed and safe FRS image is already running (this command
does not load an FPGA image, enable TX, reboot, or touch the SD card):

```sh
ci/with_ad936x_frs_rx_profile.sh --uri usb: --apply -- \
  ./web_go/frs-web-armv7 -listen 0.0.0.0:8765 -source frs-iio \
  -iio-uri usb: -iio-device cf-ad9361-lpc \
  -iio-elements voltage0,voltage1,voltage2,voltage3
```

On the stock image, `cf-ad9361-lpc` is ordinary IQ and must not be passed to
the FRS audio decoder. Use this profile only after the custom FRS image is
loaded and its IIO/packed-audio ABI is independently confirmed. The script's
tests use a mock `iio_attr` executable; they verify read-only default behavior,
the exact temporary write/restore order, untouched gain controls, and
restoration on a command failure. Run them with
`python3 -m unittest ci.test_ad936x_frs_rx_profile`.

Use these gates to turn this into actual HIL CI, in order:

1. **Inventory and recovery (read-only):** record exact board/revision and
   boot switches, identify which serial port is console and capture an
   ordinary boot log, inspect the mounted SD read-only, and document a known
   recovery path. Never write, reformat, or repartition that SD card in CI.
2. **Build/package (no device):** an experimental board-integrated FRS
   candidate now synthesizes and generates a bitstream, but it is not timing
   closed or board validated. Produce any next FPGA image and required boot
   metadata from the reviewed vendor project. Record source commit,
   tool/version, board part, file sizes, and SHA-256 hashes; reject missing or
   unexpected files.
3. **Verify package and identity:** compare hashes on runner and target,
   verify target identity and firmware/version over a read-only channel, and
   confirm endpoint/transport plus tested rollback before any update.
4. **Explicitly approved deploy/reboot/fetch:** only a separate manual job,
   with protected `sdr-hardware` environment approval and an explicit run
   input, may transfer a package or request reboot. Keep it off push/PR and
   fork paths. FTP/TFTP/network boot is not assumed; first prove the chosen
   target-side fetch mechanism and recovery behavior independently.
5. **Linux and AD9363 intake:** the read-only board probe now confirms the
   running Linux identity and IIO PHY, and captures a bounded 4096-sample RX
   buffer. Extend this with signedness/packing checks and quantified loss or
   overrun after a board-specific bitstream is available. Preserve the vendor
   RX-to-DMA path; do not backpressure the radio.
6. **Synthetic-IQ DSP check:** select the FPGA test source only through a
   documented control path, capture tagged output, and compare it with the
   fixed expected vectors/tolerances used by `make fpga-test`. Confirm test
   source selection is restored to live RX. This hardware test is not yet in
   the workflow.

The board probe can be requested manually after the GitHub `sdr-hardware`
environment and runner are configured. The FRS test-source selector is
currently a build-time parameter, not a runtime control, and tested recovery
is still needed for FPGA synthetic-data HIL. Keep `hardware-cycle`
hard-disabled until those are established. Do not run board I/O on push/PR or
unreviewed public-fork code.

## Experimental FRS-to-DMA candidate

`build_frs_dma_image.tcl` creates a separate disposable CLG400 project
variant connecting AD9361 12-bit RX samples through an async FIFO and the
22-channel FRS core, then replacing the existing ADC packer as producer for
the existing receive DMA. It does not change the vendor project or SD image.
DMA words hold two tagged `{channel[4:0], audio_q1_15[15:0]}` records, with the
record count in bits `[63:62]`. Existing Linux clients that assume raw IQ need
a matching decoder before the web app can consume these records.

Build from the repository root with `FRS_VENDOR_XPR` pointing to a disposable
`work/.../frs_clg400_probe.xpr`, `FRS_ADI_IP_REPO` pointing to the staged ADI
IP catalog, and `FRS_TEST_MODE=0` for live RX or `1` for synthetic IQ. The
synthetic profile is deterministic 6.4 MS/s complex FM centered on FRS channel
4 (462.6375 MHz, i.e. -2.4875 MHz from the assumed 465.125 MHz LO), with a
1 kHz message, +/-1 kHz peak deviation, and 50 ms on / 500 ms off bursts. It is a
build-time choice, not a runtime switch; a separate volatile FPGA load is
needed to change between live and test images. The bridge test verifies the
channel-4 DMA tag, nonzero settled audio, quiet gap, burst recovery, and DMA
retry/overflow behavior. The 1024-entry Q1.15 sine ROM is generated with
`python3 fpga/generate_test_sine_lut.py`.

```sh
FRS_VENDOR_XPR="$PWD/work/.../frs_clg400_probe.xpr" \
FRS_ADI_IP_REPO="$PWD/work/.../library" FRS_TEST_MODE=0 \
/opt/Xilinx/2026.1/Vivado/bin/vivado -mode batch -nolog -nojournal \
  -source fpga/plutosky_r2/build_frs_dma_image.tcl
```

The older synthetic bridge smoke test used an unmodulated 50 kHz tone and only
checked that the output framing and channel tags were legal. The replacement
FM test is end-to-end at RTL simulation, but still is not a hardware or
analog-front-end validation. The current experimental live-RX candidate is in
`work/frs_clg400_image_1790667714_743788/`. Vivado synthesized, routed, and
generated its bitstream. The new synthetic bridge smoke test passed and
validated 341 packed DMA words with legal channel tags and no overrun flags.
However, this is not yet suitable for normal radio operation: the routed
report still has -3.406 ns hold slack on the provisional AD9363 RX I/O timing
model. The 100 MHz FRS clock group has +0.630 ns setup and +0.052 ns hold
slack. RX timing assumptions need board-specific validation, and live AD9363
sample formatting/rate still need confirmation. Do not treat this as
timing-closed or board-validated. `reimplement_frs_candidate.tcl` reruns
place/route/bitgen after constraint edits without repeating synthesis.

Keep the runner interactive and offline between approved runs. Dispatch the
workflow from a reviewed branch; start the runner with `./run.sh` for the
approved run, then stop with Ctrl-C and verify it is offline. The
`hardware-cycle` job has `if: false`, so it cannot run even if a runner is
online; do not remove that guard until the transport and steps have been
reviewed and tested safely.

## Vivado license note

Vivado 2026.1 BASIC is installed and was detected as active by the successful
manual run. Future licensed builds should continue to use the protected,
on-demand self-hosted runner; the open-source CI remains safe for routine
pushes and pull requests.
