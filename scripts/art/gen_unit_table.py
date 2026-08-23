#!/usr/bin/env python3
"""Regenerate the UnitTable const in src/lantern/types.nim.

The sim is integer-only: there is no sine, cosine or atan2 anywhere in
src/lantern, not even at compile time. The 256-entry unit-vector table the
aim code reads is generated HERE, once, and committed as a literal.

Run:  python3 scripts/art/gen_unit_table.py   # prints the table body
"""

import math

rows = []
for brad in range(256):
    theta = brad * 2 * math.pi / 256
    rows.append((round(1024 * math.cos(theta)), round(1024 * math.sin(theta))))

for i in range(0, 256, 4):
    chunk = ", ".join(f"Point(x: {x}, y: {y})" for x, y in rows[i:i + 4])
    print("    " + chunk + ",")
