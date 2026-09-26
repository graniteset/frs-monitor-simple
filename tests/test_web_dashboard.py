import base64
import json
import os
import queue
import shutil
import sqlite3
import tempfile
import time
from types import SimpleNamespace
import unittest
from unittest.mock import patch
import urllib.error
import urllib.request
import wave

import numpy as np

from frs_all_channels import (ChannelMonitorSink, ConversationRecorder,
                              DEFAULT_SAMPLE_RATE, FRS_CHANNELS_HZ, FRSReceiver,
                              RealtimeWebTestReceiver,
                              SavedSessionReceiver, SessionArchive, SoftLimiter,
                              SpectrumFrameSink, WebAudioSink,
                              WebDashboardServer, TEST_CONVERSATIONS,
                              TEST_NOISE_FLOOR_DB, main)


class FakeReceiver:
    center_hz = 465_125_000
    sample_rate = 8_000_000
    audio_rate = 12_500

    def __init__(self):
        self.spectrum_frames = queue.Queue()
        self.activity_events = queue.Queue()
        self.web_audio = queue.Queue()
        self.squelch = None

    def set_squelch(self, value):
        self.squelch = value


class WebDashboardTests(unittest.TestCase):
    def setUp(self):
        self.receiver = FakeReceiver()
        self.server = WebDashboardServer(self.receiver, "127.0.0.1", 0)
        self.server.start()
        port = self.server.server.server_address[1]
        self.base = f"http://127.0.0.1:{port}"
        self.token = self.server.token

    def tearDown(self):
        self.server.stop()

    def get(self, path):
        with urllib.request.urlopen(f"{self.base}{path}") as response:
            return response.status, response.read(), response.headers

    def wait_updates(self, predicate, timeout=2):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            _, body, _ = self.get(f"/api/updates?after=0&token={self.token}")
            data = json.loads(body)
            if predicate(data):
                return data
            time.sleep(0.02)
        self.fail("dashboard collector did not publish expected state")

    def test_page_is_mobile_and_token_protected(self):
        with self.assertRaises(urllib.error.HTTPError) as denied:
            self.get("/")
        self.assertEqual(denied.exception.code, 403)
        denied.exception.close()
        status, body, _ = self.get(f"/?token={self.token}")
        text = body.decode()
        self.assertEqual(status, 200)
        self.assertIn("width=device-width", text)
        self.assertIn("touch-action:none", text)
        self.assertIn("canvas.dataset.offset", text)
        self.assertIn("tickIntervals=canvas.clientWidth<600?4:8", text)
        self.assertNotIn("Composite squelched audio", text)

    def test_fft_activity_and_live_audio_updates(self):
        row = np.linspace(-110, 0, 4096, dtype=np.float32)
        self.receiver.spectrum_frames.put((10.0, row))
        self.receiver.activity_events.put(("start", 8, 10.1, None))
        self.receiver.web_audio.put(b"\x00\x00\x01\x00")
        data = self.wait_updates(lambda value: value["frames"] and value["records"])
        decoded = base64.b64decode(data["frames"][0][2])
        self.assertEqual(len(decoded), 4096)
        self.assertEqual(data["records"][0]["channel"], 8)
        _, body, _ = self.get(f"/api/live?after=0&token={self.token}")
        live = json.loads(body)
        self.assertEqual(base64.b64decode(live["chunks"][0][1]),
                         b"\x00\x00\x01\x00")
        self.assertEqual(live["latest"], 1)

    def test_live_audio_is_fixed_size_and_soft_limited(self):
        output = queue.Queue()
        sink = WebAudioSink(output)
        sink.work([np.full(100, 0.5, dtype=np.float32)], [])
        self.assertTrue(output.empty())
        sink.work([np.full(150, 0.5, dtype=np.float32)], [])
        chunk = output.get_nowait()
        self.assertEqual(len(chunk), 250 * 2)
        self.assertEqual(np.frombuffer(chunk, dtype="<i2")[0], 16383)

        limiter = SoftLimiter()
        limited = np.empty(3, dtype=np.float32)
        limiter.work([np.array([-2.0, 0.0, 2.0], dtype=np.float32)], [limited])
        self.assertTrue(np.all(np.abs(limited) < 1.0))

    def test_live_audio_stream_is_continuous_binary_pcm(self):
        response = urllib.request.urlopen(
            f"{self.base}/api/live-stream?token={self.token}", timeout=2)
        try:
            expected = b"\x12\x34" * 250
            for _ in range(5):
                self.receiver.web_audio.put(expected)
            self.assertEqual(response.read(500 * 5), expected * 5)
            self.assertEqual(response.headers["X-Audio-Chunk-Bytes"], "500")
        finally:
            response.close()

    def test_channel_timeline_stream_inserts_silence_between_recordings(self):
        with tempfile.TemporaryDirectory() as directory:
            paths = []
            for name, value in (("first.wav", b"\x11\x11"),
                                ("second.wav", b"\x22\x22")):
                path = os.path.join(directory, name)
                with wave.open(path, "wb") as output:
                    output.setparams((1, 2, 12_500, 0, "NONE", ""))
                    output.writeframes(value * 125)
                paths.append(path)
            with self.server.lock:
                self.server.records.extend([
                    {"id": 1, "channel": 3, "frequency": 462_612_500,
                     "start": 10.0, "end": 10.01, "path": paths[0]},
                    {"id": 2, "channel": 3, "frequency": 462_612_500,
                     "start": 10.05, "end": 10.06, "path": paths[1]},
                ])
            response = urllib.request.urlopen(
                f"{self.base}/api/channel-stream?channel=3&start=10"
                f"&token={self.token}", timeout=2)
            try:
                pcm = response.read(2_500)
            finally:
                response.close()
            self.assertEqual(pcm[:250], b"\x11\x11" * 125)
            self.assertEqual(pcm[250:1_250], b"\x00" * 1_000)
            self.assertEqual(pcm[1_250:1_500], b"\x22\x22" * 125)
            self.assertEqual(pcm[1_500:], b"\x00" * 1_000)

    def test_web_test_fixture_runs_at_wall_clock_rate(self):
        args = SimpleNamespace(center_freq=None, sample_rate=8_000_000,
                               squelch=-55.0, channel_gain=0.25,
                               record_dir="")
        receiver = RealtimeWebTestReceiver(args)
        started = time.monotonic()
        receiver.start()
        time.sleep(0.32)
        receiver.stop()
        receiver.wait()
        elapsed = time.monotonic() - started
        chunks = []
        while not receiver.web_audio.empty():
            chunks.append(receiver.web_audio.get_nowait())
        produced = len(chunks) * 0.02
        self.assertGreaterEqual(produced / elapsed, 0.85)
        self.assertTrue(all(len(chunk) == 500 for chunk in chunks))
        self.assertFalse(receiver.spectrum_frames.empty())
        self.assertFalse(receiver.activity_events.empty())

    def test_synthetic_power_levels_and_squelch_share_the_display_scale(self):
        args = SimpleNamespace(center_freq=None, sample_rate=8_000_000,
                               squelch=-50.0, channel_gain=0.25,
                               record_dir="")
        receiver = RealtimeWebTestReceiver(args)
        row = receiver._spectrum(0.30)
        self.assertAlmostEqual(float(np.median(row)), TEST_NOISE_FLOOR_DB,
                               delta=0.2)
        low = receiver.center_hz - receiver.sample_rate / 2
        expected = {channel: TEST_NOISE_FLOOR_DB + snr
                    for start, end, channel, snr, _tone, _label
                    in TEST_CONVERSATIONS if start <= 0.30 < end}
        for channel, signal_db in expected.items():
            center = round((FRS_CHANNELS_HZ[channel - 1] - low) /
                           receiver.sample_rate * len(row))
            self.assertAlmostEqual(float(row[center]), signal_db, places=4)
        snrs = [conversation[3] for conversation in TEST_CONVERSATIONS]
        self.assertEqual((min(snrs), max(snrs)), (10.0, 60.0))

        receiver.start()
        time.sleep(0.34)
        receiver.stop()
        receiver.wait()
        starts = []
        while not receiver.activity_events.empty():
            event = receiver.activity_events.get_nowait()
            if event[0] == "start":
                starts.append(event[1])
        self.assertEqual(starts, [1])

    def test_fresh_browser_receives_full_visible_waterfall_history(self):
        row = bytes([40]) * 4096
        with self.server.lock:
            for seq in range(1, 651):
                self.server.frames.append((seq, 100 + seq / 20, row))
            self.server.records.extend([
                {"id": 1, "channel": 1, "start": 10.0, "end": 20.0},
                {"id": 2, "channel": 1, "start": 105.0, "end": 110.0},
            ])
        _, body, _ = self.get(f"/api/updates?after=0&token={self.token}")
        initial = json.loads(body)
        self.assertEqual(len(initial["frames"]), 650)
        self.assertEqual([record["id"] for record in initial["records"]], [2])
        self.assertNotIn("path", initial["records"][0])
        _, body, _ = self.get(f"/api/updates?after=600&token={self.token}")
        self.assertEqual(len(json.loads(body)["frames"]), 50)

    def test_completed_record_metadata_is_bounded_to_waterfall_history(self):
        row = bytes([40]) * 4096
        with self.server.lock:
            self.server.frames.append((1, 1_000.0, row))
            self.server.records.extend([
                {"id": 1, "channel": 1, "start": 100.0, "end": 200.0},
                {"id": 2, "channel": 2, "start": 500.0, "end": 600.0},
                {"id": 3, "channel": 3, "start": 100.0, "end": None},
            ])
        self.server._prune_records()
        self.assertEqual([record["id"] for record in self.server.records], [2, 3])

    def test_waterfall_raster_uses_scaled_canvas_coordinates(self):
        with open("web/dashboard.html") as source:
            page = source.read()
        self.assertIn("rasterCtx.putImageData(img,0,0)", page)
        self.assertIn("ctx.drawImage(raster,0,0,w,h,p.x,p.y,p.w,p.h)", page)
        self.assertNotIn("ctx.putImageData(img,Math.round(p.x)", page)
        self.assertIn("latencyHint:'interactive'", page)
        self.assertIn("/api/live-stream", page)
        self.assertIn("requestAnimationFrame(animate)", page)
        self.assertIn("key!==rasterKey", page)
        self.assertNotIn("setTimeout(livePoll,25)", page)
        self.assertIn("LIVE_AV_DELAY=.32", page)
        self.assertIn("audioOn?LIVE_AV_DELAY:0", page)
        self.assertIn("canvas.dataset.avDelay", page)
        self.assertIn("/api/channel-stream", page)
        self.assertIn("AUDIO_RATE=__AUDIO_RATE__", page)
        self.assertIn("createBuffer(1,pcm.length,AUDIO_RATE)", page)
        self.assertNotIn("sampleRate:48000", page)
        self.assertIn("startChannelPlayback(h.r.channel,tappedTime)", page)
        self.assertIn("stopPlayback", page)
        self.assertIn("new ResizeObserver(resize).observe(canvas)", page)
        self.assertNotIn('id="waterfall"', page)
        self.assertNotIn('id="conversations"', page)
        self.assertNotIn("function setMode", page)
        self.assertIn("const palette=new Uint8ClampedArray(256*3)", page)
        self.assertIn("function binsFor(width,count)", page)
        self.assertNotIn("function color(v)", page)
        self.assertIn("&since=${since}", page)
        self.assertIn("function setOffset(value,force=false)", page)
        self.assertIn("function beginPinch()", page)
        self.assertIn("pinch.axis==='frequency'", page)
        self.assertIn("pinch.axis==='time'", page)
        self.assertIn("canvas.dataset.freqSpan", page)
        self.assertIn("canvas.dataset.freqCenter", page)
        self.assertIn("drag.axis==='frequency'", page)
        self.assertIn("clampFreqCenter(freqCenter-dx", page)
        self.assertIn("incoming[0].seq>expected+1", page)
        self.assertIn("pointercancel", page)
        self.assertIn("function stopLiveSources()", page)
        self.assertIn("if(!response.ok||!response.body)", page)
        self.assertIn("/api/history?before=", page)
        self.assertIn("framesVersion", page)
        self.assertIn("ARCHIVED", page)
        self.assertIn("[hidden]{display:none!important}", page)

    def test_session_archive_round_trip_is_portable_and_contains_no_iq(self):
        with tempfile.TemporaryDirectory() as root:
            original = os.path.join(root, "field.frs-session")
            archive = SessionArchive.create(original, 465_125_000, 8_000_000)
            archive.set_display_origin(100.0)
            audio_dir = os.path.join(archive.audio_directory, "channel_03")
            os.makedirs(audio_dir)
            wav_path = os.path.join(audio_dir, "call.wav")
            with wave.open(wav_path, "wb") as output:
                output.setparams((1, 2, 48_000, 0, "NONE", ""))
                output.writeframes(b"\x34\x12" * 4_800)
            expected_row = bytes(range(256)) * 16
            archive.add_frame(1, 100.05, expected_row)
            record = {"id": 7, "channel": 3, "frequency": 462_612_500,
                      "start": 100.10, "end": None, "path": wav_path}
            archive.start_record(record)
            record["end"] = 100.20
            archive.end_record(record)
            outside_path = os.path.join(root, "outside.wav")
            with open(outside_path, "wb") as outside:
                outside.write(b"not session audio")
            archive.start_record(
                {"id": 8, "channel": 4, "frequency": 462_637_500,
                 "start": 100.15, "end": None, "path": outside_path})
            archive.close()

            moved = os.path.join(root, "moved.frs-session")
            shutil.move(original, moved)
            reopened = SessionArchive.open(moved)
            reopened.set_display_origin(500.0)
            frames = reopened.frames_before(501.0, 10)
            records = reopened.records_between(500.0, 501.0)
            self.assertEqual(frames, [(1, 500.05, expected_row)])
            self.assertAlmostEqual(records[0]["start"], 500.10)
            self.assertTrue(records[0]["path"].startswith(moved))
            self.assertTrue(os.path.isfile(records[0]["path"]))
            escaped = reopened.get_record(8)
            self.assertIsNone(escaped["path"])
            self.assertAlmostEqual(escaped["end"], 500.20)
            self.assertEqual(reopened.metadata["contains_iq"], "false")
            self.assertEqual(reopened.metadata["audio_rate"], "12500")
            tables = {row[0] for row in reopened.connection.execute(
                "SELECT name FROM sqlite_master WHERE type='table'")}
            self.assertEqual(tables, {"metadata", "frames", "conversations"})
            self.assertEqual(
                reopened.connection.execute("PRAGMA quick_check").fetchone()[0], "ok")
            reopened.close()

    def test_record_session_rejects_an_external_record_directory(self):
        with tempfile.TemporaryDirectory() as root:
            argv = ["frs_all_channels.py", "--record-session",
                    os.path.join(root, "session"), "--record-dir",
                    os.path.join(root, "elsewhere")]
            with patch("sys.argv", argv), self.assertRaisesRegex(
                    SystemExit, "owns its audio directory"):
                main()

    def test_saved_session_initial_tail_and_lazy_history_are_disjoint(self):
        with tempfile.TemporaryDirectory() as root:
            path = os.path.join(root, "long.frs-session")
            archive = SessionArchive.create(path, 465_125_000, 8_000_000)
            archive.set_display_origin(100.0)
            row = bytes([77]) * 4096
            for sequence in range(1, 2501):
                archive.add_frame(sequence, 100 + sequence * 0.05, row)
            archive.close()

            reopened = SessionArchive.open(path)
            receiver = SavedSessionReceiver(reopened)
            server = WebDashboardServer(
                receiver, "127.0.0.1", 0, session=reopened, archived=True)
            server.start()
            base = f"http://127.0.0.1:{server.server.server_address[1]}"
            try:
                with urllib.request.urlopen(
                        f"{base}/api/updates?after=0&token={server.token}") as response:
                    initial = json.loads(response.read())
                self.assertEqual(len(initial["frames"]), 800)
                self.assertFalse(initial["timeline"]["live"])
                first_time = initial["frames"][0][1]
                with urllib.request.urlopen(
                        f"{base}/api/history?before={first_time}"
                        f"&limit=900&token={server.token}") as response:
                    history = json.loads(response.read())
                self.assertEqual(len(history["frames"]), 900)
                self.assertTrue(history["more_before"])
                self.assertLess(history["frames"][-1][1], first_time)
                self.assertTrue(
                    {frame[0] for frame in initial["frames"]}.isdisjoint(
                        frame[0] for frame in history["frames"]))
                with urllib.request.urlopen(
                        f"{base}/?token={server.token}") as response:
                    page = response.read().decode()
                self.assertIn("ARCHIVED=true", page)
                self.assertIn("FRS session browser", page)
                self.assertNotIn("__SESSION_LABEL__", page)
            finally:
                receiver.stop()
                server.stop()

    def test_saved_session_channel_stream_preserves_audio_gaps(self):
        with tempfile.TemporaryDirectory() as root:
            path = os.path.join(root, "audio.frs-session")
            archive = SessionArchive.create(path, 465_125_000, 8_000_000)
            archive.set_display_origin(10.0)
            archive.add_frame(1, 10.0, bytes([10]) * 4096)
            archive.add_frame(2, 10.2, bytes([10]) * 4096)
            channel_dir = os.path.join(archive.audio_directory, "channel_03")
            os.makedirs(channel_dir)
            for record_id, start, value in ((1, 0.0, b"\x11\x11"),
                                             (2, 0.05, b"\x22\x22")):
                wav_path = os.path.join(channel_dir, f"{record_id}.wav")
                with wave.open(wav_path, "wb") as output:
                    output.setparams((1, 2, 16_000, 0, "NONE", ""))
                    output.writeframes(value * 160)
                record = {"id": record_id, "channel": 3,
                          "frequency": 462_612_500,
                          "start": 10 + start, "end": None, "path": wav_path}
                archive.start_record(record)
                record["end"] = 10 + start + 0.01
                archive.end_record(record)
            archive.close()

            reopened = SessionArchive.open(path)
            receiver = SavedSessionReceiver(reopened)
            server = WebDashboardServer(
                receiver, "127.0.0.1", 0, session=reopened, archived=True)
            server.start()
            base = f"http://127.0.0.1:{server.server.server_address[1]}"
            start = receiver.timeline_origin
            try:
                response = urllib.request.urlopen(
                    f"{base}/api/channel-stream?channel=3&start={start}"
                    f"&token={server.token}", timeout=2)
                try:
                    pcm = response.read(2_500)
                finally:
                    response.close()
                self.assertEqual(pcm[:250], b"\x11\x11" * 125)
                self.assertEqual(pcm[250:1_250], b"\x00" * 1_000)
                self.assertEqual(pcm[1_250:1_500], b"\x22\x22" * 125)
            finally:
                receiver.stop()
                server.stop()

    def test_web_test_fixture_records_and_streams_12500hz(self):
        with tempfile.TemporaryDirectory() as directory:
            args = SimpleNamespace(center_freq=None, sample_rate=8_000_000,
                                   squelch=-55.0, channel_gain=0.25,
                                   record_dir=directory)
            receiver = RealtimeWebTestReceiver(args)
            receiver.start()
            time.sleep(0.36)
            receiver.stop()
            receiver.wait()
            channel_dir = os.path.join(directory, "channel_01")
            recordings = os.listdir(channel_dir)
            self.assertEqual(len(recordings), 1)
            with wave.open(os.path.join(channel_dir, recordings[0]), "rb") as source:
                self.assertEqual(source.getframerate(), 12_500)
                self.assertGreater(source.getnframes(), 0)
            self.assertEqual(len(receiver.web_audio.get_nowait()), 12_500 // 50 * 2)

    def test_remote_squelch_and_recording_download(self):
        request = urllib.request.Request(
            f"{self.base}/api/squelch?value=-51&token={self.token}", method="POST")
        with urllib.request.urlopen(request) as response:
            self.assertEqual(response.status, 204)
        self.assertEqual(self.receiver.squelch, -51.0)

        with tempfile.TemporaryDirectory() as directory:
            path = os.path.join(directory, "clip.wav")
            with wave.open(path, "wb") as output:
                output.setparams((1, 2, 48_000, 0, "NONE", ""))
                output.writeframes(b"\x00\x00" * 4_800)
            self.receiver.activity_events.put(("start", 1, 1.0, path))
            self.receiver.activity_events.put(("end", 1, 1.5, path))
            data = self.wait_updates(lambda value: bool(value["records"]))
            record_id = data["records"][0]["id"]
            status, body, headers = self.get(
                f"/api/recording?id={record_id}&token={self.token}")
            self.assertEqual(status, 200)
            self.assertEqual(headers.get_content_type(), "audio/wav")
            self.assertTrue(body.startswith(b"RIFF"))
            _, sliced, _ = self.get(
                f"/api/recording?id={record_id}&offset=0.05&token={self.token}")
            self.assertLess(len(sliced), len(body))

    def test_invalid_api_parameters_return_400(self):
        for path in ("/api/updates?after=nope",
                     "/api/live?after=-1",
                     "/api/history?before=nan",
                     "/api/history?before=10&limit=0",
                     "/api/recording?id=nope"):
            with self.assertRaises(urllib.error.HTTPError) as rejected:
                self.get(f"{path}&token={self.token}")
            self.assertEqual(rejected.exception.code, 400)
            rejected.exception.close()
        request = urllib.request.Request(
            f"{self.base}/api/squelch?value=nan&token={self.token}", method="POST")
        with self.assertRaises(urllib.error.HTTPError) as rejected:
            urllib.request.urlopen(request)
        self.assertEqual(rejected.exception.code, 400)
        rejected.exception.close()

    def test_sample_clock_timestamps_do_not_follow_scheduler_time(self):
        fft_events = queue.Queue()
        fft = SpectrumFrameSink(32, fft_events, timeline_origin=100.0,
                                frame_interval=0.05)
        fft.work([np.ones((3, 32), dtype=np.complex64)], [])
        stamps = [fft_events.get()[0] for _ in range(3)]
        self.assertEqual(stamps, [100.0, 100.05, 100.1])

        audio_events = queue.Queue()
        recorder = ConversationRecorder(1, 48_000, "", audio_events,
                                        timeline_origin=100.0,
                                        hang_seconds=0.1)
        recorder.work([np.ones(4_800, dtype=np.float32)], [])
        recorder.work([np.zeros(4_800, dtype=np.float32)], [])
        opened = audio_events.get()
        closed = audio_events.get()
        self.assertEqual(opened[0], "start")
        self.assertAlmostEqual(opened[2], 100.0)
        self.assertEqual(closed[0], "end")
        self.assertAlmostEqual(closed[2], 100.2)

    def test_consolidated_channel_monitor_tracks_and_closes_independently(self):
        events = queue.Queue()
        monitor = ChannelMonitorSink(16_000, "", events, 100.0, 0.25,
                                     hang_seconds=0.1)
        inputs = [np.zeros(1_600, dtype=np.float32) for _ in FRS_CHANNELS_HZ]
        inputs[2][:] = 1.0
        monitor.work(inputs, [])
        self.assertAlmostEqual(monitor.levels[2], 0.25)
        self.assertEqual(events.get()[:3], ("start", 3, 100.0))
        monitor.work([np.zeros(1_600, dtype=np.float32)
                      for _ in FRS_CHANNELS_HZ], [])
        self.assertEqual(events.get()[:2], ("end", 3))
        self.assertAlmostEqual(monitor.processed / 16_000, 0.2)

    def test_default_recorder_writes_no_post_key_off_silence(self):
        with tempfile.TemporaryDirectory() as directory:
            events = queue.Queue()
            monitor = ChannelMonitorSink(
                16_000, directory, events, 100.0, 0.25)
            active = [np.zeros(1_600, dtype=np.float32)
                      for _ in FRS_CHANNELS_HZ]
            active[0][:] = 1.0
            monitor.work(active, [])
            started = events.get()
            monitor.work([np.zeros(1_600, dtype=np.float32)
                          for _ in FRS_CHANNELS_HZ], [])
            ended = events.get()
            self.assertEqual(started[:2], ("start", 1))
            self.assertEqual(ended[:2], ("end", 1))
            self.assertAlmostEqual(ended[2], 100.1)
            with wave.open(started[3], "rb") as recording:
                self.assertEqual(recording.getnframes(), 1_600)

    def test_optimized_default_sample_rate_covers_all_frs_channels(self):
        half = DEFAULT_SAMPLE_RATE / 2
        self.assertGreaterEqual(FRSReceiver.LOWEST_HZ - 15_000,
                                FRSReceiver.PLUTO_CENTER_HZ - half)
        self.assertLessEqual(FRSReceiver.HIGHEST_HZ + 15_000,
                             FRSReceiver.PLUTO_CENTER_HZ + half)
        self.assertEqual(DEFAULT_SAMPLE_RATE % 12_500, 0)

    def test_sparse_channelizer_geometry_and_adjacent_stress_case(self):
        self.assertEqual(FRSReceiver.SUBBAND_RATE // 12_500, 32)
        for frequency in FRS_CHANNELS_HZ:
            covering = [center for center in FRSReceiver.SUBBAND_CENTERS_HZ
                        if abs(frequency - center) <= 100_000]
            self.assertEqual(len(covering), 1)

        # Channels 15 and 1 are directly adjacent on the 12.5 kHz grid. The
        # full-DSP self-test runs them simultaneously with a 50 dB imbalance.
        self.assertEqual(FRS_CHANNELS_HZ[0] - FRS_CHANNELS_HZ[14], 12_500)
        simultaneous = {
            channel: snr for start, end, channel, snr, _tone, _label
            in TEST_CONVERSATIONS if start <= 0.25 < end
        }
        self.assertEqual(simultaneous[1] - simultaneous[15], 50.0)


if __name__ == "__main__":
    unittest.main()
