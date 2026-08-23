#!/usr/bin/env python3
"""Splits the nano-banana cog sheet into the two team sprites.

scripts/art/source/cogs_sheet.png is a single Gemini ("nano-banana") render
of the Softmax cog in lantern's two team kits — the Owl warden (teal plating,
brass warden's lantern, goggle visor, shoulder searchlight) and the Moth
(amber plating, spread moth-wing panels with eye-spots, feathery antennae)
— on a flat green backdrop. This script keys the backdrop out with an edge
flood fill (so teal/green accents survive), splits the row into two, crops
each to content, pads to a square and writes 128 px RGBA sprites:

    python3 scripts/art/split_cog_sheet.py [outdir]

Default outdir is client/art (the only art dir the bundle copies from; the
replay-viewer build copies client/art into replay-viewer/dist/art).
The viewer (client/broadcast_core.js) measures the solid-pixel centroid of
each sprite at load and rotates it about that pivot, so the sprites stay
front-facing ("south") here exactly like the old paintbot rigs.
"""

import os
import sys
from collections import deque

from PIL import Image

SRC = os.path.join(os.path.dirname(__file__), "source", "cogs_sheet.png")
ROLES = ["cog_owl_rig.png", "cog_moth_rig.png"]
SIZE = 128
TOL = 60  # colour distance from the backdrop that still counts as backdrop


def key_background(img):
    img = img.convert("RGBA")
    w, h = img.size
    px = img.load()
    # median of the border is robust to corner smudges in the render
    border = [px[x, y][:3] for x in range(w) for y in (0, h - 1)] + \
        [px[x, y][:3] for y in range(h) for x in (0, w - 1)]
    bg = tuple(sorted(c[i] for c in border)[len(border) // 2] for i in range(3))

    def near(p):
        r, g, b = p[:3]
        if sum((a - c) ** 2 for a, c in zip((r, g, b), bg)) ** 0.5 <= TOL:
            return True
        # the render paints a darker-green contact shadow under the wheels;
        # it is still unmistakably backdrop hue, so the edge fill eats it too
        return g > r + 40 and g > b + 40 and g >= bg[1] * 0.45

    seen = bytearray(w * h)
    q = deque()
    for x in range(w):
        for y in (0, h - 1):
            q.append((x, y))
    for y in range(h):
        for x in (0, w - 1):
            q.append((x, y))
    while q:
        x, y = q.popleft()
        if x < 0 or y < 0 or x >= w or y >= h or seen[y * w + x]:
            continue
        seen[y * w + x] = 1
        if not near(px[x, y]):
            continue
        px[x, y] = (0, 0, 0, 0)
        q.extend(((x + 1, y), (x - 1, y), (x, y + 1), (x, y - 1)))
    # soften the keyed edge: fade pixels still tinted toward the backdrop
    for y in range(h):
        for x in range(w):
            r, g, b, a = px[x, y]
            if a and g > r + 40 and g > b + 40 and abs(g - bg[1]) < 30 and abs(r - bg[0]) < 40:
                px[x, y] = (r, g, b, 0)
    return img


def split(img):
    """Separates the sheet into one sprite per character.

    The two cogs overlap in x (the Owl's lantern hand reaches under the
    Moth's wing tip), so a column scan cannot cut the row; instead the
    opaque pixels are grouped into connected components, the big ones are
    the characters, small bits inside (or just outside) a character's box
    join it, and specks elsewhere in the backdrop are dropped.
    """
    alpha = img.getchannel("A").load()
    w, h = img.size
    label = [0] * (w * h)
    comps = []
    for sy in range(h):
        for sx in range(w):
            if label[sy * w + sx] or not alpha[sx, sy]:
                continue
            cid = len(comps) + 1
            pixels = []
            q = deque([(sx, sy)])
            label[sy * w + sx] = cid
            while q:
                x, y = q.popleft()
                pixels.append((x, y))
                for nx, ny in ((x + 1, y), (x - 1, y), (x, y + 1), (x, y - 1)):
                    if 0 <= nx < w and 0 <= ny < h and alpha[nx, ny] \
                            and not label[ny * w + nx]:
                        label[ny * w + nx] = cid
                        q.append((nx, ny))
            comps.append(pixels)
    comps.sort(key=len, reverse=True)
    big = sorted(comps[:len(ROLES)], key=lambda c: sum(x for x, _ in c) / len(c))
    assert len(big) == len(ROLES), len(big)
    boxes = [(min(x for x, _ in c), min(y for _, y in c),
              max(x for x, _ in c), max(y for _, y in c)) for c in big]
    for small in comps[len(ROLES):]:
        cx = sum(x for x, _ in small) / len(small)
        cy = sum(y for _, y in small) / len(small)
        for i, (x0, y0, x1, y1) in enumerate(boxes):
            pad = (x1 - x0) * 0.08
            if x0 - pad <= cx <= x1 + pad and y0 - pad <= cy <= y1 + pad:
                big[i].extend(small)
                break
        # anything else is a keyed-out speck in the backdrop: dropped
    out = []
    for pixels in big:
        x0 = min(x for x, _ in pixels); x1 = max(x for x, _ in pixels) + 1
        y0 = min(y for _, y in pixels); y1 = max(y for _, y in pixels) + 1
        part = Image.new("RGBA", (x1 - x0, y1 - y0), (0, 0, 0, 0))
        src = img.load(); dst = part.load()
        for x, y in pixels:
            dst[x - x0, y - y0] = src[x, y]
        side = max(part.size)
        sq = Image.new("RGBA", (side, side), (0, 0, 0, 0))
        sq.paste(part, ((side - part.width) // 2, side - part.height))
        out.append(sq.resize((SIZE, SIZE), Image.LANCZOS))
    return out


def main():
    outdir = sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.dirname(__file__), "..", "..", "client", "art")
    os.makedirs(outdir, exist_ok=True)
    for name, sprite in zip(ROLES, split(key_background(Image.open(SRC)))):
        sprite.save(os.path.join(outdir, name))
    print("cog sprites written to", outdir)


if __name__ == "__main__":
    main()
