#!/usr/bin/env python3
"""Generate ios/Echora/Resources/mock_table.jpg (1024x768) for MockPerceptionService.

Writes a PNG with the standard library, then converts it with macOS `sips`.
    python3 scripts/make_mock_table.py
"""
import os
import struct
import subprocess
import tempfile
import zlib

WIDTH = 1024
HEIGHT = 768
OUT = os.path.join(os.path.dirname(__file__), "..", "ios", "Echora", "Resources", "mock_table.jpg")


def pixel(x, y):
    # Wood-ish table with a checker placemat and a "mug" disc in the center.
    r, g, b = 150, 105, 70
    if 212 < x < 812 and 184 < y < 584:
        checker = ((x // 40) + (y // 40)) % 2
        r, g, b = (220, 220, 210) if checker else (60, 90, 140)
    dx = x - WIDTH / 2
    dy = y - HEIGHT / 2
    if dx * dx + dy * dy < 70 * 70:
        r, g, b = 30, 70, 200
    return bytes((r, g, b))


def png_bytes():
    rows = bytearray()
    for y in range(HEIGHT):
        rows.append(0)
        for x in range(WIDTH):
            rows += pixel(x, y)

    def chunk(kind, data):
        body = kind + data
        return struct.pack(">I", len(data)) + body + struct.pack(">I", zlib.crc32(body) & 0xFFFFFFFF)

    header = struct.pack(">IIBBBBB", WIDTH, HEIGHT, 8, 2, 0, 0, 0)
    return (
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", header)
        + chunk(b"IDAT", zlib.compress(bytes(rows), 6))
        + chunk(b"IEND", b"")
    )


def main():
    with tempfile.NamedTemporaryFile(suffix=".png", delete=False) as tmp:
        tmp.write(png_bytes())
        png_path = tmp.name
    subprocess.run(
        ["sips", "-s", "format", "jpeg", "-s", "formatOptions", "70", png_path, "--out", OUT],
        check=True,
        stdout=subprocess.DEVNULL,
    )
    os.remove(png_path)
    print("wrote", os.path.relpath(OUT))


if __name__ == "__main__":
    main()
