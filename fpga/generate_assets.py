#!/usr/bin/env python3
"""Export GNU Radio reference taps and fixed-point lookup assets.

Requires GNU Radio Python bindings. The checked-in default assets correspond to
the 6.4 MS/s receiver configuration in frs_all_channels.py.
"""

import argparse
import json
import math
from pathlib import Path

from gnuradio.filter import firdes, window


IQ_RATE = 6_400_000
SUBBAND_RATE = 400_000
CHANNEL_RATE = 25_000
AUDIO_RATE = 12_500
FRS_CHANNELS_HZ = (
    462_562_500, 462_587_500, 462_612_500, 462_637_500, 462_662_500,
    462_687_500, 462_712_500, 467_562_500, 467_587_500, 467_612_500,
    467_637_500, 467_662_500, 467_687_500, 467_712_500, 462_550_000,
    462_575_000, 462_600_000, 462_625_000, 462_650_000, 462_675_000,
    462_700_000, 462_725_000,
)
BAND_CENTERS_HZ = (462_637_500, 467_637_500)


def quantize_signed(value, fractional_bits, width):
    """Round to nearest integer and clamp to a signed two's-complement word."""
    scaled = round(float(value) * (1 << fractional_bits))
    return max(-(1 << (width - 1)), min((1 << (width - 1)) - 1, scaled))


def write_memh(path, values, width):
    digits = (width + 3) // 4
    mask = (1 << width) - 1
    path.write_text("".join(f"{value & mask:0{digits}x}\n" for value in values))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--output-dir", type=Path,
        default=Path(__file__).resolve().parent / "coeffs",
    )
    args = parser.parse_args()
    args.output_dir.mkdir(parents=True, exist_ok=True)

    specs = {
        "subband_q17": firdes.low_pass(
            1.0, IQ_RATE, 100_000, 75_000, window.WIN_HAMMING),
        "channel_q17": firdes.low_pass(
            1.0, SUBBAND_RATE, 6_000, 4_000, window.WIN_HAMMING),
        "audio_q17": firdes.low_pass(
            1.0, CHANNEL_RATE, 2_700, 500, window.WIN_HAMMING),
    }
    metadata = {
        "sample_rates_hz": {
            "input": IQ_RATE,
            "subband": SUBBAND_RATE,
            "channel": CHANNEL_RATE,
            "audio": AUDIO_RATE,
        },
        "coefficient_format": "signed 18-bit Q1.17, round-to-nearest/clamp",
        "files": {},
    }
    for name, taps in specs.items():
        quantized = [quantize_signed(tap, 17, 18) for tap in taps]
        filename = f"{name}.memh"
        write_memh(args.output_dir / filename, quantized, 18)
        metadata["files"][filename] = {
            "tap_count": len(quantized),
            "float_sum": sum(taps),
            "fixed_sum": sum(quantized) / (1 << 17),
        }

    deemphasis_corner = 1.0 / 75e-6
    deemphasis_analog_corner = 2.0 * CHANNEL_RATE * math.tan(
        deemphasis_corner / (2.0 * CHANNEL_RATE))
    deemphasis_b0 = deemphasis_analog_corner / (
        deemphasis_analog_corner + 2.0 * CHANNEL_RATE)
    deemphasis_feedback = (2.0 * CHANNEL_RATE - deemphasis_analog_corner) / (
        2.0 * CHANNEL_RATE + deemphasis_analog_corner)
    deemphasis_q17 = [quantize_signed(deemphasis_b0, 17, 18),
                       quantize_signed(deemphasis_feedback, 17, 18)]
    write_memh(args.output_dir / "deemphasis_q17.memh", deemphasis_q17, 18)
    metadata["deemphasis"] = {
        "sample_rate_hz": CHANNEL_RATE,
        "tau_seconds": 75e-6,
        "format": "signed 18-bit Q1.17 [feedforward b0, feedback -a1]",
        "b0": deemphasis_b0,
        "feedback": deemphasis_feedback,
        "fixed": deemphasis_q17,
    }

    channel_prototype = specs["channel_q17"]
    channel_coefficients = []
    for channel_bin in range(32):
        for tap_index, coefficient in enumerate(channel_prototype):
            angle = 2.0 * math.pi * channel_bin * tap_index / 32
            real = quantize_signed(coefficient * math.cos(angle), 17, 18)
            imag = quantize_signed(coefficient * math.sin(angle), 17, 18)
            channel_coefficients.append(((real & 0x3ffff) << 18) |
                                        (imag & 0x3ffff))
    write_memh(args.output_dir / "channel_modulated_q17.memh",
               channel_coefficients, 36)

    for band_number, center in enumerate(BAND_CENTERS_HZ, start=1):
        members = [
            (index + 1, frequency)
            for index, frequency in enumerate(FRS_CHANNELS_HZ)
            if abs(frequency - center) <= 100_000
        ]
        packed_map = []
        for channel_number, frequency in members:
            channel_bin = round((frequency - center) / 12_500) % 32
            packed_map.append((channel_number << 5) | channel_bin)
        write_memh(args.output_dir / f"channel_map_band{band_number}.memh",
                   packed_map, 10)

    # 9-bit phase accumulator, represented by a 128-entry quarter-wave ROM.
    # The exact table span is [0, 127*pi/256]; quadrant boundaries are handled
    # explicitly in the RTL sine function.
    nco = [quantize_signed(math.sin(math.pi * index / 256), 15, 16)
           for index in range(128)]
    write_memh(args.output_dir / "nco_q15_quarter.memh", nco, 16)

    # Exact rational mixer phase increments for the two default band-center
    # offsets, where phase_step = -(band_center - LO) / input_rate * 512.
    metadata["nco"] = {
        "phase_bits": 9,
        "phase_step_band_1": 199,
        "phase_step_band_2": (-201) % 512,
        "phase_initial_band_1": (199 * 102) % 512,
        "phase_initial_band_2": ((-201) * 102) % 512,
        "mixer_sign": "exp(-j*2*pi*delta_hz*n/input_rate)",
        "initial_phase_corrects_for": "(tap_count-1)/2 FIR group delay",
        "centers_hz": BAND_CENTERS_HZ,
    }
    metadata["channel_map"] = {
        f"band{band_number}": [
            {
                "channel": index + 1,
                "frequency_hz": frequency,
                "band_center_hz": center,
                "bin": round((frequency - center) / 12_500) % 32,
            }
            for index, frequency in enumerate(FRS_CHANNELS_HZ)
            if abs(frequency - center) <= 100_000
        ]
        for band_number, center in enumerate(BAND_CENTERS_HZ, start=1)
    }
    (args.output_dir / "metadata.json").write_text(
        json.dumps(metadata, indent=2) + "\n")
    print(f"Wrote {len(specs)} FIR assets to {args.output_dir}")
    for filename, record in metadata["files"].items():
        print(f"{filename}: {record['tap_count']} taps, "
              f"fixed sum {record['fixed_sum']:.9f}")


if __name__ == "__main__":
    main()
