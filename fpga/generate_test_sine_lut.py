#!/usr/bin/env python3
"""Generate the deterministic Q1.15 sine ROM used by the board FM test source."""

import math
from pathlib import Path


def main() -> None:
    output = Path(__file__).resolve().parent / "coeffs/test_sine_q15_1024.memh"
    values = [max(-32768, min(32767, round(32767 * math.sin(2 * math.pi * i / 1024))))
              for i in range(1024)]
    output.write_text("".join(f"{v & 0xffff:04x}\n" for v in values), encoding="ascii")


if __name__ == "__main__":
    main()
