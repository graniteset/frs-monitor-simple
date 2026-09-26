"""Black-box correctness and latency/throughput comparison for two HTTP servers."""
from __future__ import annotations

import argparse
import base64
import concurrent.futures
import json
import math
import os
import shutil
import statistics
import subprocess
import sys
import tempfile
import time
import socket
import select
import urllib.error
import urllib.request
from pathlib import Path

from .fixture import TOKEN, START, write_fixture

ROOT = Path(__file__).resolve().parents[1]


class ServerProcess:
    def __init__(self, command, fixture, cwd=ROOT, extra_args=()):
        env = os.environ.copy()
        env["PYTHONPATH"] = str(ROOT) + os.pathsep + env.get("PYTHONPATH", "")
        sock = socket.socket()
        sock.bind(("127.0.0.1", 0))
        self.port = sock.getsockname()[1]
        sock.close()
        self.proc = subprocess.Popen(
            command + ["--fixture", fixture, "--listen", f"127.0.0.1:{self.port}",
                       "--token", TOKEN] + list(extra_args), cwd=cwd, env=env,
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, bufsize=1)
        line = ""
        deadline = time.monotonic() + 90
        while time.monotonic() < deadline:
            readable, _, _ = select.select([self.proc.stdout], [], [], 0.5)
            if not readable:
                if self.proc.poll() is not None:
                    break
                continue
            line = self.proc.stdout.readline().strip()
            if "LISTENING http://" in line:
                break
            if self.proc.poll() is not None:
                break
        if "LISTENING http://" not in line:
            stderr = self.proc.stdout.read(2000)
            self.close()
            raise RuntimeError(f"server failed startup: {line!r}\n{stderr}")
        line = line[line.index("LISTENING http://"):]
        self.base = line.removeprefix("LISTENING ").split("?", 1)[0].rstrip("/")

    def url(self, path):
        path = path if path.startswith("/") else "/" + path
        if "?" in path:
            return self.base + path + "&token=" + TOKEN
        return self.base + path + "?token=" + TOKEN

    def request(self, path, method="GET", body=None, timeout=5):
        req = urllib.request.Request(self.url(path), data=body, method=method)
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return resp.status, resp.read(), dict(resp.headers)

    def close(self):
        if self.proc.poll() is None:
            self.proc.terminate()
            try:
                self.proc.wait(timeout=3)
            except subprocess.TimeoutExpired:
                self.proc.kill()
                self.proc.wait(timeout=2)


def decode_json(server, path):
    status, body, _headers = server.request(path)
    if status != 200:
        raise AssertionError(f"{path} status {status}")
    return json.loads(body)


def stream_prefix(server, path, size):
    req = urllib.request.Request(server.url(path))
    response = urllib.request.urlopen(req, timeout=3)
    try:
        return response.status, response.read(size), dict(response.headers)
    finally:
        response.close()


def correctness_bounded(server):
    # Split out stream routes (the ordinary JSON correctness checker must not
    # block while reading their intentionally unbounded responses).
    status, channel_pcm, headers = stream_prefix(
        server, f"/api/channel-stream?channel=3&start={START}", 2_500)
    assert status == 200 and headers.get("X-Audio-Chunk-Bytes") == "2500"
    # Two 20 ms recorded segments with silence where no recording exists.
    # The fixture's source waveform is indexed from each recording's time zero.
    assert len(channel_pcm) == 2_500
    assert channel_pcm[500:1_250] == b"\x00" * 375 * 2
    assert channel_pcm[1_750:2_500] == b"\x00" * 375 * 2

    status, wav_data, headers = server.request("/api/recording?id=1&offset=0")
    assert status == 200 and headers.get("Content-Type", "").startswith("audio/wav")
    import io
    import wave
    with wave.open(io.BytesIO(wav_data), "rb") as wav:
        assert wav.getnchannels() == 1 and wav.getsampwidth() == 2
        assert wav.getframerate() == 12_500 and wav.getnframes() == 1_250

    request = urllib.request.Request(
        server.url("/api/squelch?value=-77.5"), data=b"", method="POST")
    with urllib.request.urlopen(request, timeout=3) as response:
        assert response.status == 204

    for path in ("/api/updates?after=-1", "/api/history?before=nan&limit=1",
                 "/api/live?after=-1", "/api/channel-stream?channel=0&start=1",
                 "/api/recording?id=-1&offset=0"):
        try:
            urllib.request.urlopen(server.url(path), timeout=3)
            raise AssertionError(f"invalid input accepted: {path}")
        except urllib.error.HTTPError as error:
            assert error.code == 400, (path, error.code)


def assert_backend_parity(python, go):
    """Compare equivalent fixture responses, not only each server to itself."""
    routes = ("/api/updates?after=0&since=0",
              "/api/updates?after=6&since=0",
              f"/api/history?before={START + .26}&limit=3",
              "/api/live?after=4")
    for path in routes:
        ps, pb, _ = python.request(path)
        gs, gb, _ = go.request(path)
        assert ps == gs == 200, path
        assert json.loads(pb) == json.loads(gb), f"JSON differs on {path}"
    channel_path = f"/api/channel-stream?channel=3&start={START}"
    _, py_pcm, py_headers = stream_prefix(python, channel_path, 2_500)
    _, go_pcm, go_headers = stream_prefix(go, channel_path, 2_500)
    assert py_headers.get("X-Audio-Chunk-Bytes") == go_headers.get("X-Audio-Chunk-Bytes") == "2500"
    assert py_pcm == go_pcm, "channel playback PCM differs"
    _, py_wav, _ = python.request("/api/recording?id=1&offset=0.01")
    _, go_wav, _ = go.request("/api/recording?id=1&offset=0.01")
    assert py_wav == go_wav, "recording/WAV offset payload differs"
    ps, pb, ph = python.request("/")
    gs, gb, gh = go.request("/")
    assert ps == gs == 200
    assert pb == gb, "embedded dashboard HTML differs from production HTML"
    assert ph.get("Content-Type") == gh.get("Content-Type")


def assert_live_stream_parity(python, go):
    outputs = [stream_prefix(server, "/api/live-stream", 2_500)
               for server in (python, go)]
    expected = [base64.b64decode(row["pcm"]) for row in fixture_data["audio"]]
    for status, pcm, headers in outputs:
        assert status == 200 and len(pcm) == 2_500
        assert headers.get("X-Audio-Chunk-Bytes") == "500"
        parts = [pcm[i:i + 500] for i in range(0, len(pcm), 500)]
        indexes = [expected.index(chunk) for chunk in parts]
        assert all(indexes[i + 1] == (indexes[i] + 1) % len(expected)
                   for i in range(len(indexes) - 1)), indexes


def _proc_stats(pid):
    """Linux /proc stats (CPU seconds, RSS bytes), or None on other OSes."""
    try:
        fields = Path(f"/proc/{pid}/stat").read_text().split()
        # utime/stime are in clock ticks, fields 14/15 (zero-based 13/14).
        cpu = (int(fields[13]) + int(fields[14])) / os.sysconf("SC_CLK_TCK")
        status = Path(f"/proc/{pid}/status").read_text()
        rss_kb = int(next(line.split()[1] for line in status.splitlines()
                          if line.startswith("VmRSS:")))
        return cpu, rss_kb * 1024
    except (OSError, ValueError, StopIteration, IndexError):
        return None


def benchmark(server, requests=300, warmup=20, concurrency=1):
    paths = ["/api/updates?after=0&since=0",
             f"/api/history?before={START + .30}&limit=6",
             "/api/live?after=0"]
    for i in range(warmup):
        server.request(paths[i % len(paths)])
    before = _proc_stats(server.proc.pid)
    start = time.perf_counter()

    def one(i):
        t0 = time.perf_counter()
        server.request(paths[i % len(paths)])
        return time.perf_counter() - t0

    if concurrency == 1:
        latencies = [one(i) for i in range(requests)]
    else:
        with concurrent.futures.ThreadPoolExecutor(max_workers=concurrency) as pool:
            latencies = list(pool.map(one, range(requests)))
    elapsed = time.perf_counter() - start
    after = _proc_stats(server.proc.pid)
    ordered = sorted(latencies)
    def percentile(p):
        return ordered[min(len(ordered) - 1, math.ceil(p * len(ordered)) - 1)]
    cpu_delta = after[0] - before[0] if before and after else None
    return {
        "requests": requests, "concurrency": concurrency,
        "elapsed_seconds": elapsed,
        "requests_per_second": requests / elapsed,
        "latency_ms_p50": percentile(.50) * 1000,
        "latency_ms_p95": percentile(.95) * 1000,
        "latency_ms_mean": statistics.mean(latencies) * 1000,
        "cpu_seconds_delta": cpu_delta,
        "rss_bytes_after": after[1] if after else None,
        "cpu_per_request_seconds": cpu_delta / requests if cpu_delta is not None else None,
    }


def command_main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--go-cmd", nargs="+", help="Go executable/command, default go run .")
    parser.add_argument("--requests", type=int, default=300)
    parser.add_argument("--warmup", type=int, default=20)
    parser.add_argument("--concurrency", type=int, default=1)
    parser.add_argument("--skip-bench", action="store_true")
    parser.add_argument("--skip-correctness", action="store_true")
    parser.add_argument("--python-only", action="store_true",
                        help="validate/measure only the production Python server")
    args = parser.parse_args()
    global fixture_data
    with tempfile.TemporaryDirectory(prefix="web-port-bench-") as temporary:
        fixture_path = write_fixture(temporary)
        with open(fixture_path, encoding="utf-8") as source:
            fixture_data = json.load(source)
        python_cmd = [sys.executable, "-m", "web_port_bench.python_server"]
        python = ServerProcess(python_cmd, fixture_path)
        go = None
        if not args.python_only:
            if args.go_cmd:
                go_cmd = args.go_cmd
            else:
                go_binary = os.path.join(temporary, "frs-web-bench")
                build_env = os.environ.copy()
                build_env.setdefault("GOCACHE", os.path.join(temporary, "go-cache"))
                subprocess.run(["go", "build", "-trimpath", "-o", go_binary, "."],
                               cwd=ROOT / "web_go", env=build_env, check=True)
                go_cmd = [go_binary, "-source", "fixture"]
            go = ServerProcess(go_cmd, fixture_path, cwd=ROOT / "web_go")
        try:
            if not args.skip_correctness:
                servers = [("python", python)]
                if go:
                    servers.append(("go", go))
                for name, server in servers:
                    correctness_json(server)
                    correctness_bounded(server)
                    print(f"{name} parity checks: PASS")
                if go:
                    assert_backend_parity(python, go)
                    print("cross-backend JSON/HTML parity: PASS")
                    py_stream = ServerProcess(python_cmd, fixture_path,
                                              extra_args=["--fixture-replay"])
                    go_stream = ServerProcess(go_cmd, fixture_path,
                                              cwd=ROOT / "web_go",
                                              extra_args=["-fixture-replay"])
                    try:
                        assert_live_stream_parity(py_stream, go_stream)
                        print("live-stream PCM parity: PASS")
                    finally:
                        go_stream.close()
                        py_stream.close()
            if not args.skip_bench:
                servers = [("python", python)]
                if go:
                    servers.append(("go", go))
                results = {name: benchmark(server, args.requests, args.warmup,
                                           args.concurrency)
                           for name, server in servers}
                result = {"benchmark": results}
                if go:
                    result["ratios"] = {
                        "go_over_python_throughput":
                        results["go"]["requests_per_second"] /
                        results["python"]["requests_per_second"],
                        "go_over_python_p95_latency":
                        results["go"]["latency_ms_p95"] /
                        results["python"]["latency_ms_p95"],
                    }
                print(json.dumps(result, indent=2))
        finally:
            if go:
                go.close()
            python.close()


def correctness_json(server):
    """Non-stream route parity and validation checks."""
    unauthorized = urllib.request.Request(server.base + "/api/updates")
    try:
        urllib.request.urlopen(unauthorized, timeout=3)
        raise AssertionError("missing token accepted")
    except urllib.error.HTTPError as error:
        assert error.code == 403
    data = decode_json(server, "/api/updates?after=0&since=0")
    assert set(data) == {"frames", "records", "timeline"}
    assert [row[0] for row in data["frames"]] == list(range(1, 9))
    assert len(base64.b64decode(data["frames"][0][2])) == 4096
    assert [record["id"] for record in data["records"]] == [1, 2, 3]
    assert all("path" not in record for record in data["records"])
    assert abs(data["timeline"]["start"] - START) < 1e-6
    assert abs(data["timeline"]["end"] - (START + .35)) < 1e-6
    assert data["timeline"]["live"] is True
    incremental = decode_json(server, "/api/updates?after=6&since=0")
    assert [row[0] for row in incremental["frames"]] == [7, 8]
    history = decode_json(server,
                          f"/api/history?before={START + .26}&limit=3")
    assert [row[0] for row in history["frames"]] == [4, 5, 6]
    assert history["more_before"] is True
    live = decode_json(server, "/api/live?after=4")
    assert [row[0] for row in live["chunks"]] == [5, 6]
    assert len(base64.b64decode(live["chunks"][0][1])) == 500
    status, wav_data, headers = server.request("/api/recording?id=1&offset=0")
    assert status == 200 and headers.get("Content-Type", "").startswith("audio/wav")
    import io
    import wave
    with wave.open(io.BytesIO(wav_data), "rb") as wav:
        assert (wav.getnchannels(), wav.getsampwidth(), wav.getframerate(),
                wav.getnframes()) == (1, 2, 12_500, 1_250)
    request = urllib.request.Request(server.url("/api/squelch?value=-77.5"),
                                     data=b"", method="POST")
    with urllib.request.urlopen(request, timeout=3) as response:
        assert response.status == 204
    for value in ("nan", "1", "-121"):
        request = urllib.request.Request(server.url(f"/api/squelch?value={value}"),
                                         data=b"", method="POST")
        try:
            urllib.request.urlopen(request, timeout=3)
            raise AssertionError(f"invalid squelch accepted: {value}")
        except urllib.error.HTTPError as error:
            assert error.code == 400, (value, error.code)
    invalid_paths = ("/api/updates?after=-1", "/api/history?before=nan&limit=1",
                     "/api/live?after=-1", "/api/channel-stream?channel=0&start=1",
                     "/api/recording?id=-1&offset=0")
    for path in invalid_paths:
        try:
            urllib.request.urlopen(server.url(path), timeout=3)
            raise AssertionError(f"invalid request accepted: {path}")
        except urllib.error.HTTPError as error:
            assert error.code == 400, (path, error.code)
    try:
        urllib.request.urlopen(server.url("/api/does-not-exist"), timeout=3)
        raise AssertionError("unknown route unexpectedly succeeded")
    except urllib.error.HTTPError as error:
        assert error.code == 404


if __name__ == "__main__":
    command_main()
