#!/usr/bin/env python3
"""Generate full-chain 12-bit RF burst input and GNU Radio audio references."""

import argparse
import json
from pathlib import Path

import numpy as np
from gnuradio import analog, blocks, filter, gr
from gnuradio.filter import firdes, window


RATE = 6_400_000
SUBBAND_RATE = 400_000
CHANNEL_RATE = 25_000
LO_HZ = 465_125_000
BANDS = (462_637_500, 467_637_500)
FRS_HZ = (
    462_562_500, 462_587_500, 462_612_500, 462_637_500,
    462_662_500, 462_687_500, 462_712_500,
    467_562_500, 467_587_500, 467_612_500, 467_637_500,
    467_662_500, 467_687_500, 467_712_500,
    462_550_000, 462_575_000, 462_600_000, 462_625_000,
    462_650_000, 462_675_000, 462_700_000, 462_725_000,
)
SAMPLES = 98_304  # 15.36 ms; 384 subband frames, 192 audio outputs/channel
FRAMES_AUDIO = SAMPLES // (16 * 16 * 2)


def quantize12(values):
    return np.clip(np.rint(np.asarray(values) * 2048.0), -2048, 2047).astype(np.int16)


def write_hex(path, values, digits):
    mask = (1 << (digits * 4)) - 1
    path.write_text("".join(f"{int(value) & mask:0{digits}x}\n" for value in values))


def fm_carrier(n, frequency_hz, amplitude, start, stop, tones):
    active = (n >= start) & (n < stop)
    t = n / RATE
    message = sum(weight * np.sin(2 * np.pi * tone * t + phase)
                  for tone, weight, phase in tones)
    deviation = 2_300.0 * message
    step = 2 * np.pi * (frequency_hz + deviation) / RATE
    phase = np.cumsum(step, dtype=np.float64)
    return amplitude * active * np.exp(1j * phase)


def generate_iq():
    n = np.arange(SAMPLES, dtype=np.float64)
    # First burst: FRS 4 at low level and its +25 kHz adjacent FRS 5 at 20 dB
    # greater RF voltage. Second burst: FRS 11 in the upper 462 MHz cluster.
    signal = fm_carrier(n, FRS_HZ[3] - LO_HZ, 0.055, 4_096, 45_056,
                        ((700, 0.58, 0.2), (1_650, 0.20, -0.4)))
    signal += fm_carrier(n, FRS_HZ[4] - LO_HZ, 0.55, 4_096, 45_056,
                         ((900, 0.58, -0.5), (2_000, 0.20, 0.7)))
    signal += fm_carrier(n, FRS_HZ[10] - LO_HZ, 0.17, 52_224, 94_208,
                         ((1_200, 0.72, 0.3), (450, 0.12, -0.8)))
    rng = np.random.default_rng(0x7020)
    noise = rng.normal(0.0, 0.00075, SAMPLES) + 1j * rng.normal(0.0, 0.00075, SAMPLES)
    signal += noise
    iq_i = quantize12(signal.real)
    iq_q = quantize12(signal.imag)
    iq = (iq_i.astype(np.float32) + 1j * iq_q.astype(np.float32)) / 2048.0
    packed = ((iq_i.astype(np.int32) & 0x0FFF) << 12) | (iq_q.astype(np.int32) & 0x0FFF)
    return iq.astype(np.complex64), packed, iq_i, iq_q


def make_reference(iq, output_dir):
    top = gr.top_block("Full FRS receiver burst reference")
    source = blocks.vector_source_c(iq.tolist(), False)
    channel_taps = firdes.low_pass(1.0, SUBBAND_RATE, 6_000, 4_000, window.WIN_HAMMING)
    subband_taps = firdes.low_pass(1.0, RATE, 100_000, 75_000, window.WIN_HAMMING)
    routes = {}
    for band_center in BANDS:
        translator = filter.freq_xlating_fir_filter_ccc(
            RATE // SUBBAND_RATE, subband_taps, band_center - LO_HZ, RATE)
        splitter = blocks.stream_to_streams(gr.sizeof_gr_complex, 32)
        channelizer = filter.pfb_channelizer_ccf(32, channel_taps, 2.0)
        channelizer.set_tag_propagation_policy(gr.TPP_DONT)
        members = [(idx, freq) for idx, freq in enumerate(FRS_HZ)
                   if abs(freq - band_center) <= 100_000]
        bins = [round((freq - band_center) / 12_500) % 32 for _, freq in members]
        channelizer.set_channel_map(bins)
        top.connect(source, translator, splitter)
        for input_port in range(32):
            top.connect((splitter, input_port), (channelizer, input_port))
        for output_port, (idx, _freq) in enumerate(members):
            routes[idx] = (channelizer, output_port)

    sinks = []
    for index in range(len(FRS_HZ)):
        pfb, pfb_port = routes[index]
        # Keep the scripted noise floor muted but open on each transmission.
        squelch = analog.simple_squelch_cc(-45.0, 33.0 / 32768.0)
        demod = analog.nbfm_rx(audio_rate=12_500, quad_rate=25_000,
                               tau=75e-6, max_dev=2_500)
        gain = blocks.multiply_const_ff(0.25)
        sink = blocks.vector_sink_f()
        top.connect((pfb, pfb_port), squelch, demod, gain, sink)
        sinks.append(sink)
    top.run()

    expected = []
    counts = []
    for sink in sinks:
        samples = np.asarray(sink.data(), dtype=np.float64)
        q15 = np.clip(np.rint(samples * 32768.0), -32768, 32767).astype(np.int16)
        counts.append(int(len(q15)))
        expected.extend(q15)
    if len(set(counts)) != 1:
        raise RuntimeError(f"unequal channel output counts: {counts}")
    write_hex(output_dir / "rx_burst_expected.memh", expected, 4)
    return counts[0]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--output-dir", type=Path,
                        default=Path(__file__).resolve().parent / "vectors")
    args = parser.parse_args()
    args.output_dir.mkdir(parents=True, exist_ok=True)
    iq, packed, iq_i, iq_q = generate_iq()
    write_hex(args.output_dir / "rx_burst_input.memh", packed, 6)
    outputs = make_reference(iq, args.output_dir)
    metadata = {
        "raw_samples": SAMPLES,
        "raw_rate_hz": RATE,
        "adc_format": "signed 12-bit I/Q; normalized by 2048 before GNU Radio reference",
        "output_samples_per_channel": outputs,
        "audio_rate_hz": CHANNEL_RATE // 2,
        "transmissions": [
            {"channel": 4, "start_sample": 4096, "stop_sample": 45056, "amplitude": 0.055},
            {"channel": 5, "start_sample": 4096, "stop_sample": 45056, "amplitude": 0.55,
             "adjacent_to": 4, "stronger_by_db": 20.0},
            {"channel": 11, "start_sample": 52224, "stop_sample": 94208, "amplitude": 0.17},
        ],
        "noise_std_per_component": 0.00075,
        "reference": "GNU Radio two-band DDC/PFB/simple_squelch(-45 dB)/nbfm_rx/gain graph",
        "reference_layout": "22 channel-major blocks, each output_samples_per_channel signed Q1.15 values",
        "packing": "input line: 12-bit I in bits 23:12, 12-bit Q in bits 11:0",
        "max_abs_adc_code": int(max(np.abs(iq_i).max(), np.abs(iq_q).max())),
    }
    (args.output_dir / "rx_burst_metadata.json").write_text(json.dumps(metadata, indent=2) + "\n")
    print(f"Wrote {SAMPLES} raw samples and {outputs} GNU Radio audio outputs/channel")


if __name__ == "__main__":
    main()
