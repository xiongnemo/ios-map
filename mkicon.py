#!/usr/bin/env python3
"""The icon of Map as the PNGs its Info.plist names (no asset catalog: actool is a Mac program): a map folded in three
-- land, a park, a river and a road on it, the middle panel in the shadow of its folds -- with a red pin standing on it,
on a green to blue gradient. SpringBoard rounds the corners itself.
usage: python3 -I mkicon.py APP_DIR"""
import math
import os
import struct
import sys
import zlib

TOP_LEFT, BOTTOM_RIGHT = (0x34, 0xb8, 0x6a), (0x15, 0x5a, 0xc4)
LAND = (0xf6, 0xf3, 0xea)
PARK = (0xab, 0xd9, 0x8c)
WATER = (0x8e, 0xc6, 0xf2)
ROAD = (0xf4, 0xbb, 0x42)
PIN, PIN_EDGE, PIN_LIGHT = (0xe5, 0x39, 0x35), (0x8c, 0x16, 0x16), (0xff, 0x9a, 0x8e)
SS = 4      # samples per pixel along each side

FOLDS = (0.15, 0.383, 0.617, 0.85)      # the map's left edge, its two folds, its right edge
TOPS = (0.30, 0.235, 0.30, 0.235)       # the top edge at each: the panels slant in turn, as a folded map's do
HEIGHT = 0.52
LIGHT = (1.0, 0.84, 0.96)               # how much light each panel gets
HEAD, RADIUS, TIP = (0.5, 0.385), 0.13, (0.5, 0.665)
ROAD_FROM, ROAD_TO = (0.15, 0.73), (0.85, 0.50)


def mix(c, d, a):
    return tuple(x + (y - x) * a for x, y in zip(c, d))


def panel(u, v):
    """the panel of the map (u, v) is on, or None"""
    for i in range(3):
        a, b = FOLDS[i], FOLDS[i + 1]
        if a <= u < b:
            top = TOPS[i] + (TOPS[i + 1] - TOPS[i]) * (u - a) / (b - a)
            return i if top <= v <= top + HEIGHT else None
    return None


def in_drop(u, v, radius, tip):
    """inside a drop: a circle round HEAD, and the cone from tip to where its sides touch the circle"""
    hx, hy = HEAD
    if math.hypot(u - hx, v - hy) <= radius:
        return True
    tx, ty = tip
    d = math.hypot(hx - tx, hy - ty)
    ax, ay = (hx - tx) / d, (hy - ty) / d           # the axis, from the tip up to the middle of the head
    px, py = u - tx, v - ty
    along = px * ax + py * ay
    across = abs(px * ay - py * ax)
    side = math.sqrt(d * d - radius * radius)       # tip to where a side touches the circle
    return 0 <= along <= side * side / d and across <= along * radius / side


def road_distance(u, v):
    (x0, y0), (x1, y1) = ROAD_FROM, ROAD_TO
    dx, dy = x1 - x0, y1 - y0
    t = max(0.0, min(1.0, ((u - x0) * dx + (v - y0) * dy) / (dx * dx + dy * dy)))
    return math.hypot(u - x0 - t * dx, v - y0 - t * dy)


def color(u, v):
    c = mix(TOP_LEFT, BOTTOM_RIGHT, (u + v) / 2)
    p = panel(u, v)
    if p is None:
        # the map's shadow on the gradient, down and to the right of it
        if panel(u - 0.014, v - 0.024) is not None:
            c = mix(c, (0, 0, 0), 0.24)
    else:
        c = LAND
        if math.hypot(u - 0.265, v - 0.66) < 0.075:
            c = PARK
        if abs(v - (0.45 + 0.04 * math.sin(u * 12 + 0.8))) < 0.028:
            c = WATER
        if road_distance(u, v) < 0.017:
            c = ROAD
        c = tuple(x * LIGHT[p] for x in c)
        # the pin's shadow where it stands
        if math.hypot((u - TIP[0]) / 0.075, (v - TIP[1]) / 0.022) < 1:
            c = mix(c, (0, 0, 0), 0.28)
    if in_drop(u, v, RADIUS + 0.011, (TIP[0], TIP[1] + 0.012)):
        c = PIN_EDGE
    if in_drop(u, v, RADIUS, TIP):
        # lit from the top left
        glow = max(0.0, 1 - math.hypot(u - HEAD[0] + 0.05, v - HEAD[1] + 0.05) / (RADIUS * 1.1))
        c = mix(PIN, PIN_LIGHT, 0.55 * glow * glow)
        if math.hypot(u - HEAD[0], v - HEAD[1]) < 0.05:
            c = (0xff, 0xff, 0xff)
    return c


def png(size):
    rows = []
    for y in range(size):
        row = bytearray([0])
        for x in range(size):
            total = [0, 0, 0]
            for i in range(SS):
                for j in range(SS):
                    c = color((x + (i + 0.5) / SS) / size, (y + (j + 0.5) / SS) / size)
                    total = [t + k for t, k in zip(total, c)]
            row += bytes(min(255, round(t / (SS * SS))) for t in total)
        rows.append(bytes(row))

    def chunk(kind, data):
        return struct.pack('>I', len(data)) + kind + data + struct.pack('>I', zlib.crc32(kind + data))
    return (b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', size, size, 8, 2, 0, 0, 0)) +
            chunk(b'IDAT', zlib.compress(b''.join(rows), 9)) + chunk(b'IEND', b''))


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    for scale in (2, 3):
        with open(os.path.join(sys.argv[1], 'AppIcon60x60@%dx.png' % scale), 'wb') as f:
            f.write(png(60 * scale))


main()
