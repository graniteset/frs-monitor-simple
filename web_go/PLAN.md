# Zynq web backend: tooling and rollout plan

## Candidate stack

- Go standard library only (`net/http`, `embed`, `encoding/json`, `encoding/base64`). This avoids a Python/GNU Radio runtime for the web-serving process and avoids CGO for a first ARMv7 build.
- Keep `web/dashboard.html` as the browser UI and preserve its existing URL/query/body behavior. Embed an unchanged copy for a self-contained binary; run an explicit parity check against the source HTML in tests.
- Keep DSP and DMA outside this service. The backend consumes a narrow `Source` interface (timestamped waterfall rows, conversation records, PCM chunks, optional recording WAVs, and squelch control). Start with deterministic synthetic/replay sources; add a hardware adapter only after a stable Linux/DMA ABI exists.
- Initial runtime target is a static Linux ARMv7 binary (`GOOS=linux GOARCH=arm GOARM=7 CGO_ENABLED=0`). A static Go binary is libc-independent in principle, but kernel ABI, available CPU instructions, filesystem paths, and vendor rootfs policies still need on-board validation.

## Staged rollout

1. Preserve the Python server as the behavior reference; mirror its token protection, routes, status codes, JSON shapes, PCM byte order/rates, history windows, and channel playback semantics.
2. Add deterministic fixture injection and unit/API tests. Benchmark the Go and Python servers with the same request traces and fixture data before deciding whether the port is worthwhile.
3. Cross-build for ARMv7 without installing tools/dependencies. Record the output architecture and binary size. Test on the vendor Linux image when board access is available.
4. Add a replay adapter independent of the server; no assumption that the vendor image has Python, GNU Radio, SQLite CGO, or a particular DMA driver.
5. Only after measuring the actual FPGA output ABI, add a bounded-buffer hardware source and specify overrun, timestamp, and channel metadata behavior.

## Non-goals / portability caveats

- No FPGA driver, DMA integration, RF capture, or bitstream work is included here.
- Existing SQLite Python sessions are not opened directly: the stdlib-only Go binary intentionally avoids a CGO SQLite dependency. The source interface permits a later adapter or an explicit export/import tool.
- The Go service does not make the vendor's unknown root filesystem or network configuration automatically compatible. Validate its kernel version, ARM ABI, certificates/networking needs, writable storage paths, and service startup on the actual board.
