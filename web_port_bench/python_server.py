"""Run the production Python HTTP handler with deterministic seeded state."""
from __future__ import annotations

import argparse
import base64
import json
import queue
import time
import threading

from frs_all_channels import WebDashboardServer


class FixtureReceiver:
    def __init__(self, fixture):
        self.center_hz = fixture["center_hz"]
        self.sample_rate = fixture["sample_rate"]
        self.audio_rate = fixture["audio_rate"]
        self.timeline_origin = fixture["start"]
        self.spectrum_frames = queue.Queue()
        self.activity_events = queue.Queue()
        self.web_audio = queue.Queue()
        self.squelch = fixture.get("squelch")

    def set_squelch(self, value):
        self.squelch = value


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--fixture", required=True)
    parser.add_argument("--listen", default="127.0.0.1:0")
    parser.add_argument("--token", default="WEBPORTBENCHTOKEN")
    parser.add_argument("--fixture-replay", action="store_true")
    args = parser.parse_args()
    host, port = args.listen.rsplit(":", 1)
    with open(args.fixture, encoding="utf-8") as source:
        fixture = json.load(source)
    receiver = FixtureReceiver(fixture)
    server = WebDashboardServer(receiver, host, int(port),
                                archived=bool(fixture.get("archived", False)))
    server.token = args.token
    server.frames.extend((row["seq"], row["time"],
                          base64.b64decode(row["row"]))
                         for row in fixture["frames"])
    server.frame_seq = max((row["seq"] for row in fixture["frames"]), default=0)
    server.records.extend(dict(record) for record in fixture["records"])
    server.record_seq = max((record["id"] for record in fixture["records"]), default=0)
    server.audio.extend((chunk["seq"], base64.b64decode(chunk["pcm"]))
                        for chunk in fixture["audio"])
    server.audio_seq = max((chunk["seq"] for chunk in fixture["audio"]), default=0)
    server.start()
    if args.fixture_replay:
        chunks = [base64.b64decode(row["pcm"]) for row in fixture["audio"]]

        def replay():
            sequence = server.audio_seq
            index = 0
            while server.running:
                time.sleep(0.02)
                sequence += 1
                with server.audio_condition:
                    server.audio_seq = sequence
                    server.audio.append((sequence, chunks[index]))
                    server.audio_condition.notify_all()
                index = (index + 1) % len(chunks)

        threading.Thread(target=replay, daemon=True).start()
    print(f"LISTENING {server.url()}", flush=True)
    try:
        while server.running:
            time.sleep(1)
    except KeyboardInterrupt:
        pass
    finally:
        server.stop()


if __name__ == "__main__":
    main()
