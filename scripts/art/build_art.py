#!/usr/bin/env python3
"""Generate lantern's board art.

Real painted art, not placeholder rectangles: a warehouse floor with poured
concrete grain and joint lines, wooden crates in their three states (loose,
locked with visible bolts, broken into splintered planks) and the lockerroom
plate. It no longer owns the cog sprites: client/art/cog_owl_rig.png and
cog_moth_rig.png are nano-banana renders of the Softmax cog, produced from
scripts/art/source/cogs_sheet.png by scripts/art/split_cog_sheet.py, and
this script never writes them.

The output is committed under client/art/ so the bundle stays hermetic — the
replay viewer downloads nothing but the replay itself.

Run:  python3 scripts/art/build_art.py
"""

import math
import os
import random

from PIL import Image, ImageDraw, ImageFilter

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.normpath(os.path.join(HERE, "..", "..", "client", "art"))

MOTH = (242, 193, 78)
OWL = (78, 205, 196)
WOOD = (123, 92, 53)
WOOD_LIT = (138, 106, 60)
INK = (24, 17, 11)
PAPER = (242, 232, 216)


def noise(image, amount, seed):
    rng = random.Random(seed)
    pixels = image.load()
    for y in range(image.size[1]):
        for x in range(image.size[0]):
            value = pixels[x, y]
            jitter = rng.randint(-amount, amount)
            pixels[x, y] = tuple(
                max(0, min(255, channel + jitter)) for channel in value[:3]
            ) + value[3:]
    return image


def floor_tile():
    """A 256x256 seamless concrete tile: poured slab, joints, cold cast."""
    size = 256
    image = Image.new("RGB", (size, size), (35, 30, 26))
    draw = ImageDraw.Draw(image)
    rng = random.Random(11)
    for _ in range(900):
        x = rng.randrange(size)
        y = rng.randrange(size)
        radius = rng.randint(1, 7)
        shade = rng.randint(-10, 12)
        draw.ellipse([x - radius, y - radius, x + radius, y + radius],
                     fill=(35 + shade, 30 + shade, 26 + shade))
    # slab joints
    for offset in (0, size // 2):
        draw.line([(offset, 0), (offset, size)], fill=(26, 22, 19), width=3)
        draw.line([(0, offset), (size, offset)], fill=(26, 22, 19), width=3)
    image = image.filter(ImageFilter.GaussianBlur(0.6))
    image = noise(image, 4, 12)
    image.save(os.path.join(OUT, "floor.jpg"), quality=88)


def crate(state):
    """A 96x96 painted wooden crate. state in {loose, locked, broken}."""
    size = 96
    image = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    draw = ImageDraw.Draw(image)
    if state == "broken":
        rng = random.Random(7)
        for _ in range(9):
            x0 = rng.randint(4, 60)
            y0 = rng.randint(20, 76)
            length = rng.randint(20, 40)
            angle = rng.uniform(-0.5, 0.5)
            x1 = x0 + length * math.cos(angle)
            y1 = y0 + length * math.sin(angle)
            draw.line([(x0, y0), (x1, y1)], fill=WOOD + (220,),
                      width=rng.randint(3, 6))
        return image
    body = WOOD_LIT if state == "locked" else WOOD
    draw.rounded_rectangle([2, 2, size - 3, size - 3], radius=4,
                           fill=body + (255,), outline=INK + (255,), width=3)
    # plank seams and the diagonal brace
    for y in (size // 3, 2 * size // 3):
        draw.line([(6, y), (size - 7, y)], fill=(90, 66, 38, 255), width=3)
        draw.line([(6, y + 3), (size - 7, y + 3)], fill=(160, 126, 78, 90),
                  width=2)
    draw.line([(8, size - 9), (size - 9, 8)], fill=(96, 72, 42, 160), width=4)
    if state == "locked":
        for x, y in ((14, 14), (size - 15, 14), (14, size - 15),
                     (size - 15, size - 15)):
            draw.ellipse([x - 6, y - 6, x + 6, y + 6],
                         fill=(216, 192, 138, 255), outline=INK + (255,),
                         width=2)
            draw.line([(x - 3, y), (x + 3, y)], fill=INK + (255,), width=2)
        # the bolted band
        draw.rectangle([4, size // 2 - 6, size - 5, size // 2 + 6],
                       outline=(216, 192, 138, 190), width=3)
    return image


def cog(colour, lantern):
    """A 128x128 top-down cog rig: chassis, tread band, visor, and (for a
    seeker) the lantern housing the flashlight cone comes out of."""
    size = 128
    image = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    draw = ImageDraw.Draw(image)
    centre = size // 2
    # contact shadow
    draw.ellipse([centre - 40, centre - 34, centre + 40, centre + 42],
                 fill=(0, 0, 0, 70))
    # chassis
    draw.ellipse([centre - 36, centre - 36, centre + 36, centre + 36],
                 fill=colour + (255,), outline=INK + (255,), width=5)
    # tread band
    for step in range(16):
        angle = step * math.pi / 8
        x = centre + math.cos(angle) * 30
        y = centre + math.sin(angle) * 30
        draw.ellipse([x - 4, y - 4, x + 4, y + 4], fill=INK + (200,))
    # visor, pointing +x (east) — the renderer rotates the sprite by the aim
    draw.pieslice([centre - 24, centre - 24, centre + 24, centre + 24],
                  -34, 34, fill=(28, 40, 46, 255), outline=INK + (255,),
                  width=3)
    draw.arc([centre - 16, centre - 12, centre + 20, centre + 16],
             -30, 30, fill=(150, 226, 222, 255), width=4)
    if lantern:
        draw.rectangle([centre + 26, centre - 11, centre + 46, centre + 11],
                       fill=(58, 48, 38, 255), outline=INK + (255,), width=3)
        draw.ellipse([centre + 40, centre - 8, centre + 52, centre + 8],
                     fill=(255, 248, 214, 255), outline=INK + (255,), width=2)
    return image


def locker_plate():
    """The pre-load curtain plate: a dark floor and one lit cone."""
    image = Image.new("RGB", (640, 360), (18, 13, 9))
    draw = ImageDraw.Draw(image)
    for step in range(220):
        radius = 40 + step * 2
        shade = max(0, 60 - step // 3)
        draw.pieslice([320 - radius, 300 - radius, 320 + radius, 300 + radius],
                      248, 292, outline=(shade + 20, shade + 16, shade), width=2)
    draw.ellipse([300, 285, 340, 315], fill=OWL)
    image = image.filter(ImageFilter.GaussianBlur(1.4))
    image.save(os.path.join(OUT, "lockerroom.jpg"), quality=86)


def main():
    os.makedirs(OUT, exist_ok=True)
    floor_tile()
    crate("loose").save(os.path.join(OUT, "crate.png"))
    crate("locked").save(os.path.join(OUT, "crate_locked.png"))
    crate("broken").save(os.path.join(OUT, "crate_broken.png"))
    # The cogs (cog_owl_rig.png, cog_moth_rig.png) are nano-banana renders
    # split out by scripts/art/split_cog_sheet.py, never painted here.
    locker_plate()
    print("wrote", ", ".join(sorted(os.listdir(OUT))))


if __name__ == "__main__":
    main()
