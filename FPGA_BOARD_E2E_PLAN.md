# Zynq-7020 FRS bring-up and end-to-end validation plan

## Goal and safety boundaries

Deliver an FRS receiver demonstration on the PlutoSky-R2 / Zynq-7020 that
accepts AD936x IQ, executes the 22-channel FPGA DSP, and serves live and
per-channel audio through the web UI. Validate both the FPGA synthetic-IQ
source and the real RF input path. Keep the existing SD card and bootloader
untouched during this bring-up. Use volatile FPGA loading after Linux boot if
the running image supports it; do not change U-Boot, flash, SD partitions, or
reboot automatically. Never transmit RF during these tests.

The acceptance target is a reproducible, commit-pinned test—not merely a
successful bitstream build. A board image is not loaded until the exact
candidate has no unconstrained required paths, positive setup and hold slack,
and a known recovery path.

## Work stages and gates

### 0. Preserve a known-good baseline

- Keep the original SD-card image and file-level backup unchanged.
- Keep vendor source/project staging under ignored `work/`; tracked overlays
  and patches are the only editable source of truth.
- Record board identity, firmware/kernel versions, USB/IIO state, the Vivado
  part, source commit, profile, and generated artifact hashes.
- Gate: no test has written to SD, updated boot files, or changed the board's
  persistent radio settings.

### 1. Make host CI cover the meaningful software path

- On pushes and pull requests run HDL lint/synthesis checks, all Icarus
  self-checking benches, Go unit tests/vet, and the RTL-bytes-to-Go-HTTP E2E
  test.
- Keep Vivado jobs explicit/manual or on the approved Vivado runner; save the
  exact constraints, utilization, power, DRC, timing reports, and bitstream as
  artifacts.
- Keep hardware tests manually dispatched and fail closed if the board or
  artifact identity is ambiguous. A public PR must never trigger device
  programming or a board reboot.
- Gate: a clean checkout reproduces the full software E2E and the exact HDL
  source commit is tied to its Vivado report artifacts.

### 2. Close timing on the actual CLG400 design

- Use the verified `xc7z020clg400-2` vendor-derived design and the locked
  6.4-MS/s profile. Preserve all required clock relationships and the
  datasheet-derived AD9363 LVDS min/max windows; do not add false paths or
  relax limits to hide violations.
- Investigate both external source-synchronous RX paths and internal vendor
  paths. Use legal IDELAY settings (0–31 taps), verified AD9363 register
  semantics, and Vivado hold-fix/physical optimization where appropriate.
- Run a complete routed implementation (not just OOC synthesis), with setup
  WNS/TNS, hold WHS/THS, unconstrained paths, DRC, utilization, and power
  reviewed. Repeat for synthetic and live-source configurations if they alter
  the implemented netlist.
- Gate: all required setup and hold paths have positive slack with practical
  margin, zero TNS/THS, no unreviewed unconstrained paths, no critical DRCs,
  and a reproducible report for the exact sources. If assumptions remain
  provisional, state the limitation rather than calling it signoff.

### 3. Freeze and validate the sample-format boundary

- AD936x input: two signed 12-bit I/Q values carried in 16-bit FPGA words;
  unpack/sign-extend/scale to Q1.15 exactly once in the RTL adapter. Test
  negative values, extrema, pair ordering, invalid/disabled samples, and
  overflow behavior against a Python/RTL golden vector.
- FPGA output: little-endian 64-bit word; `[63:62]=2`, `[61:42]=0`, and two
  21-bit `{channel[4:0], signed_pcm_q1_15[15:0]}` records in `[20:0]` and
  `[41:21]`. Check endianness, all channel tags, malformed headers, and
  byte-stream framing in Go tests.
- Do not interpret stock `cf-ad9361-lpc` IQ bytes as FRS audio. In FRS mode,
  use an explicitly named/configured FRS endpoint. Prefer a protocol-named
  `frs-audio` IIO scan element or a documented character-device ABI while
  leaving the stock raw-IQ IIO device truthful and intact.
- Gate: the ABI is documented, tested end-to-end, selected explicitly by the
  server, and Linux metadata does not claim the packed audio words are
  physical voltage/IQ measurements.

### 4. Establish a safe temporary loading and control path

- Check the running kernel for FPGA manager/bridge support and identify its
  exact image format and permissions. Check USB networking and serial access
  independently; keep serial as recovery if network drops.
- Build a deploy bundle containing only the validated bitstream, matching
  device-tree/overlay changes if required, the ARMv7 web executable, and a
  manifest with commit/profile/hash/report identities.
- Load the bitstream only after the user-approved/manual safety gate, after
  stopping DMA and quiescing the FPGA bridge. Do not reboot, write persistent
  storage, or change U-Boot as part of the first test.
- Gate: a volatile load can be performed and undone/recovered through a
  documented command path without touching the SD card.

### 5. On-board synthetic-IQ E2E test

- Select the deterministic in-FPGA FM/noise/gap source; verify it cannot reach
  the RF transmitter. The source should exercise the same receiver/DMA path as
  radio IQ, including burst gaps, adjacent-channel stress, backpressure, and
  recovery.
- Capture packed FRS words from the FPGA DMA endpoint on the ARM, run the Go
  server against that endpoint, and open it over the board network.
- Verify channel tags, burst start/end records, per-channel PCM, live mix,
  audio continuation through silence, and HTTP/WebSocket health. Save test
  logs and hashes; do not persist a long recording.
- Gate: a phone/desktop browser can reach the board's server and hear/inspect
  the generated channel audio, with capture and API checks passing.

### 6. On-board real-IQ E2E test

- Restore live AD936x input (no RF transmit); configure the validated RX-only
  profile and record the before/after LO, sample-rate, bandwidth, and gain.
- First verify real IQ enters the RTL adapter with correct signed sample
  interpretation and expected clock/sample counts. Then route it through the
  same 22-channel DSP, DMA protocol, Go server, and browser endpoints.
- With no known signal source, expect mostly noise/squelch—not a meaningful
  conversation. Validate live stream continuity, plausible noise-floor and
  per-channel levels, no adjacent-channel false audio at the selected
  threshold, and no DMA overflow. The current audio-only stream can mark
  channel activity; it is not a real RF-spectrum waterfall.
- Restore the original radio settings after the run and report any settings
  that could not be restored.
- Gate: board-origin IQ is shown to reach the web app through the real FPGA
  chain; errors, overruns, or unexpected active channels are logged and
  triaged.

### 7. Turn the successful manual sequence into hardware CI

- Run hardware CI only by explicit dispatch on the trusted self-hosted runner
  with a human-approved protected environment.
- Preflight checks board identity, link, runner labels, artifact hash, FPGA
  manager availability, and recovery console. Abort on any mismatch.
- Test synthetic mode first. Only after it passes, run real-IQ RX-only mode.
  Always restore radio settings and leave the board in a known bootable state.
- Upload timing/build/test logs and image manifests. Keep reboot, SD write,
  U-Boot replacement, and automatic programming disabled unless separately
  approved.
- Gate: a documented manual workflow can reproduce both tests and fail safely
  when prerequisites are absent.

## Current checkpoint

- Board identity and USB IIO are readable. A bounded stock real-IQ capture
  currently returns 256 eight-byte scan frames (2,048 bytes), but this is raw
  IQ only—not the FRS packed output.
- Read-only USB inventory exposes RX `voltage0/rf_bandwidth` and
  `voltage0/sampling_frequency` as channel attributes. The host RX-profile
  helper now uses those observed names plus libiio's input-only selector
  (RX/TX channel IDs overlap), and its read-only preflight returned LO 2.4 GHz,
  sample rate 30.72 MS/s, BW 18 MHz, slow-attack gain, and 71 dB RX gain. Its
  mock tests verify restoration; no radio settings have been changed.
- The running kernel is Linux 5.15 ARMv7 and exposes `/dev/fpga0` plus
  `/sys/class/fpga_manager/fpga0`; `CONFIG_FPGA_BRIDGE` is disabled. The
  volatile loading/recovery procedure therefore still needs verification,
  especially how the full design is quiesced without the FPGA-bridge class.
- Board-independent RTL regression passes through the 22-channel chain,
  synthetic burst/adjacent-channel tests, 6.4-MS/s cadence, and overrun tests.
- The exact RTL-to-Go-HTTP test passes: 2,706 DMA words / 21,648 bytes;
  channel-4 record duration 19.680 ms; updates/live/channel-stream endpoints
  all returned the expected activity/audio.
- Go tests, `go vet`, HIL-manifest tests, and whitespace checks pass.
- Routed timing is not yet acceptable: hold violations remain. No candidate
  bitstream has been loaded on hardware. A valid `frs-audio` Linux-side format
  endpoint is also not yet installed.
- The driver/DT patch for that endpoint has been compiled and its DTS built in
  a disposable kernel tree, but the running board still reports only the
  stock `cf-ad9361-lpc` raw-IQ scan. Go defaults to the FRS endpoint, and the
  explicitly selected raw-IQ fallback must not be used with the FRS decoder.

## Current execution evidence (2026-09-29)

- Full local RTL regression and the RTL-bytes-to-Go-HTTP integration test pass.
- Go race tests, vet, ARMv7 static cross-build, HIL manifest tests, and the
  radio-profile mock tests pass after the IIO attribute correction.
- A new timing experiment is still unresolved: one RX-only top has positive
  setup but negative hold, and an experimental single-ended TX tie-off raised
  differential-output DRC errors. That candidate is discarded; no bitstream
  is authorized for the board.
- The best valid full-TX BUFIO+hold-fix route reported RX `WHS=+0.019 ns` but
  TX-related `WHS=-1.153 ns`, so it still fails and the RX margin is too thin
  for acceptance. A corrected receive-only version retaining differential
  OBUFDS outputs is plausible but not yet routed/DRC-checked. Vivado's batch
  process now fails license discovery; the registered protected runner exists
  but is offline, and the local branch is behind GitHub `main`.
- The current manual Vivado workflow runs OOC synthesis only; it cannot close
  routed hold paths. Full P&R inputs (vendor project archive and generated ADI
  IP catalog) are currently ignored under `work/`, so a clean Actions checkout
  cannot reproduce the local image yet. A future protected route workflow
  needs an immutable, hash-verified cache/staging step and hard gates for WNS,
  WHS, TNS/THS, unconstrained endpoints, and DRC before artifact publication.
- ADI RTL/driver source review confirms the intended live-IQ input format:
  low 12 bits are two's-complement; Linux enables sign extension and leaves
  offset-binary conversion disabled. The adapter's `OFFSET_BINARY_INPUT=0`
  and Q1.15 left shift match that source configuration, pending hardware
  capture after a custom image is loaded.
- The board's root filesystem is still the stock Pluto firmware. The only
  proven live capture is raw AD936x IQ; neither synthetic nor real samples
  have yet traversed the custom FPGA chain into the web app.
- USB serial is available, but the host RNDIS interfaces are enumerated with
  no driver bound, so there is no current board IP path. Binding the existing
  RNDIS interface requires host-side root permission; the earlier allowed
  workspace/sysfs request could not override the kernel's root-only mode.

## Immediate next actions

1. Finish a fully routed positive-hold candidate using legal hardware tap
   values and implementation hold-fix; review its exact constraints and
   reports. Preserve the vendor differential TX pins even if the first
   receive test does not use them; do not count the invalid RX-only/tied-off
   differential-port experiment.
2. Complete the protocol-specific Linux endpoint/metadata work and rebuild or
   validate it against the existing ARMv7 firmware source; keep raw IQ intact.
3. Verify FPGA-manager/recovery controls and package bitstream/server artifacts
   without writing the SD card.
4. Run synthetic mode on-board first; then run the RX-only real-IQ path through
   the same web server and restore radio settings.
5. Enable only the manually dispatched, protected CI hardware job after both
   manual runs are repeatable.
