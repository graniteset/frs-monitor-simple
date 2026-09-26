#!/usr/bin/env python3
"""Generate fixed-point IQ and GNU Radio golden vectors for the first DDC."""

import argparse
import json
from pathlib import Path

import numpy as np
from gnuradio import blocks, filter, gr
from gnuradio.filter import firdes, window


INPUT_RATE = 6_400_000
DECIMATION = 16
CENTER_OFFSET = 462_637_500 - 465_125_000
INPUT_SAMPLES = 4096


def q15(value):
    values = np.rint(np.asarray(value) * 32768.0)
    return np.clip(values, -32768, 32767).astype(np.int16)


def write_packed(path, i_samples, q_samples):
    with path.open("w") as output:
        for i_value, q_value in zip(i_samples, q_samples):
            output.write(f"{(int(i_value) & 0xffff):04x}{(int(q_value) & 0xffff):04x}\n")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--output-dir", type=Path,
        default=Path(__file__).resolve().parent / "vectors",
    )
    args = parser.parse_args()
    args.output_dir.mkdir(parents=True, exist_ok=True)

    n = np.arange(INPUT_SAMPLES, dtype=np.float64)
    # Tone offsets within the band, plus a strong carrier in the other cluster.
    components = (
        (CENTER_OFFSET - 25_000, 0.20, 0.31),
        (CENTER_OFFSET + 25_000, 0.08, -0.73),
        (467_637_500 - 465_125_000, 0.40, 1.07),
    )
    signal = np.zeros(INPUT_SAMPLES, dtype=np.complex128)
    for frequency, amplitude, phase in components:
        signal += amplitude * np.exp(
            1j * (2 * np.pi * frequency * n / INPUT_RATE + phase))
    i_input = q15(signal.real)
    q_input = q15(signal.imag)
    quantized_input = (i_input.astype(np.float64) +
                       1j * q_input.astype(np.float64)) / 32768.0

    taps = firdes.low_pass(
        1.0, INPUT_RATE, 100_000, 75_000, window.WIN_HAMMING)
    top = gr.top_block("DDC golden-vector generator")
    source = blocks.vector_source_c(quantized_input.astype(np.complex64).tolist(), False)
    ddc = filter.freq_xlating_fir_filter_ccc(
        DECIMATION, taps, CENTER_OFFSET, INPUT_RATE)
    sink = blocks.vector_sink_c()
    top.connect(source, ddc, sink)
    top.run()
    reference = np.asarray(sink.data(), dtype=np.complex64)
    i_reference = q15(reference.real)
    q_reference = q15(reference.imag)

    write_packed(args.output_dir / "ddc_input.memh", i_input, q_input)
    write_packed(args.output_dir / "ddc_expected.memh", i_reference, q_reference)
    metadata = {
        "input_samples": INPUT_SAMPLES,
        "expected_outputs": int(len(reference)),
        "input_rate_hz": INPUT_RATE,
        "decimation": DECIMATION,
        "mix_frequency_hz": CENTER_OFFSET,
        "components": components,
        "packing": "16-bit signed I in upper half, Q in lower half",
        "comparison": "per-component absolute tolerance 6 Q1.15 LSB after startup alignment",
    }
    (args.output_dir / "ddc_metadata.json").write_text(
        json.dumps(metadata, indent=2) + "\n")
    print(f"Generated {INPUT_SAMPLES} IQ input samples and {len(reference)} GNU Radio outputs")


if __name__ == "__main__":
    main()
