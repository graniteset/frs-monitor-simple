# Go web-service prototype

This is an isolated, standard-library-only alternative to the Python dashboard server. It deliberately leaves `frs_all_channels.py`, the browser UI, and the FPGA code untouched. The server embeds an exact copy of `web/dashboard.html`; a test fails if that copy is stale. Its source boundary accepts already-produced display frames, audio, activity records, and squelch state. The only sources implemented here are synthetic and deterministic JSON fixtures. It does **not** access AD9363, DMA, GNU Radio, or Python session SQLite databases.

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
