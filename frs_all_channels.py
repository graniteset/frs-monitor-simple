#!/usr/bin/env python3
"""Simultaneously receive, squelch, and mix all 22 analog FRS channels.

Requires GNU Radio 3.10 and gr-osmosdr.  The SDR must provide enough usable
bandwidth to cover 462.5500 through 467.7125 MHz at the same time.
"""

import argparse
import base64
import datetime as dt
import json
import io
import os
import queue
import secrets
import signal
import socket
import sqlite3
import subprocess
import sys
import threading
import time
import wave
import zlib
from collections import deque
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse

import numpy as np
import osmosdr
from gnuradio import analog, audio, blocks, filter, gr
from gnuradio.fft import window
from gnuradio.filter import firdes
from PyQt5 import QtCore, QtGui, QtWidgets


FRS_CHANNELS_HZ = (
    462_562_500, 462_587_500, 462_612_500, 462_637_500,
    462_662_500, 462_687_500, 462_712_500,
    467_562_500, 467_587_500, 467_612_500, 467_637_500,
    467_662_500, 467_687_500, 467_712_500,
    462_550_000, 462_575_000, 462_600_000, 462_625_000,
    462_650_000, 462_675_000, 462_700_000, 462_725_000,
)
WEB_HISTORY_SECONDS = 10 * 60
WATERFALL_ROWS_PER_SECOND = 20
TEST_NOISE_FLOOR_DB = -96.0
TEST_IQ_NOISE_STD = 8.0e-4
DEFAULT_SAMPLE_RATE = 6_400_000
TEST_IQ_PERIOD = 12.0

TEST_CONVERSATIONS = (
    # start, end, channel, SNR above the synthetic noise floor, tone, label
    (0.20, 1.35, 1, 60.0, 720.0, "Meet at the trailhead"),
    (0.25, 1.75, 8, 45.0, 1120.0, "Copy, arriving in five"),
    (0.20, 1.35, 15, 10.0, 1650.0, "Below squelch test"),
    (2.40, 3.55, 3, 42.0, 840.0, "Did you bring the map?"),
    (4.15, 5.25, 3, 50.0, 1260.0, "Yes, it is in my pack"),
    (5.75, 7.10, 20, 30.0, 930.0, "Base to team, radio check"),
    (6.35, 7.55, 6, 55.0, 1380.0, "Team two reads you clearly"),
    (9.00, 10.40, 12, 40.0, 1040.0, "Returning to camp now"),
)


class SessionArchive:
    """Portable waterfall/audio session backed by a small SQLite index."""

    SCHEMA_VERSION = 1
    DATABASE_NAME = "session.sqlite3"

    def __init__(self, directory, connection, metadata, writable=False):
        self.directory = os.path.abspath(directory)
        self.database_path = os.path.join(self.directory, self.DATABASE_NAME)
        self.connection = connection
        self.metadata = metadata
        self.writable = writable
        self.display_origin = 0.0
        self.lock = threading.RLock()
        self.dirty = False
        self.last_commit = time.monotonic()
        self.closed = False
        with self.lock:
            row = self.connection.execute(
                "SELECT MIN(time_us), MAX(time_us), MAX(seq) FROM frames"
            ).fetchone()
        self.first_time_us = row[0]
        self.last_time_us = row[1]
        self.last_sequence = row[2] or 0

    @classmethod
    def validate_new_directory(cls, directory):
        path = Path(directory).expanduser().resolve()
        if path.exists() and (not path.is_dir() or any(path.iterdir())):
            raise FileExistsError(
                f"session directory must be new or empty: {path}"
            )
        return str(path)

    @classmethod
    def create(cls, directory, center_hz, sample_rate):
        directory = cls.validate_new_directory(directory)
        os.makedirs(directory, exist_ok=True)
        os.makedirs(os.path.join(directory, "audio"), exist_ok=True)
        database_path = os.path.join(directory, cls.DATABASE_NAME)
        connection = sqlite3.connect(database_path, check_same_thread=False)
        connection.execute("PRAGMA journal_mode=WAL")
        connection.execute("PRAGMA synchronous=NORMAL")
        connection.executescript(
            """
            CREATE TABLE metadata (
                key TEXT PRIMARY KEY,
                value TEXT NOT NULL
            );
            CREATE TABLE frames (
                seq INTEGER PRIMARY KEY,
                time_us INTEGER NOT NULL,
                row BLOB NOT NULL
            );
            CREATE INDEX frames_time ON frames(time_us);
            CREATE TABLE conversations (
                id INTEGER PRIMARY KEY,
                channel INTEGER NOT NULL,
                frequency INTEGER NOT NULL,
                start_us INTEGER NOT NULL,
                end_us INTEGER,
                audio_path TEXT
            );
            CREATE INDEX conversations_time
                ON conversations(start_us, end_us);
            CREATE INDEX conversations_channel
                ON conversations(channel, start_us);
            """
        )
        metadata = {
            "schema_version": str(cls.SCHEMA_VERSION),
            "created_utc": dt.datetime.now(dt.timezone.utc).isoformat(),
            "center_hz": str(round(center_hz)),
            "sample_rate": str(round(sample_rate)),
            "audio_rate": "12500",
            "fft_bins": "4096",
            "waterfall_fps": str(WATERFALL_ROWS_PER_SECOND),
            "waterfall_encoding": "uint8-zlib",
            "contains_iq": "false",
        }
        connection.executemany(
            "INSERT INTO metadata(key, value) VALUES (?, ?)", metadata.items())
        connection.commit()
        return cls(directory, connection, metadata, writable=True)

    @classmethod
    def open(cls, directory):
        directory = str(Path(directory).expanduser().resolve())
        database_path = os.path.join(directory, cls.DATABASE_NAME)
        if not os.path.isfile(database_path):
            raise FileNotFoundError(f"not an FRS session: {database_path} is missing")
        uri = Path(database_path).as_uri() + "?mode=ro"
        connection = None
        try:
            connection = sqlite3.connect(
                uri, uri=True, check_same_thread=False)
            metadata = dict(connection.execute(
                "SELECT key, value FROM metadata").fetchall())
            version = int(metadata.get("schema_version", -1))
            if version != cls.SCHEMA_VERSION:
                raise ValueError(
                    f"unsupported FRS session version {version}; "
                    f"expected {cls.SCHEMA_VERSION}"
                )
            check = connection.execute("PRAGMA quick_check").fetchone()[0]
            if check != "ok":
                raise ValueError(f"session database check failed: {check}")
            int(metadata["center_hz"])
            int(metadata["sample_rate"])
        except (KeyError, sqlite3.DatabaseError, ValueError):
            if connection is not None:
                connection.close()
            raise
        return cls(directory, connection, metadata, writable=False)

    @property
    def audio_directory(self):
        return os.path.join(self.directory, "audio")

    @property
    def center_hz(self):
        return int(self.metadata["center_hz"])

    @property
    def sample_rate(self):
        return int(self.metadata["sample_rate"])

    @property
    def created_utc(self):
        return self.metadata.get("created_utc", "")

    def set_display_origin(self, origin):
        self.display_origin = float(origin)

    def _relative_us(self, timestamp):
        return max(0, round((float(timestamp) - self.display_origin) * 1_000_000))

    def _display_time(self, time_us):
        return self.display_origin + time_us / 1_000_000.0

    def _commit_if_due(self):
        if self.dirty and time.monotonic() - self.last_commit >= 1.0:
            self.connection.commit()
            self.dirty = False
            self.last_commit = time.monotonic()

    def add_frame(self, sequence, timestamp, row):
        if not self.writable:
            return
        expected_bins = int(self.metadata.get("fft_bins", "4096"))
        if len(row) != expected_bins:
            raise ValueError(
                f"waterfall row has {len(row)} bins; expected {expected_bins}")
        time_us = self._relative_us(timestamp)
        encoded = zlib.compress(row, level=1)
        with self.lock:
            self.connection.execute(
                "INSERT INTO frames(seq, time_us, row) VALUES (?, ?, ?)",
                (int(sequence), time_us, encoded),
            )
            self.first_time_us = (time_us if self.first_time_us is None
                                  else min(self.first_time_us, time_us))
            self.last_time_us = (time_us if self.last_time_us is None
                                 else max(self.last_time_us, time_us))
            self.last_sequence = max(self.last_sequence, int(sequence))
            self.dirty = True
            self._commit_if_due()

    def _portable_audio_path(self, path):
        if not path:
            return None
        root = os.path.realpath(self.directory)
        absolute = os.path.realpath(path)
        try:
            if os.path.commonpath((root, absolute)) != root:
                return None
        except ValueError:
            return None
        return os.path.relpath(absolute, self.directory)

    def _resolved_audio_path(self, relative):
        if not relative or os.path.isabs(relative):
            return None
        root = os.path.realpath(self.directory)
        candidate = os.path.realpath(os.path.join(self.directory, relative))
        try:
            if os.path.commonpath((root, candidate)) != root:
                return None
        except ValueError:
            return None
        return candidate

    def start_record(self, record):
        if not self.writable:
            return
        values = (
            int(record["id"]), int(record["channel"]),
            int(record["frequency"]), self._relative_us(record["start"]),
            self._portable_audio_path(record.get("path")),
        )
        with self.lock:
            self.connection.execute(
                """INSERT INTO conversations
                   (id, channel, frequency, start_us, end_us, audio_path)
                   VALUES (?, ?, ?, ?, NULL, ?)""", values)
            self.dirty = True
            self._commit_if_due()

    def end_record(self, record):
        if not self.writable or record.get("end") is None:
            return
        with self.lock:
            self.connection.execute(
                "UPDATE conversations SET end_us=? WHERE id=?",
                (self._relative_us(record["end"]), int(record["id"])),
            )
            self.dirty = True
            self._commit_if_due()

    def _record_from_row(self, row):
        record_id, channel, frequency, start_us, end_us, audio_path = row
        return {
            "id": record_id,
            "channel": channel,
            "frequency": frequency,
            "start": self._display_time(start_us),
            "end": self._display_time(end_us) if end_us is not None else None,
            "path": self._resolved_audio_path(audio_path),
        }

    def frames_before(self, before, limit):
        before_us = self._relative_us(before)
        with self.lock:
            rows = self.connection.execute(
                """SELECT seq, time_us, row FROM frames
                   WHERE time_us < ? ORDER BY time_us DESC, seq DESC LIMIT ?""",
                (before_us, int(limit)),
            ).fetchall()
        rows.reverse()
        expected_bins = int(self.metadata.get("fft_bins", "4096"))
        decoded = []
        for sequence, time_us, encoded in rows:
            decompressor = zlib.decompressobj()
            row = decompressor.decompress(encoded, expected_bins + 1)
            if (len(row) != expected_bins or decompressor.unconsumed_tail or
                    not decompressor.eof):
                raise ValueError("invalid compressed waterfall row")
            decoded.append((sequence, self._display_time(time_us), row))
        return decoded

    def records_between(self, start, end, channel=None):
        start_us, end_us = self._relative_us(start), self._relative_us(end)
        sql = (
            "SELECT id, channel, frequency, start_us, end_us, audio_path "
            "FROM conversations WHERE start_us <= ? "
            "AND COALESCE(end_us, ?) >= ?"
        )
        values = [end_us, end_us, start_us]
        if channel is not None:
            sql += " AND channel=?"
            values.append(int(channel))
        sql += " ORDER BY start_us, id"
        with self.lock:
            rows = self.connection.execute(sql, values).fetchall()
        return [self._record_from_row(row) for row in rows]

    def get_record(self, record_id):
        with self.lock:
            row = self.connection.execute(
                """SELECT id, channel, frequency, start_us, end_us, audio_path
                   FROM conversations WHERE id=?""", (int(record_id),)
            ).fetchone()
        return self._record_from_row(row) if row else None

    def timeline_bounds(self):
        if self.first_time_us is None or self.last_time_us is None:
            return self.display_origin, self.display_origin
        return (self._display_time(self.first_time_us),
                self._display_time(self.last_time_us))

    def finish(self):
        if not self.writable or self.closed:
            return
        with self.lock:
            duration_us = self.last_time_us or 0
            record_end = self.connection.execute(
                "SELECT MAX(COALESCE(end_us, start_us)) FROM conversations"
            ).fetchone()[0]
            duration_us = max(duration_us, record_end or 0)
            self.connection.execute(
                "UPDATE conversations SET end_us=? WHERE end_us IS NULL",
                (duration_us,),
            )
            ended = dt.datetime.now(dt.timezone.utc).isoformat()
            self.connection.executemany(
                "INSERT OR REPLACE INTO metadata(key, value) VALUES (?, ?)",
                (("duration_us", str(duration_us)), ("ended_utc", ended)),
            )
            self.connection.commit()
            self.metadata["duration_us"] = str(duration_us)
            self.metadata["ended_utc"] = ended
            self.dirty = False

    def close(self):
        if self.closed:
            return
        if self.writable:
            self.finish()
        with self.lock:
            self.connection.close()
            self.closed = True


class SavedSessionReceiver:
    """Receiver-shaped adapter used to browse a completed disk session."""

    def __init__(self, archive):
        self.archive = archive
        self.center_hz = archive.center_hz
        self.sample_rate = archive.sample_rate
        self.audio_rate = int(archive.metadata.get("audio_rate", "12500"))
        duration = int(archive.metadata.get("duration_us", "0")) / 1_000_000.0
        if archive.last_time_us is not None:
            duration = max(duration, archive.last_time_us / 1_000_000.0)
        self.timeline_origin = time.monotonic() - duration
        archive.set_display_origin(self.timeline_origin)
        self.spectrum_frames = queue.Queue()
        self.activity_events = queue.Queue()
        self.web_audio = queue.Queue()
        self.stopped = threading.Event()
        self.live_audio_available = False

    def set_squelch(self, _threshold):
        pass

    def set_live_audio(self, _enabled):
        pass

    def channel_levels(self):
        return [0.0] * len(FRS_CHANNELS_HZ)

    def start(self):
        pass

    def stop(self):
        self.stopped.set()

    def wait(self):
        self.stopped.wait()


class RealtimeWebTestReceiver:
    """Wall-clock-paced dashboard fixture; the RF self-test still uses the DSP graph."""

    AUDIO_RATE = 12_500
    RECORD_RATE = 12_500
    FRAME_SAMPLES = 250
    PERIOD = 12.0

    def __init__(self, args):
        self.center_hz = args.center_freq or FRSReceiver.PLUTO_CENTER_HZ
        self.sample_rate = args.sample_rate
        self.audio_rate = self.AUDIO_RATE
        self.squelch = float(args.squelch)
        self.channel_gain = float(args.channel_gain)
        self.record_dir = args.record_dir
        self.timeline_origin = time.monotonic()
        self.spectrum_frames = queue.Queue(maxsize=200)
        self.activity_events = queue.Queue()
        self.web_audio = queue.Queue(maxsize=100)
        self.running = False
        self.thread = threading.Thread(target=self._run, daemon=True)
        self.rng = np.random.default_rng(0x465125)
        self.open_recordings = {}

    def set_squelch(self, threshold):
        self.squelch = float(threshold)

    def set_live_audio(self, enabled):
        pass

    def channel_levels(self):
        return [0.0] * len(FRS_CHANNELS_HZ)

    @staticmethod
    def _put_latest(destination, item):
        try:
            destination.put_nowait(item)
        except queue.Full:
            try:
                destination.get_nowait()
            except queue.Empty:
                pass
            destination.put_nowait(item)

    def _open_recording(self, key, conversation, timestamp):
        _start, _end, channel, _snr_db, _tone, _label = conversation
        path = None
        output = None
        if self.record_dir:
            channel_dir = os.path.join(self.record_dir, f"channel_{channel:02d}")
            os.makedirs(channel_dir, exist_ok=True)
            stamp = dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%S.%fZ")
            path = os.path.join(channel_dir, f"frs_{channel:02d}_{stamp}.wav")
            output = wave.open(path, "wb")
            output.setparams((1, 2, self.RECORD_RATE, 0, "NONE", ""))
        self.open_recordings[key] = (channel, path, output)
        self.activity_events.put(("start", channel, timestamp, path))

    def _close_recording(self, key, timestamp):
        channel, path, output = self.open_recordings.pop(key)
        if output:
            output.close()
        self.activity_events.put(("end", channel, timestamp, path))

    def _spectrum(self, elapsed):
        row = self.rng.normal(
            TEST_NOISE_FLOOR_DB, 1.8, 4096).astype(np.float32)
        cycle = elapsed % self.PERIOD
        low = self.center_hz - self.sample_rate / 2
        for start, end, channel, snr_db, _tone, _label in TEST_CONVERSATIONS:
            if start <= cycle < end:
                center = round((FRS_CHANNELS_HZ[channel - 1] - low) /
                               self.sample_rate * len(row))
                level = TEST_NOISE_FLOOR_DB + snr_db
                for delta, falloff in ((0, 0), (-1, 7), (1, 7), (-2, 15), (2, 15)):
                    if 0 <= center + delta < len(row):
                        row[center + delta] = level - falloff
        return row

    def _run(self):
        chunk_seconds = self.FRAME_SAMPLES / self.AUDIO_RATE
        wall_origin = time.monotonic()
        chunk_index = 0
        next_spectrum = 0.0
        while self.running:
            target = wall_origin + chunk_index * chunk_seconds
            delay = target - time.monotonic()
            if delay > 0:
                time.sleep(delay)
            elapsed = chunk_index * chunk_seconds
            cycle_number = int(elapsed // self.PERIOD)
            cycle = elapsed - cycle_number * self.PERIOD
            samples_t = (chunk_index * self.FRAME_SAMPLES +
                         np.arange(self.FRAME_SAMPLES)) / self.AUDIO_RATE
            mixed = np.zeros(self.FRAME_SAMPLES, dtype=np.float32)
            wanted = {}
            for index, conversation in enumerate(TEST_CONVERSATIONS):
                start, end, channel, snr_db, tone, _label = conversation
                signal_db = TEST_NOISE_FLOOR_DB + snr_db
                if start <= cycle < end and signal_db >= self.squelch:
                    key = (cycle_number, index)
                    wanted[key] = conversation
                    local = samples_t - (cycle_number * self.PERIOD + start)
                    voice = (0.72 * np.sin(2 * np.pi * tone * local) +
                             0.28 * np.sin(2 * np.pi * tone * 1.37 * local))
                    channel_audio = (self.channel_gain * voice).astype(np.float32)
                    mixed += channel_audio
                    if key not in self.open_recordings:
                        self._open_recording(
                            key, conversation,
                            self.timeline_origin + cycle_number * self.PERIOD + start)
                    output = self.open_recordings[key][2]
                    if output:
                        output.writeframes(
                            (np.tanh(channel_audio) * 32767)
                            .astype("<i2").tobytes())
            for key in list(self.open_recordings):
                if key not in wanted:
                    conversation = TEST_CONVERSATIONS[key[1]]
                    self._close_recording(
                        key, self.timeline_origin + key[0] * self.PERIOD + conversation[1])
            pcm = (np.tanh(mixed) * 32767).astype("<i2").tobytes()
            self._put_latest(self.web_audio, pcm)
            while elapsed >= next_spectrum:
                self._put_latest(
                    self.spectrum_frames,
                    (self.timeline_origin + next_spectrum,
                     self._spectrum(next_spectrum)))
                next_spectrum += 0.05
            chunk_index += 1

        for key in list(self.open_recordings):
            self._close_recording(key, self.timeline_origin +
                                  chunk_index * chunk_seconds)

    def start(self):
        self.running = True
        self.thread.start()

    def stop(self):
        self.running = False

    def wait(self):
        if self.thread.ident is not None:
            self.thread.join()


def generate_synthetic_iq_file(path, sample_rate, center_hz, force=False):
    """Generate one deterministic test period as complex-float IQ."""
    path = str(Path(path).expanduser().resolve())
    sample_count = round(TEST_IQ_PERIOD * sample_rate)
    expected_bytes = sample_count * np.dtype(np.complex64).itemsize
    if not force and os.path.isfile(path) and os.path.getsize(path) == expected_bytes:
        return path
    os.makedirs(os.path.dirname(path), exist_ok=True)
    temporary = path + ".partial"
    rng = np.random.default_rng(0x465125)
    chunk_samples = 262_144
    with open(temporary, "wb") as output:
        for offset in range(0, sample_count, chunk_samples):
            count = min(chunk_samples, sample_count - offset)
            absolute_t = (offset + np.arange(count)) / sample_rate
            iq = ((rng.normal(size=count) + 1j * rng.normal(size=count)) *
                  TEST_IQ_NOISE_STD).astype(np.complex64)
            for start, end, channel, snr_db, tone_hz, _label in TEST_CONVERSATIONS:
                active = (absolute_t >= start) & (absolute_t < end)
                if not np.any(active):
                    continue
                carrier = FRS_CHANNELS_HZ[channel - 1] - center_hz
                local = absolute_t[active] - start
                modulation = (0.72 * np.sin(2 * np.pi * tone_hz * local) +
                              0.28 * np.sin(2 * np.pi * tone_hz * 1.37 * local))
                phase = (2 * np.pi * carrier * absolute_t[active] +
                         (2_500.0 / tone_hz) * modulation)
                amplitude = 10.0 ** ((TEST_NOISE_FLOOR_DB + snr_db) / 20.0)
                iq[active] += (amplitude * np.exp(1j * phase)).astype(np.complex64)
            output.write(iq.tobytes())
    os.replace(temporary, path)
    return path


class ChannelMonitorSink(gr.sync_block):
    """Monitor and record all demodulated channels in one scheduled block."""

    def __init__(self, sample_rate, directory, events, timeline_origin,
                 channel_gain, open_rms=0.002, hang_seconds=0.8):
        super().__init__(name="FRS channel monitor/recorder bank",
                         in_sig=[np.float32] * len(FRS_CHANNELS_HZ), out_sig=None)
        self.sample_rate = sample_rate
        self.directory = directory
        self.events = events
        self.timeline_origin = timeline_origin
        self.channel_gain = float(channel_gain)
        self.open_rms = open_rms
        self.hang_samples = int(hang_seconds * sample_rate)
        self.remaining = [0] * len(FRS_CHANNELS_HZ)
        self.wavs = [None] * len(FRS_CHANNELS_HZ)
        self.paths = [None] * len(FRS_CHANNELS_HZ)
        self.started = [None] * len(FRS_CHANNELS_HZ)
        self.levels = [0.0] * len(FRS_CHANNELS_HZ)
        self.processed = 0

    def _open(self, index, timestamp):
        channel = index + 1
        path = None
        output = None
        if self.directory:
            channel_dir = os.path.join(self.directory, f"channel_{channel:02d}")
            os.makedirs(channel_dir, exist_ok=True)
            stamp = dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%S.%fZ")
            path = os.path.join(channel_dir, f"frs_{channel:02d}_{stamp}.wav")
            output = wave.open(path, "wb")
            output.setparams((1, 2, self.sample_rate, 0, "NONE", ""))
        self.wavs[index] = output
        self.paths[index] = path
        self.started[index] = timestamp
        self.events.put(("start", channel, timestamp, path))

    def _close(self, index, timestamp=None):
        if self.wavs[index]:
            self.wavs[index].close()
        if self.started[index] is not None:
            ended = timestamp if timestamp is not None else (
                self.timeline_origin + self.processed / self.sample_rate)
            self.events.put(("end", index + 1, ended, self.paths[index]))
        self.wavs[index] = None
        self.paths[index] = None
        self.started[index] = None

    def work(self, input_items, output_items):
        count = len(input_items[0]) if input_items else 0
        block_start = self.timeline_origin + self.processed / self.sample_rate
        for index, raw in enumerate(input_items):
            samples = raw * self.channel_gain
            rms = float(np.sqrt(np.mean(samples * samples))) if count else 0.0
            self.levels[index] = rms
            if rms >= self.open_rms:
                self.remaining[index] = self.hang_samples
                if self.started[index] is None:
                    self._open(index, block_start)
            elif self.started[index] is not None:
                self.remaining[index] -= count
            if self.started[index] is not None and self.wavs[index]:
                pcm = np.clip(samples, -1.0, 1.0)
                self.wavs[index].writeframes(
                    (pcm * 32767).astype("<i2").tobytes())
        self.processed += count
        ended = self.timeline_origin + self.processed / self.sample_rate
        for index in range(len(input_items)):
            if self.started[index] is not None and self.remaining[index] <= 0:
                self._close(index, ended)
        return count

    def stop(self):
        for index in range(len(FRS_CHANNELS_HZ)):
            self._close(index)
        return True


class ConversationRecorder(gr.sync_block):
    """Segment one squelched audio stream into per-transmission WAV files."""

    def __init__(self, channel, sample_rate, directory, events, timeline_origin,
                 open_rms=0.002, hang_seconds=0.8):
        super().__init__(name=f"FRS {channel} conversation recorder",
                         in_sig=[np.float32], out_sig=None)
        self.channel = channel
        self.sample_rate = sample_rate
        self.directory = directory
        self.events = events
        self.timeline_origin = timeline_origin
        self.open_rms = open_rms
        self.hang_samples = int(hang_seconds * sample_rate)
        self.remaining = 0
        self.wav = None
        self.path = None
        self.started = None
        self.processed = 0

    def _open(self, timestamp):
        now = dt.datetime.now(dt.timezone.utc)
        stamp = now.strftime("%Y%m%dT%H%M%S.%fZ")
        self.path = None
        if self.directory:
            channel_dir = os.path.join(self.directory, f"channel_{self.channel:02d}")
            os.makedirs(channel_dir, exist_ok=True)
            self.path = os.path.join(channel_dir, f"frs_{self.channel:02d}_{stamp}.wav")
            self.wav = wave.open(self.path, "wb")
            self.wav.setnchannels(1)
            self.wav.setsampwidth(2)
            self.wav.setframerate(self.sample_rate)
        self.started = timestamp
        self.events.put(("start", self.channel, self.started, self.path))

    def _close(self, timestamp=None):
        if self.wav:
            self.wav.close()
        if self.started is not None:
            ended = timestamp if timestamp is not None else (
                self.timeline_origin + self.processed / self.sample_rate)
            self.events.put(("end", self.channel, ended, self.path))
        self.wav = None
        self.path = None
        self.started = None

    def work(self, input_items, output_items):
        samples = input_items[0]
        block_start = self.timeline_origin + self.processed / self.sample_rate
        rms = float(np.sqrt(np.mean(samples * samples))) if len(samples) else 0.0
        if rms >= self.open_rms:
            self.remaining = self.hang_samples
            if self.started is None:
                self._open(block_start)
        elif self.started is not None:
            self.remaining -= len(samples)

        if self.started is not None:
            if self.wav:
                pcm = np.clip(samples, -1.0, 1.0)
                self.wav.writeframes((pcm * 32767).astype("<i2").tobytes())
        self.processed += len(samples)
        if self.started is not None and self.remaining <= 0:
            self._close(self.timeline_origin + self.processed / self.sample_rate)
        return len(samples)

    def stop(self):
        self._close()
        return True


class SpectrumFrameSink(gr.sync_block):
    """Convert occasional wideband IQ vectors into timestamped dB rows."""

    def __init__(self, fft_size, output_queue, timeline_origin, frame_interval):
        super().__init__(name="FRS waterfall FFT frames",
                         in_sig=[(np.complex64, fft_size)], out_sig=None)
        self.fft_size = fft_size
        self.output_queue = output_queue
        self.timeline_origin = timeline_origin
        self.frame_interval = frame_interval
        self.frame_number = 0
        self.window = np.blackman(fft_size).astype(np.float32)
        self.scale = max(float(np.sum(self.window)), 1.0)

    def work(self, input_items, output_items):
        for vector in input_items[0]:
            spectrum = np.fft.fftshift(np.fft.fft(vector * self.window))
            db = 20.0 * np.log10(np.maximum(np.abs(spectrum) / self.scale, 1e-12))
            # The GUI owns history; the scheduler only transfers compact rows.
            stamp = self.timeline_origin + self.frame_number * self.frame_interval
            self.frame_number += 1
            frame = (stamp, db.astype(np.float32))
            try:
                self.output_queue.put_nowait(frame)
            except queue.Full:
                try:
                    self.output_queue.get_nowait()
                except queue.Empty:
                    pass
                self.output_queue.put_nowait(frame)
        return len(input_items[0])


class WebAudioSink(gr.sync_block):
    def __init__(self, output_queue, sample_rate=12_500):
        super().__init__(name="Browser live audio", in_sig=[np.float32], out_sig=None)
        self.output_queue = output_queue
        self.chunk_samples = sample_rate // 50
        self.pending = bytearray()

    def _publish(self, pcm):
        try:
            self.output_queue.put_nowait(pcm)
        except queue.Full:
            try:
                self.output_queue.get_nowait()
            except queue.Empty:
                pass
            self.output_queue.put_nowait(pcm)

    def work(self, input_items, output_items):
        # The composite is already soft-limited upstream; only quantize here.
        pcm = (np.clip(input_items[0], -1.0, 1.0) * 32767).astype("<i2").tobytes()
        self.pending.extend(pcm)
        chunk_bytes = self.chunk_samples * 2
        while len(self.pending) >= chunk_bytes:
            self._publish(bytes(self.pending[:chunk_bytes]))
            del self.pending[:chunk_bytes]
        return len(input_items[0])


class SoftLimiter(gr.sync_block):
    def __init__(self):
        super().__init__(name="Composite audio soft limiter",
                         in_sig=[np.float32], out_sig=[np.float32])

    def work(self, input_items, output_items):
        np.tanh(input_items[0], out=output_items[0])
        return len(output_items[0])


class FRSReceiver(gr.top_block):
    QUAD_RATE = 64_000
    CHANNEL_RATE = 25_000
    DEMOD_AUDIO_RATE = 12_500
    AUDIO_RATE = 12_500
    LOWEST_HZ = min(FRS_CHANNELS_HZ)
    HIGHEST_HZ = max(FRS_CHANNELS_HZ)
    PLUTO_CENTER_HZ = 465_125_000

    def __init__(self, args):
        super().__init__("All-channel FRS receiver")
        self.started_at = time.monotonic()
        self.timeline_origin = self.started_at
        self.activity_events = queue.Queue()
        self.spectrum_frames = queue.Queue(maxsize=200)
        self.web_audio = queue.Queue(maxsize=100)
        self.test_input = args.test_input
        self.sample_rate = args.sample_rate
        self.audio_rate = self.AUDIO_RATE

        if args.sample_rate % self.QUAD_RATE:
            raise ValueError(
                f"--sample-rate must be an integer multiple of {self.QUAD_RATE}"
            )
        if args.sample_rate % 400_000:
            raise ValueError("--sample-rate must also be an integer multiple of 400000")
        required = (self.HIGHEST_HZ - self.LOWEST_HZ) + 30_000
        if args.sample_rate < required:
            raise ValueError(
                f"all FRS channels need at least {required / 1e6:.3f} MS/s; "
                f"requested {args.sample_rate / 1e6:.3f} MS/s"
            )

        self.center_hz = args.center_freq or self.PLUTO_CENTER_HZ
        if round(self.center_hz) % 12_500:
            raise ValueError("--center-freq must lie on the 12.5 kHz channelizer grid")
        half_band = args.sample_rate / 2
        if (self.LOWEST_HZ - 15_000 < self.center_hz - half_band or
                self.HIGHEST_HZ + 15_000 > self.center_hz + half_band):
            raise ValueError("--center-freq/--sample-rate do not cover every channel")

        if args.test_input:
            default_iq = os.path.join(
                os.path.dirname(os.path.abspath(__file__)), "work",
                f"frs_test_{args.sample_rate}_{round(self.center_hz)}.cf32")
            iq_path = generate_synthetic_iq_file(
                getattr(args, "test_iq_file", None) or default_iq,
                args.sample_rate, self.center_hz,
                getattr(args, "regenerate_test_iq", False))
            vector = blocks.file_source(gr.sizeof_gr_complex, iq_path, True)
            pace = (blocks.copy(gr.sizeof_gr_complex)
                    if getattr(args, "benchmark_dsp", False) else
                    blocks.throttle(gr.sizeof_gr_complex, args.sample_rate, True))
            self.source = vector
            self.test_iq_path = iq_path
            self.connect(vector, pace)
            rf_stream = pace
        else:
            self.source = osmosdr.source(args=args.device)
            self.source.set_sample_rate(args.sample_rate)
            self.source.set_center_freq(self.center_hz, 0)
            self.source.set_freq_corr(args.ppm, 0)
            self.source.set_gain_mode(False, 0)
            self.source.set_gain(args.gain, 0)
            try:
                self.source.set_bandwidth(args.sample_rate, 0)
            except RuntimeError:
                pass
            rf_stream = self.source

        if args.gui or args.web or getattr(args, "benchmark_dsp", False):
            fft_size = 4096
            rows_per_second = 20
            vectorizer = blocks.stream_to_vector(gr.sizeof_gr_complex, fft_size)
            keep_n = max(1, round(args.sample_rate / fft_size / rows_per_second))
            keep = blocks.keep_one_in_n(
                gr.sizeof_gr_complex * fft_size,
                keep_n,
            )
            self.spectrum_sink = SpectrumFrameSink(
                fft_size, self.spectrum_frames, self.timeline_origin,
                keep_n * fft_size / args.sample_rate)
            self.connect(rf_stream, vectorizer, keep, self.spectrum_sink)

        # A single 12.5 kHz analysis bank shares the wideband transform across
        # every channel. Oversampling by two yields 25 kS/s channel outputs.
        channel_count = args.sample_rate // 12_500
        channel_taps = firdes.low_pass(
            1.0, args.sample_rate, 6_000, 4_000,
            window.WIN_HAMMING,
        )
        splitter = blocks.stream_to_streams(gr.sizeof_gr_complex, channel_count)
        channelizer = filter.pfb_channelizer_ccf(channel_count, channel_taps, 2.0)
        channelizer.set_tag_propagation_policy(gr.TPP_DONT)
        selected_bins = [
            round((frequency - self.center_hz) / 12_500) % channel_count
            for frequency in FRS_CHANNELS_HZ
        ]
        channelizer.set_channel_map(selected_bins)
        self.connect(rf_stream, splitter)
        for port in range(channel_count):
            self.connect((splitter, port), (channelizer, port))
        self.channelizers = [(splitter, channelizer)]

        demodulated = []
        self.channel_blocks = []  # Keep Python proxy objects alive.
        self.channel_monitor = ChannelMonitorSink(
            self.DEMOD_AUDIO_RATE, args.record_dir, self.activity_events,
            self.timeline_origin, args.channel_gain)
        for number, frequency in enumerate(FRS_CHANNELS_HZ, start=1):
            output_port = number - 1
            port = selected_bins[output_port]
            squelch = analog.simple_squelch_cc(args.squelch, args.squelch_alpha)
            demod = analog.nbfm_rx(
                audio_rate=self.DEMOD_AUDIO_RATE,
                quad_rate=self.CHANNEL_RATE,
                tau=75e-6,
                max_dev=2_500,
            )
            level = blocks.multiply_const_ff(args.channel_gain)
            self.connect((channelizer, output_port), squelch, demod, level)
            self.connect(demod, (self.channel_monitor, output_port))
            self.channel_blocks.append(
                (number, port, squelch, demod, level))
            demodulated.append(level)

        mixer = blocks.add_vff(1)
        for port, stream in enumerate(demodulated):
            self.connect(stream, (mixer, port))

        # Soft-limit the composite without AGC pumping or hard-clipped peaks.
        self.audio_limiter = SoftLimiter()  # Keep the Python block proxy alive.
        limiter = self.audio_limiter
        self.connect(mixer, limiter)
        if args.web or getattr(args, "benchmark_dsp", False):
            self.web_audio_sink = WebAudioSink(self.web_audio, self.AUDIO_RATE)
            self.connect(limiter, self.web_audio_sink)

        self.live_gate = blocks.copy(gr.sizeof_float)
        self.live_gate.set_enabled(not (args.gui or args.web) or args.live_audio)
        self.connect(limiter, self.live_gate)
        if args.wav:
            destination = blocks.wavfile_sink(
                args.wav, 1, self.AUDIO_RATE,
                blocks.FORMAT_WAV, blocks.FORMAT_PCM_16,
            )
        elif args.no_audio or args.test_input or args.web:
            destination = blocks.null_sink(gr.sizeof_float)
        else:
            destination = audio.sink(self.AUDIO_RATE, args.audio_device, True)
        self.connect(self.live_gate, destination)

    def set_squelch(self, threshold):
        for (_number, _port, squelch, _demod, _level) in self.channel_blocks:
            squelch.set_threshold(float(threshold))

    def set_live_audio(self, enabled):
        self.live_gate.set_enabled(bool(enabled))

    def channel_levels(self):
        return list(self.channel_monitor.levels)

    def processed_seconds(self):
        return self.channel_monitor.processed / self.DEMOD_AUDIO_RATE


class ConversationWaterfall(QtWidgets.QWidget):
    """One canvas for spectrogram history, activity borders, and playback."""

    def __init__(self, receiver, history_minutes=30):
        super().__init__()
        self.receiver = receiver
        self.frames = deque(maxlen=history_minutes * 60 * 20)
        self.records, self.active, self.hit_rects = [], {}, []
        self.history_offset = 0.0
        self.visible_seconds = 30.0
        self.drag_y = None
        self.dragged = False
        self.player = None
        self.playing = None
        self.play_started = None
        self.setMinimumHeight(430)
        self.setCursor(QtCore.Qt.OpenHandCursor)

    def plot_rect(self):
        return QtCore.QRectF(72, 38, max(1, self.width() - 92),
                             max(1, self.height() - 78))

    def go_live(self):
        self.history_offset = 0.0
        self.update()

    def start_record(self, channel, when, path):
        rec = {"channel": channel, "start": when, "end": None, "path": path}
        self.records.append(rec)
        self.active[channel] = rec

    def end_record(self, channel, when):
        rec = self.active.pop(channel, None)
        if rec:
            rec["end"] = when

    def ingest(self):
        while True:
            try:
                self.frames.append(self.receiver.spectrum_frames.get_nowait())
            except queue.Empty:
                break
        self.update()

    @staticmethod
    def colorize(values):
        v = np.clip((values + 110.0) / 110.0, 0.0, 1.0)
        r = np.clip(4.0 * (v - 0.62), 0, 1)
        g = np.clip(1.6 - 3.2 * np.abs(v - 0.55), 0, 1)
        b = np.clip(1.35 - 2.7 * v, 0, 1)
        return (np.stack((r, g, b), axis=-1) * 255).astype(np.uint8)

    def view_end(self):
        latest = self.frames[-1][0] if self.frames else time.monotonic()
        return latest - self.history_offset

    def time_to_y(self, timestamp, rect, end_time):
        return rect.bottom() - (end_time - timestamp) / self.visible_seconds * rect.height()

    def paintEvent(self, event):
        painter = QtGui.QPainter(self)
        painter.fillRect(self.rect(), QtGui.QColor("#171c22"))
        painter.setRenderHint(QtGui.QPainter.Antialiasing)
        plot = self.plot_rect()
        end_time = self.view_end()
        start_time = end_time - self.visible_seconds
        visible = [(stamp, row) for stamp, row in self.frames
                   if start_time <= stamp <= end_time]
        if visible:
            height = max(1, round(plot.height()))
            width = len(visible[0][1])
            rgb = np.zeros((height, width, 3), dtype=np.uint8)
            rgb[:] = (0, 18, 28)
            for index, (stamp, row) in enumerate(visible):
                y = int(np.clip((stamp - start_time) / self.visible_seconds *
                                (height - 1), 0, height - 1))
                if index + 1 < len(visible):
                    next_stamp = visible[index + 1][0]
                    next_y = int(np.clip((next_stamp - start_time) /
                                         self.visible_seconds * (height - 1),
                                         y + 1, height))
                else:
                    next_y = min(height, y + 2)
                rgb[y:next_y] = self.colorize(row)
            image = QtGui.QImage(rgb.data, width, height, rgb.strides[0],
                                 QtGui.QImage.Format_RGB888).copy()
            painter.drawImage(plot, image)
        else:
            painter.fillRect(plot, QtGui.QColor("#062f35"))
        painter.setPen(QtGui.QPen(QtGui.QColor("#aab4bd"), 1))
        painter.drawRect(plot)

        span = self.receiver.sample_rate
        low = self.receiver.center_hz - span / 2
        for tick in range(9):
            x = plot.left() + tick / 8 * plot.width()
            mhz = (low + tick / 8 * span) / 1e6
            painter.drawLine(QtCore.QPointF(x, plot.bottom()),
                             QtCore.QPointF(x, plot.bottom() + 5))
            painter.drawText(QtCore.QRectF(x - 42, plot.bottom() + 7, 84, 18),
                             QtCore.Qt.AlignCenter, f"{mhz:.3f}")
        painter.drawText(QtCore.QRectF(plot.left(), 2, plot.width(), 28),
                         QtCore.Qt.AlignCenter, "FRS waterfall history")

        self.hit_rects = []
        for rec in self.records[-1000:]:
            rec_end = rec["end"] or time.monotonic()
            if rec_end < start_time or rec["start"] > end_time:
                continue
            frequency = FRS_CHANNELS_HZ[rec["channel"] - 1]
            x = plot.left() + (frequency - low) / span * plot.width()
            y1 = self.time_to_y(rec["start"], plot, end_time)
            y2 = self.time_to_y(rec_end, plot, end_time)
            border = QtCore.QRectF(x - 8, y1, 16, max(5, y2 - y1)).intersected(plot)
            selected = rec is self.playing
            color = QtGui.QColor("white") if selected else QtGui.QColor.fromHsv(
                (rec["channel"] * 31) % 360, 210, 255)
            painter.setPen(QtGui.QPen(color, 4 if selected else 2))
            painter.drawRect(border)
            self.hit_rects.append((border.adjusted(-8, -3, 8, 3), rec))

        if self.playing and self.play_started is not None:
            elapsed = time.monotonic() - self.play_started
            duration = max(0.01, (self.playing["end"] or time.monotonic()) -
                           self.playing["start"])
            play_timestamp = self.playing["start"] + min(elapsed, duration)
            y = self.time_to_y(play_timestamp, plot, end_time)
            painter.setPen(QtGui.QPen(QtGui.QColor("white"), 3))
            painter.drawLine(QtCore.QPointF(plot.left(), y),
                             QtCore.QPointF(plot.right(), y))
            painter.fillRect(QtCore.QRectF(plot.left() + 8, plot.top() + 8, 155, 25),
                             QtGui.QColor(0, 0, 0, 190))
            painter.drawText(QtCore.QRectF(plot.left() + 14, plot.top() + 10, 145, 20),
                             f"▶ Playing channel {self.playing['channel']}")
            if self.player and self.player.poll() is not None:
                self.player = self.playing = self.play_started = None

        if self.history_offset > 0.05:
            painter.fillRect(QtCore.QRectF(plot.right() - 160, plot.top() + 8, 150, 25),
                             QtGui.QColor(0, 0, 0, 190))
            painter.setPen(QtGui.QColor("white"))
            painter.drawText(QtCore.QRectF(plot.right() - 153, plot.top() + 10, 140, 20),
                             QtCore.Qt.AlignRight,
                             f"{self.history_offset:.1f}s behind live")

    def wheelEvent(self, event):
        steps = event.angleDelta().y() / 120.0
        self.history_offset = max(0, self.history_offset + steps * 2.0)
        self.update()
        event.accept()

    def mousePressEvent(self, event):
        self.drag_y, self.dragged = event.pos().y(), False
        self.setCursor(QtCore.Qt.ClosedHandCursor)

    def mouseMoveEvent(self, event):
        if self.drag_y is None:
            return
        delta = event.pos().y() - self.drag_y
        self.dragged |= abs(delta) > 2
        self.history_offset = max(0, self.history_offset +
                                  delta / max(1, self.plot_rect().height()) *
                                  self.visible_seconds)
        self.drag_y = event.pos().y()
        self.update()

    def mouseReleaseEvent(self, event):
        self.setCursor(QtCore.Qt.OpenHandCursor)
        self.drag_y = None
        if self.dragged:
            return
        for rect, rec in reversed(self.hit_rects):
            if rect.contains(event.pos()) and rec["path"] and os.path.exists(rec["path"]):
                if self.player and self.player.poll() is None:
                    self.player.terminate()
                self.player = subprocess.Popen(
                    ["paplay", rec["path"]], stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL)
                self.playing, self.play_started = rec, time.monotonic()
                self.update()
                break


class ReceiverWindow:
    def __init__(self, receiver, initial_squelch):
        try:
            import sip
        except ImportError:
            from PyQt5 import sip
        self.receiver = receiver
        self.widget = QtWidgets.QWidget()
        self.widget.setWindowTitle("All-channel FRS receiver")
        layout = QtWidgets.QVBoxLayout(self.widget)
        title = QtWidgets.QLabel("22-channel FRS monitor — per-channel recording and mixed audio")
        title.setStyleSheet("font-size: 16px; font-weight: bold; padding: 6px")
        layout.addWidget(title)
        row = QtWidgets.QHBoxLayout()
        row.addWidget(QtWidgets.QLabel("Squelch threshold (dB):"))
        slider = QtWidgets.QSlider(QtCore.Qt.Horizontal)
        slider.setRange(-100, -20)
        slider.setValue(round(initial_squelch))
        value = QtWidgets.QLabel(f"{initial_squelch:.0f}")
        slider.valueChanged.connect(lambda x: (value.setText(str(x)), receiver.set_squelch(x)))
        row.addWidget(slider, 1)
        row.addWidget(value)
        layout.addLayout(row)
        controls = QtWidgets.QHBoxLayout()
        live_audio = QtWidgets.QPushButton("Live audio: off")
        live_audio.setCheckable(True)
        live_audio.toggled.connect(lambda on: (
            receiver.set_live_audio(on),
            live_audio.setText("Live audio: on" if on else "Live audio: off")))
        go_live = QtWidgets.QPushButton("● Live")
        controls.addWidget(live_audio)
        controls.addWidget(go_live)
        controls.addWidget(QtWidgets.QLabel(
            "Drag/wheel to browse • tap a border to play"), 1)
        layout.addLayout(controls)
        self.waterfall = ConversationWaterfall(receiver)
        go_live.clicked.connect(self.waterfall.go_live)
        layout.addWidget(self.waterfall, 1)
        self.timer = QtCore.QTimer(self.widget)
        self.timer.timeout.connect(self._update)
        self.timer.start(100)
        self.widget.resize(1150, 720)
        self.widget.show()

    def _update(self):
        self.waterfall.ingest()
        while True:
            try:
                kind, channel, timestamp, path = self.receiver.activity_events.get_nowait()
            except queue.Empty:
                break
            if kind == "start":
                self.waterfall.start_record(channel, timestamp, path)
            else:
                self.waterfall.end_record(channel, timestamp)
        self.waterfall.update()


class WebDashboardServer:
    """Token-protected LAN dashboard with optional durable session history."""

    def __init__(self, receiver, host, port, session=None, archived=False):
        self.receiver, self.token = receiver, secrets.token_urlsafe(18)
        self.audio_rate = int(getattr(receiver, "audio_rate", 12_500))
        self.session, self.archived = session, bool(archived)
        self.frames = deque(
            maxlen=WATERFALL_ROWS_PER_SECOND * WEB_HISTORY_SECONDS)
        self.audio = deque(maxlen=400)
        self.records, self.active = [], {}
        self.frame_seq = self.audio_seq = self.record_seq = 0
        self.lock = threading.Lock()
        self.audio_condition = threading.Condition(self.lock)
        self.last_prune = 0.0
        self.running = True
        with open(os.path.join(os.path.dirname(__file__), "web", "dashboard.html"),
                  encoding="utf-8") as source:
            self.html = source.read()
        if self.archived and self.session is not None:
            _start, end = self.session.timeline_bounds()
            tail = self.session.frames_before(end + 1.0, 800)
            self.frames.extend(tail)
            self.frame_seq = self.session.last_sequence
            if tail:
                self.records.extend(
                    self.session.records_between(tail[0][1], end))
                self.record_seq = max(
                    (record["id"] for record in self.records), default=0)
        dashboard = self

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, fmt, *args):
                return

            def authorized(self, query):
                return query.get("token", [""])[0] == dashboard.token

            def send_bytes(self, code, content_type, body):
                self.send_response(code)
                self.send_header("Content-Type", content_type)
                self.send_header("Content-Length", str(len(body)))
                self.send_header("Cache-Control", "no-store")
                self.end_headers()
                self.wfile.write(body)

            def render_channel_pcm(self, channel, start, frame_count=None):
                """Render 100 ms of a channel timeline at its transport rate."""
                output_rate = dashboard.audio_rate
                frame_count = frame_count or output_rate // 10
                end = start + frame_count / output_rate
                rendered = np.zeros(frame_count, dtype="<i2")
                if dashboard.session is not None:
                    records = dashboard.session.records_between(
                        start, end, channel=channel)
                else:
                    with dashboard.lock:
                        records = [dict(record) for record in dashboard.records
                                   if record["channel"] == channel]
                for record in records:
                    record_end = record["end"] if record["end"] is not None else end
                    overlap_start = max(start, record["start"])
                    overlap_end = min(end, record_end)
                    path = record.get("path")
                    if overlap_end <= overlap_start or not path or not os.path.isfile(path):
                        continue
                    try:
                        with wave.open(path, "rb") as source:
                            if (source.getnchannels() != 1 or
                                    source.getsampwidth() != 2 or
                                    not 8_000 <= source.getframerate() <= 48_000):
                                continue
                            destination_first = max(
                                0, round((overlap_start - start) * output_rate))
                            destination_last = min(
                                frame_count,
                                round((overlap_end - start) * output_rate),
                            )
                            if destination_last <= destination_first:
                                continue
                            destination_frames = np.arange(
                                destination_first, destination_last)
                            source_positions = (
                                start + destination_frames / output_rate -
                                record["start"]
                            ) * source.getframerate()
                            source_first = max(0, int(np.floor(source_positions[0])))
                            source_last = min(
                                source.getnframes() - 1,
                                int(np.ceil(source_positions[-1])),
                            )
                            if source_last < source_first:
                                continue
                            source.setpos(source_first)
                            source_samples = np.frombuffer(
                                source.readframes(source_last - source_first + 1),
                                dtype="<i2",
                            )
                            if not len(source_samples):
                                continue
                            interpolated = np.interp(
                                source_positions - source_first,
                                np.arange(len(source_samples)),
                                source_samples,
                            )
                            rendered[destination_first:destination_last] = np.rint(
                                interpolated).astype("<i2")
                    except (EOFError, OSError, ValueError, wave.Error):
                        # An active WAV can be between header updates; its next
                        # 100 ms segment will retry while the timeline continues.
                        continue
                return rendered.tobytes()

            def do_GET(self):
                parsed = urlparse(self.path)
                query = parse_qs(parsed.query)
                if not self.authorized(query):
                    self.send_bytes(403, "text/plain", b"Invalid dashboard token")
                    return
                if parsed.path == "/":
                    body = dashboard.html.replace("__TOKEN__", dashboard.token)
                    body = body.replace("__CENTER__", str(receiver.center_hz))
                    body = body.replace("__RATE__", str(receiver.sample_rate))
                    body = body.replace("__AUDIO_RATE__", str(dashboard.audio_rate))
                    body = body.replace(
                        "__ARCHIVED__", "true" if dashboard.archived else "false")
                    label = ""
                    if dashboard.session is not None:
                        created = dashboard.session.created_utc[:19].replace("T", " ")
                        label = f"Saved session · {created} UTC" if dashboard.archived else (
                            f"Recording session · {created} UTC")
                    body = body.replace("__SESSION_LABEL__", json.dumps(label))
                    self.send_bytes(200, "text/html; charset=utf-8", body.encode())
                elif parsed.path == "/api/updates":
                    try:
                        after = int(query.get("after", [0])[0])
                        since = float(query.get("since", [0])[0])
                        if after < 0 or not np.isfinite(since):
                            raise ValueError
                    except ValueError:
                        self.send_bytes(400, "text/plain", b"Invalid history cursor")
                        return
                    with dashboard.lock:
                        frame_rows = [(seq, stamp, row)
                                      for seq, stamp, row in dashboard.frames
                                      if seq > after]
                        # A fresh browser needs enough rows to fill its initial
                        # 30-second view. Incremental polls stay deliberately
                        # small to keep phone updates lightweight.
                        frame_rows = (frame_rows[-800:] if after == 0
                                      else frame_rows[-100:])
                        record_since = max(
                            since,
                            frame_rows[0][1] if after == 0 and frame_rows else since,
                        )
                        records = [
                            dashboard.public_record(record)
                            for record in dashboard.records
                            if (record["end"] is None or
                                record["end"] >= record_since)
                        ]
                    # Encoding 40 seconds of FFT rows can be expensive; never
                    # hold the collector lock while doing it.
                    frames = [[seq, stamp, base64.b64encode(row).decode()]
                              for seq, stamp, row in frame_rows]
                    self.send_bytes(
                        200, "application/json",
                        json.dumps({"frames": frames, "records": records,
                                    "timeline": dashboard.timeline()}).encode())
                elif parsed.path == "/api/history":
                    try:
                        before = float(query.get("before", ["nan"])[0])
                        limit = int(query.get("limit", [900])[0])
                        if not np.isfinite(before) or not 1 <= limit <= 1600:
                            raise ValueError
                    except ValueError:
                        self.send_bytes(400, "text/plain", b"Invalid history window")
                        return
                    frame_rows, records = dashboard.history_before(before, limit)
                    frames = [[seq, stamp, base64.b64encode(row).decode()]
                              for seq, stamp, row in frame_rows]
                    timeline = dashboard.timeline()
                    more_before = bool(
                        frame_rows and frame_rows[0][1] > timeline["start"] + 1e-6)
                    self.send_bytes(
                        200, "application/json",
                        json.dumps({"frames": frames,
                                    "records": [dashboard.public_record(record)
                                                for record in records],
                                    "more_before": more_before,
                                    "timeline": timeline}).encode())
                elif parsed.path == "/api/live":
                    try:
                        after = int(query.get("after", [0])[0])
                        if after < 0:
                            raise ValueError
                    except ValueError:
                        self.send_bytes(400, "text/plain", b"Invalid audio cursor")
                        return
                    with dashboard.lock:
                        chunks = [[seq, base64.b64encode(pcm).decode()]
                                  for seq, pcm in dashboard.audio if seq > after]
                        chunks = chunks[-20:]
                    self.send_bytes(200, "application/json",
                                    json.dumps({"chunks": chunks,
                                                "latest": dashboard.audio_seq}).encode())
                elif parsed.path == "/api/live-stream":
                    # One long-lived response replaces dozens of phone HTTP
                    # polls per second. PCM chunks are 20 ms at the transport rate.
                    self.send_response(200)
                    self.send_header("Content-Type", "application/octet-stream")
                    self.send_header("Cache-Control", "no-store")
                    self.send_header("Connection", "close")
                    self.send_header(
                        "X-Audio-Chunk-Bytes", str(dashboard.audio_rate // 50 * 2))
                    self.end_headers()
                    with dashboard.audio_condition:
                        sequence = dashboard.audio_seq
                    pending = []
                    try:
                        while dashboard.running:
                            with dashboard.audio_condition:
                                dashboard.audio_condition.wait_for(
                                    lambda: (dashboard.audio_seq > sequence or
                                             not dashboard.running),
                                    timeout=0.5,
                                )
                                chunks = [(seq, pcm) for seq, pcm in dashboard.audio
                                          if seq > sequence]
                            if not chunks:
                                continue
                            for sequence, pcm in chunks:
                                pending.append(pcm)
                            while len(pending) >= 5:
                                self.wfile.write(b"".join(pending[:5]))
                                del pending[:5]
                                self.wfile.flush()
                    except (BrokenPipeError, ConnectionResetError, OSError):
                        pass
                    self.close_connection = True
                elif parsed.path == "/api/channel-stream":
                    try:
                        channel = int(query.get("channel", [0])[0])
                        timeline = float(query.get("start", ["nan"])[0])
                        if channel not in range(1, 23) or not np.isfinite(timeline):
                            raise ValueError
                    except ValueError:
                        self.send_bytes(400, "text/plain", b"Invalid channel timeline")
                        return
                    self.send_response(200)
                    self.send_header("Content-Type", "application/octet-stream")
                    self.send_header("Cache-Control", "no-store")
                    self.send_header("Connection", "close")
                    self.send_header(
                        "X-Audio-Chunk-Bytes", str(dashboard.audio_rate // 10 * 2))
                    self.end_headers()
                    wall_origin = time.monotonic()
                    segment = 0
                    archive_end = dashboard.timeline()["end"]
                    try:
                        while (dashboard.running and
                               (not dashboard.archived or
                                timeline + segment * 0.1 <= archive_end)):
                            self.wfile.write(
                                self.render_channel_pcm(channel, timeline + segment * 0.1))
                            self.wfile.flush()
                            segment += 1
                            delay = wall_origin + segment * 0.1 - time.monotonic()
                            if delay > 0:
                                time.sleep(delay)
                    except (BrokenPipeError, ConnectionResetError, OSError):
                        pass
                    self.close_connection = True
                elif parsed.path == "/api/recording":
                    try:
                        record_id = int(query.get("id", [-1])[0])
                        offset = float(query.get("offset", [0])[0])
                        if record_id < 0 or offset < 0 or not np.isfinite(offset):
                            raise ValueError
                    except ValueError:
                        self.send_bytes(400, "text/plain", b"Invalid recording request")
                        return
                    if dashboard.session is not None:
                        rec = dashboard.session.get_record(record_id)
                    else:
                        with dashboard.lock:
                            rec = next((r for r in dashboard.records
                                        if r["id"] == record_id), None)
                    if not rec or not rec.get("path") or not os.path.isfile(rec["path"]):
                        self.send_bytes(404, "text/plain", b"Recording unavailable")
                    elif rec.get("end") is None:
                        self.send_bytes(409, "text/plain", b"Recording still active")
                    else:
                        rendered = io.BytesIO()
                        with wave.open(rec["path"], "rb") as source:
                            start_frame = min(source.getnframes(),
                                              round(offset * source.getframerate()))
                            source.setpos(start_frame)
                            params = source.getparams()
                            pcm = source.readframes(source.getnframes() - start_frame)
                        with wave.open(rendered, "wb") as output:
                            output.setparams(params)
                            output.writeframes(pcm)
                        self.send_bytes(200, "audio/wav", rendered.getvalue())
                else:
                    self.send_bytes(404, "text/plain", b"Not found")

            def do_POST(self):
                parsed = urlparse(self.path)
                query = parse_qs(parsed.query)
                if not self.authorized(query):
                    self.send_bytes(403, "text/plain", b"Invalid dashboard token")
                elif parsed.path == "/api/squelch":
                    if dashboard.archived:
                        self.send_bytes(409, "text/plain", b"Saved session is read-only")
                        return
                    try:
                        threshold = float(query["value"][0])
                        if not np.isfinite(threshold) or not -120 <= threshold <= 0:
                            raise ValueError
                    except (KeyError, ValueError):
                        self.send_bytes(400, "text/plain", b"Invalid squelch threshold")
                        return
                    receiver.set_squelch(threshold)
                    self.send_bytes(204, "text/plain", b"")
                else:
                    self.send_bytes(404, "text/plain", b"Not found")

        self.server = ThreadingHTTPServer((host, port), Handler)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.collector = threading.Thread(target=self._collect, daemon=True)

    @staticmethod
    def public_record(record):
        return {key: value for key, value in record.items() if key != "path"}

    def timeline(self):
        if self.session is not None:
            start, end = self.session.timeline_bounds()
        else:
            with self.lock:
                if self.frames:
                    start, end = self.frames[0][1], self.frames[-1][1]
                else:
                    start = end = getattr(
                        self.receiver, "timeline_origin", time.monotonic())
        return {
            "start": start,
            "end": end,
            "live": not self.archived,
            "can_live_audio": not self.archived,
        }

    def history_before(self, before, limit):
        if self.session is not None:
            rows = self.session.frames_before(before, limit)
            if not rows:
                return [], []
            return rows, self.session.records_between(rows[0][1], before)
        with self.lock:
            rows = [frame for frame in self.frames if frame[1] < before][-limit:]
            if not rows:
                return [], []
            records = [dict(record) for record in self.records
                       if record["start"] <= before and
                       (record["end"] is None or record["end"] >= rows[0][1])]
        return rows, records

    def _prune_records(self):
        """Bound browser metadata to the same timeline retained by the waterfall."""
        with self.lock:
            if not self.frames:
                return
            cutoff = self.frames[-1][1] - WEB_HISTORY_SECONDS
            self.records[:] = [
                record for record in self.records
                if record["end"] is None or record["end"] >= cutoff
            ]

    def _collect_pending(self):
        changed = False
        try:
            while True:
                stamp, db = self.receiver.spectrum_frames.get_nowait()
                compact = np.clip(
                    (db + 110) / 110 * 255, 0, 255).astype(np.uint8).tobytes()
                with self.lock:
                    self.frame_seq += 1
                    sequence = self.frame_seq
                    self.frames.append((sequence, stamp, compact))
                if self.session is not None and self.session.writable:
                    self.session.add_frame(sequence, stamp, compact)
                changed = True
        except queue.Empty:
            pass
        try:
            while True:
                kind, channel, stamp, path = self.receiver.activity_events.get_nowait()
                rec = None
                with self.lock:
                    if kind == "start":
                        self.record_seq += 1
                        rec = {"id": self.record_seq, "channel": channel,
                               "frequency": FRS_CHANNELS_HZ[channel - 1],
                               "start": stamp, "end": None, "path": path}
                        self.records.append(rec)
                        self.active[channel] = rec
                    else:
                        rec = self.active.pop(channel, None)
                        if rec:
                            rec["end"] = stamp
                if rec and self.session is not None and self.session.writable:
                    if kind == "start":
                        self.session.start_record(rec)
                    else:
                        self.session.end_record(rec)
                changed = True
        except queue.Empty:
            pass
        try:
            while True:
                pcm = self.receiver.web_audio.get_nowait()
                with self.audio_condition:
                    self.audio_seq += 1
                    self.audio.append((self.audio_seq, pcm))
                    self.audio_condition.notify_all()
                changed = True
        except queue.Empty:
            pass
        return changed

    def _collect(self):
        while self.running:
            changed = self._collect_pending()
            now = time.monotonic()
            if now - self.last_prune >= 1.0:
                self._prune_records()
                self.last_prune = now
            if not changed:
                time.sleep(0.02)

    def start(self):
        self.collector.start()
        self.thread.start()

    def stop(self):
        with self.audio_condition:
            if not self.running:
                return
            self.running = False
            self.audio_condition.notify_all()
        if self.collector.ident is not None:
            self.collector.join(timeout=1.0)
        self._collect_pending()
        self.server.shutdown()
        self.server.server_close()
        if self.thread.ident is not None:
            self.thread.join(timeout=1.0)
        if self.session is not None:
            self.session.close()

    def url(self):
        host = self.server.server_address[0]
        if host in ("0.0.0.0", "::"):
            try:
                sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
                sock.connect(("8.8.8.8", 80))
                host = sock.getsockname()[0]
                sock.close()
            except OSError:
                host = "127.0.0.1"
        return f"http://{host}:{self.server.server_address[1]}/?token={self.token}"


def parse_args():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--device", default="", help="gr-osmosdr device args")
    parser.add_argument("--sample-rate", type=int, default=DEFAULT_SAMPLE_RATE)
    parser.add_argument("--center-freq", type=float, default=None, help="Hz")
    parser.add_argument("--gain", type=float, default=30.0, help="SDR RF gain in dB")
    parser.add_argument("--ppm", type=float, default=0.0, help="frequency correction")
    parser.add_argument(
        "--squelch", type=float, default=-55.0,
        help="per-channel power threshold in dB (adjust for your SDR)",
    )
    parser.add_argument(
        "--squelch-alpha", type=float, default=0.001,
        help="squelch power-estimator smoothing factor",
    )
    parser.add_argument(
        "--channel-gain", type=float, default=0.25,
        help="audio gain applied to each open channel",
    )
    parser.add_argument("--audio-device", default="", help="GNU Radio audio device")
    parser.add_argument("--wav", help="write composite audio to WAV instead of speakers")
    parser.add_argument("--no-audio", action="store_true", help="discard audio output")
    parser.add_argument(
        "--record-dir", default="recordings",
        help="per-channel conversation directory (empty disables saving)",
    )
    session_mode = parser.add_mutually_exclusive_group()
    session_mode.add_argument(
        "--record-session", metavar="DIRECTORY",
        help="save compact waterfall history and channel WAVs as a portable session",
    )
    session_mode.add_argument(
        "--open-session", metavar="DIRECTORY",
        help="open a previously recorded session in the web dashboard",
    )
    parser.add_argument(
        "--live-audio", action="store_true",
        help="start with mixed live audio enabled in the GUI",
    )
    parser.add_argument(
        "--test-input", action="store_true",
        help="use synthetic PlutoPlus-like IQ instead of SDR hardware",
    )
    parser.add_argument(
        "--test-iq-file", metavar="PATH",
        help="path to the generated looping complex-float test IQ file",
    )
    parser.add_argument(
        "--regenerate-test-iq", action="store_true",
        help="replace the cached looping test IQ file before starting",
    )
    parser.add_argument(
        "--web-real-iq", action="store_true",
        help=("with --web --test-input, run synthetic IQ through the full "
              "channelizer/demodulator instead of the lightweight dashboard fixture"),
    )
    parser.add_argument("--gui", action=argparse.BooleanOptionalAction, default=True)
    parser.add_argument("--web", action="store_true", help="serve the phone-friendly web dashboard")
    parser.add_argument("--web-host", default="0.0.0.0", help="dashboard bind address")
    parser.add_argument("--web-port", type=int, default=8765, help="dashboard TCP port")
    parser.add_argument("--run-seconds", type=float, help="stop automatically after N seconds")
    parser.add_argument(
        "--self-test", action="store_true",
        help="verify synthetic channels 1/8 open and channel 15 stays squelched",
    )
    parser.add_argument(
        "--benchmark-dsp", action="store_true",
        help=("run the complete synthetic-IQ DSP graph without a throttle and "
              "report its maximum realtime factor"),
    )
    return parser.parse_args()


def main():
    args = parse_args()
    if args.benchmark_dsp:
        args.test_input = True
        args.gui = False
        args.web = False
        args.no_audio = True
        args.record_dir = ""
        args.run_seconds = args.run_seconds or 10.0
    if args.web_real_iq and not (args.web and args.test_input):
        raise SystemExit("--web-real-iq requires --web --test-input")
    if args.open_session:
        args.web = True
        args.gui = False
        if args.self_test:
            raise SystemExit("--open-session cannot be combined with --self-test")
    if args.record_session:
        if args.self_test:
            raise SystemExit(
                "--record-session cannot be combined with --self-test; "
                "use --test-input instead")
        if any(argument == "--record-dir" or argument.startswith("--record-dir=")
               for argument in sys.argv[1:]):
            raise SystemExit(
                "--record-session owns its audio directory and cannot be "
                "combined with --record-dir")
        args.record_session = SessionArchive.validate_new_directory(
            args.record_session)
        args.record_dir = os.path.join(args.record_session, "audio")
        args.web = True
    if args.web:
        args.gui = False
    if args.self_test:
        args.test_input = True
        args.gui = False
        args.no_audio = True
        args.record_dir = ""
        args.run_seconds = args.run_seconds or 4.0

    app = None
    if args.gui:
        app = QtWidgets.QApplication(sys.argv)
    archive = None
    if args.open_session:
        archive = SessionArchive.open(args.open_session)
        receiver = SavedSessionReceiver(archive)
    else:
        receiver = (RealtimeWebTestReceiver(args)
                    if (args.web and args.test_input and not args.self_test and
                        not args.web_real_iq)
                    else FRSReceiver(args))
        if args.record_session:
            archive = SessionArchive.create(
                args.record_session, receiver.center_hz, receiver.sample_rate)
            archive.set_display_origin(receiver.timeline_origin)
    gui = ReceiverWindow(receiver, args.squelch) if args.gui else None
    web = (WebDashboardServer(
        receiver, args.web_host, args.web_port, session=archive,
        archived=bool(args.open_session)) if args.web else None)
    stopped = False

    def stop(_signum=None, _frame=None):
        nonlocal stopped
        if stopped:
            return
        stopped = True
        receiver.stop()
        receiver.wait()
        if web is not None:
            web.stop()
        elif archive is not None:
            archive.close()
        if app is not None:
            app.quit()

    signal.signal(signal.SIGINT, stop)
    signal.signal(signal.SIGTERM, stop)
    if args.open_session:
        print(f"Opening saved FRS session: {archive.directory}. Press Ctrl-C to stop.")
    else:
        print(
            f"Receiving 22 FRS channels around {receiver.center_hz / 1e6:.6f} MHz; "
            f"squelch {args.squelch:.1f} dB. Press Ctrl-C to stop."
        )
        if archive is not None:
            print(f"Recording session (compact waterfall + channel WAVs): {archive.directory}")
    receiver.start()
    if web is not None:
        web.start()
        print(f"Dashboard: {web.url()}")
    if args.gui:
        if args.run_seconds:
            QtCore.QTimer.singleShot(round(args.run_seconds * 1000), stop)
        app.exec_()
        stop()
    elif args.run_seconds:
        measurement_started = time.monotonic()
        deadline = time.monotonic() + args.run_seconds
        levels = [0.0] * 22
        while time.monotonic() < deadline:
            time.sleep(0.1)
            levels = [max(old, new) for old, new in
                      zip(levels, receiver.channel_levels())]
        stop()
        measurement_elapsed = time.monotonic() - measurement_started
        print("Channel audio RMS:", " ".join(
            f"{number}:{level:.5f}" for number, level in enumerate(levels, 1)
            if level > 1e-5 or number in (1, 8, 15)
        ))
        if args.self_test:
            processed_seconds = receiver.processed_seconds()
            print(f"Synthetic RF processed: {processed_seconds:.2f}s of IQ")
            passed = levels[0] > 1e-3 and levels[7] > 1e-4 and levels[14] < 1e-5
            print("SELF-TEST:", "PASS" if passed else "FAIL")
            if not passed:
                return 1
        if args.benchmark_dsp:
            processed_seconds = receiver.processed_seconds()
            factor = processed_seconds / measurement_elapsed
            print(
                f"DSP BENCHMARK: {processed_seconds:.2f}s IQ in "
                f"{measurement_elapsed:.2f}s wall = {factor:.2f}x realtime"
            )
    else:
        receiver.wait()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
