#!/usr/bin/env python3
"""Make a strong-adjacent-channel test and GNU Radio PFB golden vectors."""

import argparse
import json
from pathlib import Path

import numpy as np
from gnuradio import blocks, filter, gr
from gnuradio.filter import firdes, window


RATE = 400_000
INPUT_COUNT = 4096
BIN_A = 6
BIN_B = 7


def q15(values):
    return np.clip(np.rint(np.asarray(values) * 32768), -32768, 32767).astype(np.int16)


def packed_iq(i_values, q_values):
    return [((int(i) & 0xffff) << 16) | (int(q) & 0xffff)
            for i, q in zip(i_values, q_values)]


def write_memh(path, values, width=32):
    digits = (width + 3) // 4
    mask = (1 << width) - 1
    path.write_text("".join(f"{int(value) & mask:0{digits}x}\n" for value in values))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--output-dir", type=Path,
                        default=Path(__file__).resolve().parent / "vectors")
    args = parser.parse_args()
    args.output_dir.mkdir(parents=True, exist_ok=True)

    n = np.arange(INPUT_COUNT)
    # A 0.8 adjacent-bin carrier is 18 dB stronger in voltage than the 0.1
    # desired carrier. The two bins are separated by exactly one 12.5 kHz bin.
    signal = (0.10 * np.exp(1j * (2 * np.pi * BIN_A * n / 32 + 0.23)) +
              0.80 * np.exp(1j * (2 * np.pi * BIN_B * n / 32 - 0.67)))
    input_i, input_q = q15(signal.real), q15(signal.imag)
    quantized = (input_i.astype(np.float32) + 1j * input_q.astype(np.float32)) / 32768

    taps = firdes.low_pass(1.0, RATE, 6_000, 4_000, window.WIN_HAMMING)
    top = gr.top_block("Sparse channelizer golden-vector generator")
    source = blocks.vector_source_c(quantized.astype(np.complex64).tolist(), False)
    splitter = blocks.stream_to_streams(gr.sizeof_gr_complex, 32)
    channelizer = filter.pfb_channelizer_ccf(32, taps, 2.0)
    channelizer.set_channel_map([BIN_A, BIN_B])
    channelizer.set_tag_propagation_policy(gr.TPP_DONT)
    sinks = [blocks.vector_sink_c(), blocks.vector_sink_c()]
    top.connect(source, splitter)
    for input_port in range(32):
        top.connect((splitter, input_port), (channelizer, input_port))
    for output_port, sink in enumerate(sinks):
        top.connect((channelizer, output_port), sink)
    top.run()

    # GNU Radio's PFB retains a constant bin-dependent phase; the RTL matches
    # this convention through its polyphase/frame phase progression.
    golden = []
    for channel_bin, sink in zip((BIN_A, BIN_B), sinks):
        samples = np.asarray(sink.data(), dtype=np.complex128)
        out_i, out_q = q15(samples.real), q15(samples.imag)
        golden.append(packed_iq(out_i, out_q))

    write_memh(args.output_dir / "pfb_input.memh", packed_iq(input_i, input_q))
    # The testbench compares two expected channel outputs for each PFB frame.
    expected = [word for a, b in zip(*golden) for word in (a, b)]
    write_memh(args.output_dir / "pfb_expected.memh", expected)
    metadata = {
        "input_samples": INPUT_COUNT,
        "input_rate_hz": RATE,
        "expected_frames": len(golden[0]),
        "expected_words": len(expected),
        "bins": [BIN_A, BIN_B],
        "tones": [{"bin": BIN_A, "amplitude": 0.1},
                  {"bin": BIN_B, "amplitude": 0.8}],
        "adjacent_power_ratio_db": 20 * np.log10(0.8 / 0.1),
        "phase_alignment": "native GNU PFB phase convention",
        "comparison": "Q1.15 I/Q after frame alignment; first eleven GNU reference frames are FIR startup",
    }
    (args.output_dir / "pfb_metadata.json").write_text(json.dumps(metadata, indent=2) + "\n")
    print(f"Generated {INPUT_COUNT} IQ samples; GNU Radio returned {len(expected)} channel outputs")


if __name__ == "__main__":
    main()
