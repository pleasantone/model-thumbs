#!/usr/bin/env python3
"""Writes sample G-code files whose previews are QOI images, using every QOI opcode.

usage: make_qoi_samples.py <folder>
"""
import base64
import os
import struct
import sys

SIZE = 64


def pixels():
    """A smooth gradient (small diffs), flat bands (runs), and a see-through stripe (alpha)."""
    out = []
    for y in range(SIZE):
        for x in range(SIZE):
            if y < 16:
                out.append((40, 90, 200, 255))
            elif y < 32:
                out.append((min(255, x * 4), min(255, y * 4), 128, 255))
            elif y < 44:
                out.append((230, 60, 40, 128))
            else:
                out.append(((x * 37) & 255, (y * 91) & 255, ((x ^ y) * 53) & 255, 255))
    return out


def encode(px):
    """Standard QOI encoder from the format spec."""
    data = bytearray(b"qoif" + struct.pack(">II", SIZE, SIZE) + bytes([4, 0]))
    seen = [(0, 0, 0, 0)] * 64
    prev = (0, 0, 0, 255)
    run = 0

    def wrap(v):
        return (v + 128) % 256 - 128

    for i, p in enumerate(px):
        if p == prev:
            run += 1
            if run == 62 or i == len(px) - 1:
                data.append(0xC0 | (run - 1))
                run = 0
            continue
        if run:
            data.append(0xC0 | (run - 1))
            run = 0
        h = (p[0] * 3 + p[1] * 5 + p[2] * 7 + p[3] * 11) % 64
        if seen[h] == p:
            data.append(h)
        elif p[3] != prev[3]:
            data += bytes([0xFF, *p])
        else:
            dr, dg, db = wrap(p[0] - prev[0]), wrap(p[1] - prev[1]), wrap(p[2] - prev[2])
            if all(-2 <= v <= 1 for v in (dr, dg, db)):
                data.append(0x40 | (dr + 2) << 4 | (dg + 2) << 2 | (db + 2))
            elif -32 <= dg <= 31 and -8 <= dr - dg <= 7 and -8 <= db - dg <= 7:
                data += bytes([0x80 | (dg + 32), (dr - dg + 8) << 4 | (db - dg + 8)])
            else:
                data += bytes([0xFE, *p[:3]])
        seen[h] = p
        prev = p
    return bytes(data + bytes([0] * 7 + [1]))


def main():
    folder = sys.argv[1]
    qoi = encode(pixels())
    text = base64.b64encode(qoi).decode()
    lines = [text[i:i + 78] for i in range(0, len(text), 78)]
    with open(os.path.join(folder, "sample-qoi.gcode"), "w") as f:
        f.write("; generated for testing\n;\n")
        f.write(f"; thumbnail_QOI begin {SIZE}x{SIZE} {len(text)}\n")
        f.writelines(f"; {line}\n" for line in lines)
        f.write("; thumbnail_QOI end\n;\nG28\n")
    with open(os.path.join(folder, "sample-qoi.bgcode"), "wb") as f:
        f.write(b"GCDE" + struct.pack("<IH", 1, 0))
        f.write(struct.pack("<HHI", 5, 0, len(qoi)) + struct.pack("<HHH", 2, SIZE, SIZE) + qoi)


if __name__ == "__main__":
    main()
