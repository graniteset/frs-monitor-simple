"""Small deterministic fixture shared by the Python and Go HTTP servers."""
from __future__ import annotations

import base64
import json
import os
import struct
import wave


TOKEN = "WEBPORTBENCHTOKEN"
CENTER_HZ = 465_125_000
SAMPLE_RATE = 8_000_000
AUDIO_RATE = 12_500
START = 1_700_000_000.0
ROW_BYTES = 4096


def _pcm(seed: int, samples: int = 250) -> bytes:
    # Integer-only waveform; avoids platform-dependent floating-point fixtures.
    return b"".join(struct.pack("<h", ((i * 97 + seed * 331) % 60001) - 30000)
                    for i in range(samples))


def build_fixture(directory: str) -> dict:
    """Write an equivalent fixture manifest and WAV asset; return its manifest."""
    os.makedirs(directory, exist_ok=True)
    wav_path = os.path.join(directory, "channel-3.wav")
    samples = _pcm(11, 1_250)
    with wave.open(wav_path, "wb") as wav:
        wav.setnchannels(1)
        wav.setsampwidth(2)
        wav.setframerate(AUDIO_RATE)
        wav.writeframes(samples)

    frames = []
    for seq in range(1, 9):
        # Each row has recognizable exact bytes and a full 4096 bins.
        row = bytes(((i + seq * 17) % 256 for i in range(ROW_BYTES)))
        frames.append({"seq": seq, "time": START + (seq - 1) * 0.05,
                       "row": base64.b64encode(row).decode("ascii")})
    manifest = {
        "center_hz": CENTER_HZ,
        "sample_rate": SAMPLE_RATE,
        "audio_rate": AUDIO_RATE,
        "archived": False,
        "start": START,
        "end": START + 0.35,
        "frames": frames,
        "records": [
            {"id": 1, "channel": 3, "frequency": 462_612_500,
             "start": START, "end": START + 0.02, "path": wav_path},
            {"id": 2, "channel": 3, "frequency": 462_612_500,
             "start": START + 0.05, "end": START + 0.07, "path": wav_path},
            {"id": 3, "channel": 8, "frequency": 467_587_500,
             "start": START + 0.1, "end": START + 0.2, "path": wav_path},
        ],
        "audio": [
            {"seq": seq, "pcm": base64.b64encode(_pcm(seq)).decode("ascii")}
            for seq in range(1, 7)
        ],
        "squelch": -55.0,
    }
    return manifest


def write_fixture(directory: str) -> str:
    manifest = build_fixture(directory)
    path = os.path.join(directory, "fixture.json")
    with open(path, "w", encoding="utf-8") as output:
        json.dump(manifest, output, separators=(",", ":"))
    return path
