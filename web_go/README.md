# Go web-service prototype

This is an isolated, standard-library-only alternative to the Python dashboard server. It deliberately leaves `frs_all_channels.py`, the browser UI, and the FPGA code untouched. The server embeds an exact copy of `web/dashboard.html`; a test fails if that copy is stale. Its source boundary accepts display frames, audio, activity records, and squelch state. Implemented sources include synthetic/JSON fixture inputs, captured FRS DMA words, and a no-CGO `iio_readdev` subprocess adapter. Python session SQLite compatibility is not implemented.

## Toolchain and deployment plan

The implementation is plain Go using `net/http`, JSON, and the Go standard library; there are no third-party modules and no CGO. This is a candidate methodology for the Zynq ARM Cortex-A9 (ARMv7), not a claim that it is already validated against the vendor root filesystem. A static build avoids a libc dependency, but still requires a compatible Linux kernel/ARM ABI and enough writable storage. Validate it on the exact board image before choosing it over Python.

From this directory:

```sh
go test ./...
go vet ./...
go build -trimpath -ldflags='-s -w' -o frs-web .
GOOS=linux GOARCH=arm GOARM=7 CGO_ENABLED=0 \
  go build -trimpath -ldflags='-s -w' -o frs-web-armv7 .
```

The repository environment used Go 1.27.1. If Go's default cache is not writable, set `GOCACHE` to a writable local path. No tools or dependencies are installed by this project. Actual target requirements still to verify: vendor Linux kernel/ARM ABI, board image's busybox/init conventions, Ethernet setup/firewall, launch supervision, recording storage path, and available RAM/CPU under concurrent waterfall polling.

## Run locally

```sh
go run . -listen 127.0.0.1:8765 -source synthetic
```

The process prints a token-protected URL. The synthetic input generates a repeatable waterfall-like noise floor with tone bins and PCM chunks at real-time rates; it is for UI and server plumbing checks, not a model of the radio or FPGA output.

## FPGA FRS DMA stream adapter

The experimental receiver bitstream emits little-endian 64-bit words. Bits
`[63:62]` are the record count (`2`), `[61:42]` are reserved zero, and the two
21-bit records in `[20:0]` and `[41:21]` each contain an FRS channel ID in
`[20:16]` and signed Q1.15 mono audio in `[15:0]`. The Go adapter rejects bad
counts, reserved bits, and channel IDs instead of silently desynchronizing.
It demultiplexes audio into 20 ms per-channel chunks, produces the dashboard's
mixed live PCM stream, and exposes channel playback through the existing
`/api/channel-stream` route.

For an already-captured DMA byte stream or a FIFO/device node that provides
these raw words, run:

```sh
go run . -listen 127.0.0.1:8765 -source frs-dma -dma-file /path/to/capture.bin
# Or stream bytes to stdin:
cat /path/to/capture.bin | go run . -listen 127.0.0.1:8765 -source frs-dma -dma-file -
```

For continuous IIO capture, the Go server launches `iio_readdev` directly,
without a shell or CGO, and forwards its stdout to the same strict word
decoder. The IIO device and scan elements are configurable. The default
is the intended protocol-specific `frs-audio data0` endpoint (`data0` is
the libiio channel ID; `frs_record_pair` is the human-readable channel label). It
fails until a matching driver/device is installed; it must not silently fall
back to the stock IQ scan. For example:

```sh
./frs-web-armv7 -listen 0.0.0.0:8765 -source frs-iio -iio-uri usb: \
  -iio-device frs-audio -iio-elements data0
```

Only after the custom FRS bitstream is loaded, the experimental existing-device
transport shim can be explicitly selected as follows. Never use this override
against the stock FPGA image: it would reinterpret ordinary IQ bytes as FRS
audio records.

```sh
./frs-web-armv7 -listen 0.0.0.0:8765 -source frs-iio -iio-uri usb: \
  -iio-buffer 256 -iio-readdev /usr/bin/iio_readdev \
  -iio-device cf-ad9361-lpc -iio-elements voltage0,voltage1,voltage2,voltage3
```

Or run it on a host that can reach the board's libiio network endpoint:

```sh
./frs-web-armv7 -listen 0.0.0.0:8765 -source frs-iio -iio-uri ip:192.168.2.1 \
  -iio-buffer 256 -iio-device frs-audio -iio-elements data0
```

The adapter invokes the equivalent of:

```sh
iio_readdev -u URI -b 256 -s 0 frs-audio data0
```

`-s 0` requests continuous reads. `-b` is the IIO scan-frame buffer size, not
bytes. The default 256 is intentionally modest for latency and can be tuned.
SIGINT/SIGTERM causes the Go server to send SIGINT to `iio_readdev`, wait up
to two seconds, and then let the process be killed if it does not exit. A
malformed word or unexpected `iio_readdev` exit is logged and shuts down the
HTTP service instead of leaving a quiet, stale dashboard. Verify that this
image has `iio_readdev` installed (`command -v iio_readdev`); some Buildroot
images package it with the libiio utilities rather than enabling it by
default. The command's options and device/channel syntax follow the
[libiio `iio_readdev` documentation](https://wiki.analog.com/resources/tools-software/linux-software/libiio/iio_readdev).

On the current stock board image, `iio_readdev -u usb: -b 256 -s 0
cf-ad9361-lpc voltage0 voltage1 voltage2 voltage3` was verified to emit 8
bytes per scan, but they are AD936x IQ scan data—not FRS records—and must not
be fed to this decoder. The CLI now defaults to `frs-audio/data0` (channel ID;
label `frs_record_pair`);
the stock `cf-ad9361-lpc` elements are explicit opt-in only for use after the
custom payload bitstream is active. The converter driver declares four signed 12-real-bit,
16-storage-bit scan elements (`shift=0`); this is distinct from the custom
FPGA output's 64-bit FRS word. The custom FPGA bridge consumes the ADI RX user
port's 16-bit I/Q words, takes the low 12 ADC bits, interprets them as signed
two's-complement by default, and widens them internally to Q1.15. Only after
that DSP chain does it emit tagged Q1.15 audio records. Do not conflate the
AD936x 12-bit IQ input with those 16-bit audio samples or with the packed DMA
word. The word decoder's strict header checks are a sanity check, not proof
that Linux scan metadata describes the custom payload.

### IIO metadata caveat and proper follow-up

The current command can select the existing four `cf-ad9361-lpc` scan
elements only to obtain an eight-byte-aligned stream from the board's existing
RX DMA/IIO path. Their Linux metadata still describes four signed 12-bit
voltage/IQ scan elements in 16-bit slots, and its sample-rate metadata refers
to the converter—not the serialized audio records. Once the FRS bitstream
replaces the DMA payload, those labels, scan types, and rate are not truthful,
even though userspace treats the resulting eight bytes as one FRS word. The
Go decoder is the runtime protocol decoder; it does not update Linux's IIO
metadata. The custom device/element CLI options prepare the Go adapter for a
real protocol-specific IIO endpoint, but such a kernel driver/DT binding has
not yet been built or installed.

Inspection of the vendored Pluto Linux source found the source of the static
metadata: `ad9361_conv.c` defines four `IIO_VOLTAGE` channels (`AIM_CHAN`,
12 real bits in 16 storage bits), and `cf_axi_adc_core.c` copies those into
the `cf-ad9361-lpc` device during setup. Although the generic core has a
path for user-logic channels, it currently forces `max_usr_channel` to zero
with a `FIXME`, so a Device Tree property alone cannot make an extra record
channel appear.

Do not relabel the AD9361's physical channels or change the stock device tree
for this temporary stream. The clean long-term fix is a distinct capture ABI:
prefer a board-specific `frs-audio` IIO device/driver (or a documented binary
character-device interface) bound to this DMA stream, while leaving
`cf-ad9361-lpc` for actual IQ. If retaining IIO is a priority, expose one
8-byte scan element for each packed FRS word and give it an explicit
`frs_record_pair` label (the generic-data channel ID remains `data0`); a generic unsigned/count-style scan type is less
misleading than voltage, but remains an opaque protocol payload rather than a
physical measurement. This needs matching kernel/DT source, a target kernel
build, and validation with that exact image. It is not a safe runtime-only
metadata tweak and has not been installed or tested on the board.

The data contains audio records only, not RF FFT bins or received-power
measurements. Accordingly, the DMA mode draws an *audio-activity indicator*
at each channel's frequency in the waterfall and labels it as such; it must
not be mistaken for a spectrum display. Activity is estimated from decoded
audio amplitude because the current RTL DMA ABI has no squelch/activity flag
and its complex-IQ RF squelch threshold is currently hardwired open. The web
squelch slider is an audio-level fallback: it opens at the selected audio RMS
floor in dBFS, closes 3 dB below that floor only after 200 ms continuously
below it, and keeps a 20 ms update cadence. That hysteresis/hold avoids rapid
toggle clicks; it is not equivalent to complex-IQ RF squelch.

DMA audio is retained in a bounded in-memory ring (about 29 seconds at
all 22 channels), not a durable session archive. Persisting a field session
requires choosing and implementing the device-side capture/storage lifecycle.

## Fixture mode / benchmark contract

Fixtures are JSON with base64-encoded byte arrays (`row` is exactly 4096 uint8 bins; `pcm` is little-endian signed 16-bit mono). Record paths point to mono 16-bit PCM WAV files. Fixture source does not autonomously change its state. `-fixture-replay` optionally repeats the fixture's PCM chunks every 20 ms with new sequence numbers so a streaming client can test the same behavior as a running source.

```sh
go run . -listen 127.0.0.1:8766 -token BENCHTOKEN \
  -source fixture -fixture /path/to/fixture.json -fixture-replay
```

Fixture schema:

```json
{
  "center_hz": 465125000,
  "sample_rate": 8000000,
  "audio_rate": 12500,
  "archived": false,
  "session_label": "",
  "squelch": -55,
  "frames": [{"seq": 1, "time": 100.0, "row": "<base64 of 4096 bytes>"}],
  "records": [{"id": 1, "channel": 3, "frequency": 462612500,
                "start": 100.0, "end": 100.4, "path": "/data/clip.wav"}],
  "audio": [{"seq": 1, "pcm": "<base64 of little-endian PCM>"}]
}
```

## HTTP compatibility

The existing browser routes and response shapes are mirrored: `GET /`, `/api/updates`, `/api/history`, `/api/live`, `/api/live-stream`, `/api/channel-stream`, `/api/recording`, and `POST /api/squelch`. All routes require the `token` query parameter, matching the current Python dashboard. JSON waterfall rows and PCM chunks use base64 on the polling routes; stream routes write raw PCM. Audio transport defaults to 12.5 kHz, signed little-endian 16-bit mono. Squelch updates return 204; archive-mode changes return 409.

The current Python server supports live GNU Radio and SQLite-backed session archives. Those adapters are intentionally not replicated yet: the Zynq hardware ABI and archive interchange format need an explicit decision before either is wired in. This prototype preserves the browser interface while making those inputs replaceable and measurable.
