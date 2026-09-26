# PlutoSky R2 integration notes (initial milestone)

## Selected base project

The product link supplied for the XC7Z020 board resolves to the vendor's
PlutoSky R2 family. The local vendor source snapshot is
`work/vendor_plutosky_r2` at commit `a8a7a970b` (`main`). Its ADI-derived
Vivado project is `src/hdl/projects/pluto/system_project.tcl`; it requests
`xc7z020clg484-2`, consistent with the product's `XC7Z020-2CLG484I` marking
(Vivado omits the industrial-temperature suffix in the part selector). The
script expects Vivado 2022.2; this workstation has Vivado 2026.1. Version
compatibility has not been established. Do not change ADI version checks just
to force a project build without reviewing the resulting IP compatibility.

## Reproducible first hardware-mapping check

From the repository root, run:

```sh
/opt/Xilinx/2026.1/Vivado/bin/vivado -mode batch -nolog -nojournal \
  -source fpga/plutosky_r2/ooc_synth.tcl
```

This synthesizes the existing `frs_receive_core` out-of-context for
`xc7z020clg484-2`, with a provisional 100 MHz core clock and the tested 6.4
MS/s valid-pacing contract. Generated reports/checkpoint go under ignored
`work/frs_plutosky_r2_ooc/`. This measures generic mapping against the target
part, but it is **not** the vendor project build, place-and-route, bitstream,
timing closure, or hardware validation. The OOC clock is an assumption pending
inspection of the generated R2 clock tree.

The script overrides all six coefficient/mapping-file parameters with
absolute workspace paths, so synthesis does not depend on the `.runs/synth_1`
working directory. Vivado documents `$readmemh` lookup as dependent on the
working/launch directory when an HDL filename is relative; see the
[memory initialization guidance](https://docs.amd.com/r/en-US/ug901-vivado-synthesis/Loading-Memory-Contents-With-File-I/O-Tasks).

## Observed vendor receive datapath

`system_bd.tcl` instantiates `axi_ad9361` in `MODE_1R1T=0` and connects
`adc_valid_i0/q0`, `adc_enable_i0/q0`, and `adc_data_i0/q0` to its existing
`rx_fir_decimator`, then `util_cpack2`, then `axi_ad9361_adc_dma`. The radio
datapath uses `axi_ad9361/l_clk`; it also sends `cpack/fifo_wr_overflow` to
`axi_ad9361/adc_dovf`. The existing RX path must remain intact while bringing
up DSP.

The current FRS core accepts signed 12-bit complex samples with `s_valid` /
`s_ready`; it scales the values to Q1.15 internally. Its DSP design/test
contract uses 6.4 MS/s accepted input samples and a 100 MHz processing clock.
The AXI AD9361 user-port cadence is controlled by radio sample-rate and HDL
configuration; the `l_clk` rate alone is not the IQ beat rate. The vendor BD
snippet has a nominal 61.44 MHz FIR rate argument, but this does not establish
the actual R2 sample-enable cadence after Linux configures the transceiver.
Measure/inspect `adc_enable_*` and data formatting in the exact generated
project before connecting the core.

## Safe next integration steps

1. Open/generate the unchanged vendor project in Vivado, record the exact
   `axi_ad9361` parameters, `l_clk` frequency, `adc_enable_i0/q0` cadence,
   ADC data format/sign extension, and existing FIR/cpack parameters.
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

`frs_plutosky_r2_stream.sv` wraps the existing IQ test source, a source mux,
and `frs_receive_core`. It accepts a *buffered/elastic* signed-12-bit radio
stream, normalizes both radio IQ and the Q1.15 test source to one Q1.15 mux
format, then converts back to the core's signed-12-bit input domain. It is not
connected to the AD9361 or the BD and contains no FIFO. Never connect its
`radio_ready` directly to AD9361: it is the backpressure input for a future
FIFO/adapter only. The quick Icarus self-check uses a stub core to isolate the
wrapper contract; it checks mapping, output tagging, mux hold, and downstream
stall behavior, not DSP correctness.

Source `add_frs_sources.tcl` from an open XC7Z020/CLG484 Vivado project to add
the wrapper, RTL, and coefficient memories to `sources_1`. It intentionally
does not change the block design or existing RX/DMA path. When placing the
wrapper as a module reference, set its parameters `DDC_TAPS`, `NCO_TAPS`,
`BAND1_MAP`, `BAND2_MAP`, `PFB_TAPS`, and `AUDIO_TAPS` to absolute paths to the
matching files under this checkout. This is necessary because Vivado runs
synthesis from a generated run directory; merely adding a `.memh` file to the
project does not rewrite the relative strings passed to `$readmemh`.

## Automated Vivado OOC checks

`.github/workflows/vivado-ooc.yml` runs the OOC synthesis on pushes that touch
`fpga/**`, and can also be started with **Actions → Vivado OOC synthesis → Run
workflow**. It uploads the Vivado log, timing summary/path report, utilization,
and checkpoint as a 30-day artifact. A negative worst setup slack fails the CI
job, so timing regressions remain visible instead of being hidden by a
successful `synth_design` command. This is still an OOC estimate, not a placed
and routed board timing result.

The workflow requires a self-hosted GitHub Actions runner on a machine with
Vivado 2026.1, Zynq-7000 device support, and a working license. In the
repository's **Settings → Actions → Runners**, add a Linux x64 runner and give
it the custom label `vivado`; the workflow targets `[self-hosted, Linux, X64,
vivado]`. Keep the runner online for automatic runs. If Vivado is installed in
a different location, update `VIVADO_BIN` in the workflow. Run the agent as
the Linux account that can access the licensed Vivado installation.

For safety, this licensed desktop runner is deliberately **not** used for
`pull_request` events: a public repository can receive untrusted code from
forks, and self-hosted runners expose the host to code executed by a job. The
existing hosted open-source simulation/lint workflow still runs on pull
requests. Pushes by trusted repository writers and manual workflow dispatch
run Vivado.

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
