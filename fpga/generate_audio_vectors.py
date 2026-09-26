#!/usr/bin/env python3
"""Generate Q1.15 de-emphasized audio and GNU Radio FIR/decimator goldens."""

import argparse
import json
from pathlib import Path

import numpy as np
from gnuradio import blocks, filter, gr
from gnuradio.filter import firdes, window


INPUT_RATE = 25_000
DECIMATION = 2
COUNT = 2048


def q15(values):
    return np.clip(np.rint(np.asarray(values) * 32768), -32768, 32767).astype(np.int16)


def write_q15(path, values):
    with path.open("w") as output:
        for value in values:
            output.write(f"{(int(value) & 0xffff):04x}0000\n")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--output-dir", type=Path,
                        default=Path(__file__).resolve().parent / "vectors")
    args = parser.parse_args()
    args.output_dir.mkdir(parents=True, exist_ok=True)
    deemphasized = np.fromiter(
        (int(line[:4], 16) - (0x10000 if int(line[:4], 16) & 0x8000 else 0)
         for line in (args.output_dir / "deemph_expected.memh").read_text().splitlines()),
        dtype=np.int16,
    )
    source_values = deemphasized.astype(np.float32) / 32768
    taps = firdes.low_pass(1.0, INPUT_RATE, 2_700, 500, window.WIN_HAMMING)
    top = gr.top_block("Audio FIR golden-vector generator")
    source = blocks.vector_source_f(source_values.tolist(), False)
    fir = filter.fir_filter_fff(DECIMATION, taps)
    sink = blocks.vector_sink_f()
    top.connect(source, fir, sink)
    top.run()
    expected_unscaled = q15(np.asarray(sink.data(), dtype=np.float64))
    expected = q15(expected_unscaled.astype(np.float64) / 32768.0 * 0.25)
    write_q15(args.output_dir / "audio_input.memh", deemphasized)
    write_q15(args.output_dir / "audio_fir_expected.memh", expected_unscaled)
    write_q15(args.output_dir / "audio_expected.memh", expected)
    metadata = {
        "input_samples": len(deemphasized),
        "expected_outputs": len(expected),
        "input_rate_hz": INPUT_RATE,
        "output_rate_hz": INPUT_RATE // DECIMATION,
        "decimation": DECIMATION,
        "taps": len(taps),
        "cutoff_hz": 2_700,
        "transition_hz": 500,
        "channel_gain": 0.25,
        "comparison": "Q1.15 output, tolerance 6 LSB",
    }
    (args.output_dir / "audio_metadata.json").write_text(json.dumps(metadata, indent=2) + "\n")
    print(f"Generated {len(deemphasized)} audio inputs and {len(expected)} GNU Radio outputs")


if __name__ == "__main__":
    main()
