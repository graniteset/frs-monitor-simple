# Python vs. Go web-backend parity and benchmark

This isolated black-box harness compares the existing `WebDashboardServer` in
`frs_all_channels.py` with the board-oriented Go server in `web_go/`. It shares
one deterministic JSON fixture and WAV asset between processes; the Python
production code and Go production implementation are not edited by the
harness. It compares API payloads, the embedded dashboard, PCM playback, WAV
offset playback, and squelch validation. `live-stream` is exercised with the
fixture's opt-in 20 ms PCM replay mode.

## Run

From the repository root:

```sh
python3 -m web_port_bench.compare
```

The command builds a temporary Go binary (no Go benchmark server startup/build
time is included in request timing), launches both servers on loopback with an
identical token and fixture, runs correctness checks, and then benchmarks
`/api/updates`, `/api/history`, and `/api/live` with sequential requests. It
prints p50/p95/mean latency, request throughput, child CPU time, RSS, and Go to
Python throughput/p95 ratios. It does not impose performance pass/fail limits.

Useful options:

```sh
python3 -m web_port_bench.compare --python-only --skip-bench
python3 -m web_port_bench.compare --requests 2000 --warmup 100 --concurrency 4
python3 -m web_port_bench.compare --skip-correctness
```

`--python-only` is useful to verify the fixture adapter before the Go server is
available. `--go-cmd` may provide an alternative Go server command; that
command must accept `--fixture`, `--listen`, and `--token` arguments, plus
`-fixture-replay` for the raw-stream parity phase.

## Interpretation and limits

- Results are local loopback desktop measurements, **not** Zynq ARM performance
  predictions. The target board, vendor root filesystem, radio DMA, Wi-Fi/Ethernet,
  browser, and storage I/O are not part of this experiment.
- Python starts the actual module and therefore requires GNU Radio, osmosdr,
  NumPy, and PyQt5 to be importable, even though no RF source or GUI is opened.
- `/proc` CPU and RSS figures are Linux-specific. CPU deltas have scheduler tick
  granularity, so small runs can report zero or quantized usage; use thousands
  of requests or larger payloads for a steadier estimate.
- Benchmark latency is affected by host load and server warmup. It is
  descriptive only and intentionally has no hard CI threshold.
- Correctness checks are deterministic and are the important pass/fail result.
  The in-memory fixture exercises the API/data boundary; it does not establish
  that the Go server can yet consume a real DMA or Python GNU Radio session.
