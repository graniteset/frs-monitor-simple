#!/usr/bin/env python3
"""Generate a quantized FM stream and GNU Radio discriminator golden vector."""

import json
import argparse
from pathlib import Path

import numpy as np
from gnuradio import analog, blocks, gr


RATE = 25_000
COUNT = 2048
GAIN = RATE / (2 * np.pi * 2_500)


def q15(values):
    return np.clip(np.rint(np.asarray(values) * 32768), -32768, 32767).astype(np.int16)


def write_packed(path, i_values, q_values):
    with path.open("w") as output:
        for i_value, q_value in zip(i_values, q_values):
            output.write(f"{(int(i_value) & 0xffff):04x}{(int(q_value) & 0xffff):04x}\n")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--output-dir", type=Path,
                        default=Path(__file__).resolve().parent / "vectors")
    args = parser.parse_args()
    args.output_dir.mkdir(parents=True, exist_ok=True)

    n = np.arange(COUNT)
    deviation = (2_100 * np.sin(2 * np.pi * 625 * n / RATE) +
                 200 * np.sin(2 * np.pi * 1_600 * n / RATE))
    phase_step = 2 * np.pi * deviation / RATE
    phase = np.concatenate(([0.0], np.cumsum(phase_step[:-1])))
    i_input = q15(np.cos(phase))
    q_input = q15(np.sin(phase))
    quantized = (i_input.astype(np.float32) + 1j * q_input.astype(np.float32)) / 32768

    top = gr.top_block("FM discriminator golden-vector generator")
    source = blocks.vector_source_c(quantized.astype(np.complex64).tolist(), False)
    discriminator = analog.quadrature_demod_cf(float(GAIN))
    sink = blocks.vector_sink_f()
    top.connect(source, discriminator, sink)
    top.run()
    expected = q15(np.asarray(sink.data(), dtype=np.float64))
    write_packed(args.output_dir / "fm_input.memh", i_input, q_input)
    write_packed(args.output_dir / "fm_expected.memh", expected, np.zeros_like(expected))

    deemphasis_top = gr.top_block("FM de-emphasis golden-vector generator")
    demod_source = blocks.vector_source_f(
        (expected.astype(np.float32) / 32768.0).tolist(), False)
    deemphasis = analog.fm_deemph(float(RATE), 75e-6)
    deemphasis_sink = blocks.vector_sink_f()
    deemphasis_top.connect(demod_source, deemphasis, deemphasis_sink)
    deemphasis_top.run()
    deemphasized = q15(np.asarray(deemphasis_sink.data(), dtype=np.float64))
    write_packed(args.output_dir / "deemph_expected.memh", deemphasized,
                 np.zeros_like(deemphasized))
    metadata = {
        "input_samples": COUNT,
        "sample_rate_hz": RATE,
        "max_deviation_hz": 2_500,
        "gain": float(GAIN),
        "modulation_tones_hz": [625, 1_600],
        "comparison": "Q1.15 output from quantized complex input; tolerance 8 LSB",
    }
    (args.output_dir / "fm_metadata.json").write_text(json.dumps(metadata, indent=2) + "\n")
    print(f"Generated {COUNT} complex samples and {len(expected)} GNU Radio FM outputs")


if __name__ == "__main__":
    main()
