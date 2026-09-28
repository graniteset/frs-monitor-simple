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
has Vivado 2026.1. Compatibility has not been established. Do not force an
upgrade or regenerate IP before reviewing the unchanged project's status.
Confirm the full FPGA ordering code from its package/device ID before making
a board bitstream.

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
16-bit words. The sample payload is in `[11:0]`; upper bits depend on its
format/sign-extension control, while offset-binary conversion flips the ADC
sign bit. `fpga/frs_ad9361_rx_adapter.sv` extracts those 12 bits, offers an
explicit offset-binary option, requires matching I/Q valid and enable pairs,
and flags a valid sample if a non-backpressurable consumer is not ready. It
adds no buffer or clock-domain crossing. Actual ADI format-register settings
and Linux-selected sample rate still need confirmation from the live target;
`l_clk` frequency alone is not the IQ sample cadence.

## Safe next integration steps

1. Open/generate the unchanged vendor project in Vivado, record the exact
   `axi_ad9361` parameters, `l_clk` frequency, `adc_enable_i0/q0` cadence,
   ADC data-format/sign-extension controls, and FIFO/cpack parameters.
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
The current workstation CLI could not launch Vivado because it did not see a
valid license, so no fresh CLG400 power report is available yet.

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

Use these gates to turn this into actual HIL CI, in order:

1. **Inventory and recovery (read-only):** record exact board/revision and
   boot switches, identify which serial port is console and capture an
   ordinary boot log, inspect the mounted SD read-only, and document a known
   recovery path. Never write, reformat, or repartition that SD card in CI.
2. **Build/package (no device):** after a board-integrated Vivado build exists,
   produce the FPGA image and required boot metadata from the reviewed vendor
   project. Record source commit, tool/version, board part, file sizes, and
   SHA-256 hashes; reject missing or unexpected files. The current OOC result
   is not a bitstream and cannot be booted.
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
environment and runner are configured. A bootable board-integrated image,
synthetic-source control path, and tested recovery plan are still needed for
the FPGA synthetic-data test. Keep `hardware-cycle` hard-disabled until these
are established. Do not run board I/O on push/PR or unreviewed public-fork
code.

Keep the runner interactive and offline between approved runs. Dispatch the
workflow from a reviewed branch; start the runner with `./run.sh` for the
approved run, then stop with Ctrl-C and verify it is offline. The
`hardware-cycle` job has `if: false`, so it cannot run even if a runner is
online; do not remove that guard until the transport and steps have been
reviewed and tested safely.

## Vivado license note

The first batch launch on this workstation stopped before executing Tcl with
“a valid license was not found” (1.35 s elapsed). Vivado 2026.1 requires a
valid license even to launch its full design flows. AMD says the free Vivado
BASIC annual license supports 7-Series devices including Zynq-7000, but still
requires generating and installing a license file. Generate/install BASIC
through AMD Product Licensing / Vivado License Manager, then verify with
`vivado -version` and rerun the OOC command above. The failed launch produced
no design report and does not indicate a synthesis error. See AMD's
[Licensing FAQ](https://www.amd.com/en/products/software/adaptive-socs-and-fpgas/licensing-faq.html)
and [Vivado licensing options](https://www.amd.com/en/products/software/adaptive-socs-and-fpgas/vivado/vivado-licensing-options.html).
