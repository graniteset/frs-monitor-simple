#!/usr/bin/env python3
"""Generate band-2 DDC vectors against GNU Radio's freq_xlating_fir_filter."""

import json
from pathlib import Path

import numpy as np
from gnuradio import blocks, filter, gr
from gnuradio.filter import firdes, window


RATE = 6_400_000
DECIMATION = 16
CENTER_OFFSET = 467_637_500 - 465_125_000
INPUT_SAMPLES = 4096


def q15(values):
    return np.clip(np.rint(np.asarray(values) * 32768), -32768, 32767).astype(np.int16)


def write_packed(path, i_values, q_values):
    with path.open("w") as stream:
        for i_value, q_value in zip(i_values, q_values):
            stream.write(f"{int(i_value) & 0xffff:04x}{int(q_value) & 0xffff:04x}\n")


def main():
    out_dir = Path(__file__).resolve().parent / "vectors"
    out_dir.mkdir(parents=True, exist_ok=True)
    n = np.arange(INPUT_SAMPLES, dtype=np.float64)
    components = (
        (CENTER_OFFSET - 25_000, 0.10, 0.31),
        (CENTER_OFFSET + 25_000, 0.20, -0.73),
        (462_637_500 - 465_125_000, 0.40, 1.07),
    )
    signal = sum(amplitude * np.exp(1j * (2 * np.pi * frequency * n / RATE + phase))
                 for frequency, amplitude, phase in components)
    i_input, q_input = q15(signal.real), q15(signal.imag)
    quantized = (i_input.astype(np.float64) + 1j * q_input.astype(np.float64)) / 32768.0
    taps = firdes.low_pass(1.0, RATE, 100_000, 75_000, window.WIN_HAMMING)
    top = gr.top_block("Band 2 DDC reference")
    source = blocks.vector_source_c(quantized.astype(np.complex64).tolist(), False)
    ddc = filter.freq_xlating_fir_filter_ccc(DECIMATION, taps, CENTER_OFFSET, RATE)
    sink = blocks.vector_sink_c()
    top.connect(source, ddc, sink)
    top.run()
    reference = np.asarray(sink.data(), dtype=np.complex64)
    write_packed(out_dir / "ddc_band2_input.memh", i_input, q_input)
    write_packed(out_dir / "ddc_band2_expected.memh", q15(reference.real), q15(reference.imag))
    metadata = {
        "input_samples": INPUT_SAMPLES,
        "expected_outputs": int(len(reference)),
        "input_rate_hz": RATE,
        "decimation": DECIMATION,
        "mix_frequency_hz": CENTER_OFFSET,
        "components": components,
        "rtl_phase_step": 311,
        "rtl_initial_phase": 490,
        "comparison": "Q1.15 I/Q, tolerance 6 LSB",
    }
    (out_dir / "ddc_band2_metadata.json").write_text(json.dumps(metadata, indent=2) + "\n")
    print(f"Generated {INPUT_SAMPLES} samples and {len(reference)} band-2 outputs")


if __name__ == "__main__":
    main()
