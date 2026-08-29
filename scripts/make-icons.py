#!/usr/bin/env python3
"""Generate Rosy Bit's two icon assets from one sakura motif.

Two assets, one motif, and they are not interchangeable:

  * the menu bar icon MUST be a monochrome template image — macOS tints
    template images itself to match the menu bar and appearance mode, so a
    rosy tint here would simply be thrown away;
  * the app icon (Finder, Login Items, About) is where the rosy tint belongs.
    That is the one people actually see in System Settings.

Pure standard library on purpose: no Pillow, no numpy, no cairo. It runs on a
stock python3 anywhere, including the system python3 on Rosy. The generated
PNGs are committed, so this only needs re-running if the motif changes.

    python3 scripts/make-icons.py

Outputs into Support/icons/:
    sakura.svg                  vector source of truth
    MenuBarIcon.png             18x18  black on transparent (template)
    MenuBarIcon@2x.png          36x36  black on transparent (template)
    AppIcon.iconset/*.png       the ten sizes `iconutil` expects
"""

import math
import os
import struct
import zlib

# --- Motif geometry -------------------------------------------------------
# Normalised so the flower's bounding radius is exactly 1.0. Five petals, one
# pointing up, each an ellipse with a circular notch bitten out of its tip —
# that cleft is the whole sakura signature. A centre disc fills the middle
# where the petals would otherwise leave a gap.

PETALS = 5
PETAL_CENTRE = 0.55      # distance from origin to the petal ellipse's centre
PETAL_LENGTH = 0.45      # ellipse semi-axis along the petal's own axis
PETAL_WIDTH = 0.30       # ellipse semi-axis across it
CENTRE_RADIUS = 0.24
NOTCH_CENTRE = 1.02      # notch circle sits just beyond the petal tip
NOTCH_RADIUS = 0.20

_ANGLES = [(-math.pi / 2) + k * 2 * math.pi / PETALS for k in range(PETALS)]
_FRAMES = [(math.cos(a), math.sin(a)) for a in _ANGLES]

# Body of the app icon: a superellipse, the familiar macOS rounded square.
BODY_EXPONENT = 5.0
BODY_HALF_WIDTH = 0.40   # fraction of the canvas, so the body spans 80%
FLOWER_IN_APP_ICON = 0.30
FLOWER_IN_MENU_BAR = 0.45

ROSE_TOP = (255, 176, 200)
ROSE_BOTTOM = (226, 92, 138)
PETAL_WHITE = (255, 250, 252)

MASTER = 1024            # master mask resolution; flower fills it exactly
SUPERSAMPLE = 2

ICONSET_SIZES = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024),
]


def in_flower(px, py):
    """True if the normalised point lies inside the sakura silhouette."""
    radius_squared = px * px + py * py
    if radius_squared > 1.1:            # outside the bounding circle entirely
        return False
    if radius_squared <= CENTRE_RADIUS * CENTRE_RADIUS:
        return True

    for cos_a, sin_a in _FRAMES:
        # Rotate into this petal's frame: u along its axis, v across it.
        u = px * cos_a + py * sin_a
        v = -px * sin_a + py * cos_a

        du = (u - PETAL_CENTRE) / PETAL_LENGTH
        dv = v / PETAL_WIDTH
        if du * du + dv * dv > 1.0:
            continue

        # Inside the ellipse — unless it falls in the notch at the tip.
        nu = u - NOTCH_CENTRE
        if nu * nu + v * v <= NOTCH_RADIUS * NOTCH_RADIUS:
            continue
        return True
    return False


def render_master_mask():
    """Antialiased coverage of the flower filling a MASTER x MASTER canvas."""
    mask = bytearray(MASTER * MASTER)
    samples = SUPERSAMPLE * SUPERSAMPLE
    offsets = [(i + 0.5) / SUPERSAMPLE for i in range(SUPERSAMPLE)]

    for y in range(MASTER):
        row = y * MASTER
        for x in range(MASTER):
            hits = 0
            for oy in offsets:
                # Map pixel space to [-1, 1] with y pointing up.
                py = 1.0 - 2.0 * (y + oy) / MASTER
                for ox in offsets:
                    px = 2.0 * (x + ox) / MASTER - 1.0
                    if in_flower(px, py):
                        hits += 1
            if hits:
                mask[row + x] = (hits * 255) // samples
    return mask


def downsample(mask, source_size, target_size):
    """Box-filter a square 8-bit mask down to target_size."""
    if target_size == source_size:
        return mask
    out = bytearray(target_size * target_size)
    for ty in range(target_size):
        y0 = (ty * source_size) // target_size
        y1 = max(y0 + 1, ((ty + 1) * source_size) // target_size)
        for tx in range(target_size):
            x0 = (tx * source_size) // target_size
            x1 = max(x0 + 1, ((tx + 1) * source_size) // target_size)
            total = 0
            for sy in range(y0, y1):
                base = sy * source_size
                total += sum(mask[base + x0:base + x1])
            out[ty * target_size + tx] = total // ((y1 - y0) * (x1 - x0))
    return out


def place_centred(small, small_size, canvas_size):
    """Paste a square mask into the middle of a larger transparent canvas."""
    canvas = bytearray(canvas_size * canvas_size)
    offset = (canvas_size - small_size) // 2
    for y in range(small_size):
        start = (y + offset) * canvas_size + offset
        canvas[start:start + small_size] = small[y * small_size:(y + 1) * small_size]
    return canvas


def body_coverage(size):
    """Antialiased coverage of the app icon's rounded-square body."""
    coverage = bytearray(size * size)
    offsets = [(i + 0.5) / SUPERSAMPLE for i in range(SUPERSAMPLE)]
    samples = SUPERSAMPLE * SUPERSAMPLE
    half = BODY_HALF_WIDTH * 2.0   # in [-1, 1] space

    for y in range(size):
        for x in range(size):
            hits = 0
            for oy in offsets:
                py = abs(1.0 - 2.0 * (y + oy) / size) / half
                if py > 1.0:
                    continue
                py5 = py * py * py * py * py
                for ox in offsets:
                    px = abs(2.0 * (x + ox) / size - 1.0) / half
                    if px > 1.0:
                        continue
                    if px * px * px * px * px + py5 <= 1.0:
                        hits += 1
            if hits:
                coverage[y * size + x] = (hits * 255) // samples
    return coverage


def write_png(path, size, pixels):
    """Write 8-bit RGBA pixels (a flat bytes-like of size*size*4)."""
    raw = bytearray()
    stride = size * 4
    for y in range(size):
        raw.append(0)                       # filter type 0 (None)
        raw += pixels[y * stride:(y + 1) * stride]

    def chunk(tag, data):
        return (struct.pack(">I", len(data)) + tag + data
                + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF))

    header = struct.pack(">IIBBBBB", size, size, 8, 6, 0, 0, 0)
    blob = (b"\x89PNG\r\n\x1a\n"
            + chunk(b"IHDR", header)
            + chunk(b"IDAT", zlib.compress(bytes(raw), 9))
            + chunk(b"IEND", b""))
    with open(path, "wb") as handle:
        handle.write(blob)


def write_template_png(path, size, master):
    """The menu bar asset: solid black, alpha carries the shape."""
    flower_px = max(1, round(FLOWER_IN_MENU_BAR * 2 * size))
    alpha = place_centred(downsample(master, MASTER, flower_px), flower_px, size)

    pixels = bytearray(size * size * 4)
    for i, a in enumerate(alpha):
        pixels[i * 4 + 3] = a               # RGB stays 0,0,0
    write_png(path, size, pixels)


def write_app_icon_png(path, size, master):
    """The app icon: rosy gradient body, sakura in near-white on top."""
    flower_px = max(1, round(FLOWER_IN_APP_ICON * 2 * size))
    flower = place_centred(downsample(master, MASTER, flower_px), flower_px, size)
    body = body_coverage(size)

    pixels = bytearray(size * size * 4)
    for y in range(size):
        t = y / max(1, size - 1)
        base = [round(ROSE_TOP[c] + (ROSE_BOTTOM[c] - ROSE_TOP[c]) * t) for c in range(3)]
        for x in range(size):
            i = y * size + x
            body_alpha = body[i]
            if not body_alpha:
                continue
            f = flower[i] / 255.0
            out = i * 4
            for c in range(3):
                pixels[out + c] = round(base[c] * (1.0 - f) + PETAL_WHITE[c] * f)
            pixels[out + 3] = body_alpha
    write_png(path, size, pixels)


def write_svg(path):
    """Vector source of truth, built from the same primitives as the raster."""
    scale, centre = 100.0, 128.0

    def to_svg(value):
        return round(value * scale, 3)

    notches = []
    petals = []
    for angle in _ANGLES:
        degrees = round(math.degrees(angle), 4)
        petals.append(
            f'      <ellipse cx="{to_svg(PETAL_CENTRE)}" cy="0" '
            f'rx="{to_svg(PETAL_LENGTH)}" ry="{to_svg(PETAL_WIDTH)}" '
            f'transform="rotate({degrees})"/>'
        )
        notches.append(
            f'      <circle cx="{to_svg(NOTCH_CENTRE)}" cy="0" '
            f'r="{to_svg(NOTCH_RADIUS)}" fill="black" '
            f'transform="rotate({degrees})"/>'
        )

    newline = "\n"
    svg = f"""<?xml version="1.0" encoding="UTF-8"?>
<!-- Rosy Bit sakura motif. Generated by scripts/make-icons.py -->
<svg xmlns="http://www.w3.org/2000/svg" width="256" height="256" viewBox="0 0 256 256">
  <defs>
    <mask id="notches" maskUnits="userSpaceOnUse" x="0" y="0" width="256" height="256">
      <rect x="0" y="0" width="256" height="256" fill="white"/>
      <g transform="translate({centre},{centre})">
{newline.join(notches)}
      </g>
    </mask>
  </defs>
  <g transform="translate({centre},{centre})" fill="currentColor">
    <g mask="url(#notches)">
{newline.join(petals)}
    </g>
    <circle cx="0" cy="0" r="{to_svg(CENTRE_RADIUS)}"/>
  </g>
</svg>
"""
    with open(path, "w", encoding="utf-8") as handle:
        handle.write(svg)


def main():
    here = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    icons = os.path.join(here, "Support", "icons")
    iconset = os.path.join(icons, "AppIcon.iconset")
    os.makedirs(iconset, exist_ok=True)

    print("rendering master mask ...")
    master = render_master_mask()

    write_svg(os.path.join(icons, "sakura.svg"))
    print("  sakura.svg")

    for name, size in [("MenuBarIcon.png", 18), ("MenuBarIcon@2x.png", 36)]:
        write_template_png(os.path.join(icons, name), size, master)
        print(f"  {name}")

    for name, size in ICONSET_SIZES:
        write_app_icon_png(os.path.join(iconset, name), size, master)
        print(f"  AppIcon.iconset/{name}")

    print("done. `make icons` turns the iconset into AppIcon.icns on macOS.")


if __name__ == "__main__":
    main()
