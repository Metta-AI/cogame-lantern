#!/usr/bin/env python3
"""Author and validate data/vault.mapspec.json.

The vault is hand-authored (lantern ships one map, never a generator: both
halves must be geometrically identical for the two hide fractions to compare
like with like).  The one invariant that is not obvious by eye is the fairness
one, so it is checked here and again in tests/test_map.nim:

  * every obstacle rect maps onto another obstacle rect under a 180 degree
    rotation of the floor (x -> W - x - w, y -> H - y - h), i.e. the arena has
    no preferred half;
  * every crate centre maps onto another crate centre under the same rotation;
  * spawns, nook anchors, sweep-lane waypoints, the caught pen and every crate
    box sit on free floor.

The seeker pen is deliberately NOT an obstacle: it is the one asymmetric
feature (both halves seek out of the same pen), so it lives in its own "pen"
block and is stamped separately.

Run:  python3 scripts/art/author_map.py > data/vault.mapspec.json
"""

import json
import sys

W, H = 1235, 659
WALL = 16
CRATE = 48
HALF = CRATE // 2


def rot(rect):
    x, y, w, h = rect
    return (W - x - w, H - y - h, w, h)


# ---------------------------------------------------------------------------
# Obstacles.  Authored as rotationally symmetric pairs; `pair()` emits both.
# ---------------------------------------------------------------------------
obstacles = []


def pair(x, y, w, h):
    a = (x, y, w, h)
    b = rot(a)
    obstacles.append(a)
    if b != a:
        obstacles.append(b)


# Outer wall.
pair(0, 0, W, WALL)                 # north + south
pair(0, 0, WALL, H)                 # west + east

# Six square pillars (three symmetric pairs).
pair(392, 132, 48, 48)
pair(392, 479, 48, 48)
pair(260, 60, 48, 48)

# Four three-sided alcoves.  Two vertical (opening west / opening east) and
# two horizontal (opening north / opening south); each pair is one rotation.
#
# West alcove: interior x in [204, 300], y in [246, 413], with a 47 px
# doorway at x = 196, y in [306, 353] -- one crate wide, so a single bolted
# crate really does shut it.  Its rotation is the east alcove.
pair(188, 230, 128, 16)             # west alcove north lip / east alcove south
pair(188, 413, 128, 16)             # west alcove south lip / east alcove north
pair(300, 230, 16, 199)             # west alcove back wall / east alcove back
pair(188, 246, 16, 60)              # west alcove front, above the doorway
pair(188, 353, 16, 60)              # west alcove front, below the doorway

# South alcove: interior x in [396, 505], y in [446, 513], with a 47 px
# doorway at y = 446, x in [427, 474].  It sits WEST of the pen mouth so the
# corridor out of the pen is never a 16 px slot.  Its rotation is the north
# alcove, on the east side.
pair(380, 446, 16, 67)              # south alcove west wall / north alcove east
pair(505, 446, 16, 67)              # south alcove east wall / north alcove west
pair(380, 513, 141, 16)             # south alcove back / north alcove back
pair(380, 430, 47, 16)              # south alcove front, west of the doorway
pair(474, 430, 47, 16)              # south alcove front, east of the doorway

# Two long racks (one symmetric pair): shelving that cuts the long sightlines
# between the spawn line and the pen.
pair(430, 300, 220, 16)

# Short baffles by the side walls, so the outer lanes are not open runs.
pair(120, 470, 16, 100)
pair(150, 180, 16, 120)

obstacles = sorted(set(obstacles))

# ---------------------------------------------------------------------------
# Crates: centres, 48x48, rotationally symmetric (x + x' == W, y + y' == H).
# ---------------------------------------------------------------------------
# Two crates start within a shove of each nook doorway (and their rotational
# partners do the same on the far side): a build act that cannot reach a
# crate is not a build act.
crates = [
    [150, 329], [1085, 330],
    [250, 290], [985, 369],
    [450, 380], [785, 279],
    [300, 180], [935, 479],
    [617, 270], [618, 389],
]

pen = {"x": 558, "y": 545, "w": 120, "h": 110,
       "door": {"x": 558, "y": 545, "w": 120, "h": 8}}
hider_spawns = [[150, 110], [617, 110], [1085, 110]]
seeker_spawns = [[588, 600], [617, 600], [646, 600]]
caught_pen = [617, 620]
nooks = [
    {"anchor": [240, 329], "opening": [[196, 306], [196, 353]]},
    {"anchor": [450, 490], "opening": [[427, 446], [474, 446]]},
    {"anchor": [995, 329], "opening": [[1039, 306], [1039, 353]]},
]
# Every lane starts at the pen mouth: a seeker walks OUT before it sweeps,
# so a lane whose first waypoint is due west can never press a seeker into
# the pen wall for a whole hunt act.
sweep_lanes = [
    [[617, 500], [205, 470], [205, 100], [340, 100], [340, 440]],
    [[617, 500], [617, 240], [880, 300], [400, 300], [617, 380]],
    [[617, 500], [1030, 470], [1030, 100], [890, 100], [890, 440]],
]
far_corner = [1085, 90]

# ---------------------------------------------------------------------------
# Validation.
# ---------------------------------------------------------------------------
mask = bytearray(W * H)


def stamp(x, y, w, h):
    for yy in range(max(0, y), min(H, y + h)):
        row = yy * W
        for xx in range(max(0, x), min(W, x + w)):
            mask[row + xx] = 1


for rect in obstacles:
    stamp(*rect)

pen_walls = [
    (pen["x"], pen["y"], 8, pen["h"]),
    (pen["x"] + pen["w"] - 8, pen["y"], 8, pen["h"]),
]
for rect in pen_walls:
    stamp(*rect)


def free(x, y):
    return 0 <= x < W and 0 <= y < H and mask[y * W + x] == 0


def free_box(cx, cy, half):
    for y in range(cy - half, cy + half + 1):
        for x in range(cx - half, cx + half + 1):
            if not free(x, y):
                return False
    return True


errors = []

rotset = {rot(r) for r in obstacles}
if rotset != set(obstacles):
    errors.append("obstacles are not invariant under a 180 degree rotation")

for cx, cy in crates:
    if [W - cx, H - cy] not in crates:
        errors.append(f"crate ({cx},{cy}) has no rotational partner")
    if not free_box(cx, cy, HALF):
        errors.append(f"crate box at ({cx},{cy}) is not on free floor")

for index, (a) in enumerate(crates):
    for b in crates[index + 1:]:
        if abs(a[0] - b[0]) < CRATE and abs(a[1] - b[1]) < CRATE:
            errors.append(f"crates {a} and {b} overlap")

for label, points in (("hider spawn", hider_spawns),
                      ("seeker spawn", seeker_spawns),
                      ("far corner", [far_corner]),
                      ("caught pen", [caught_pen])):
    for x, y in points:
        if not free_box(x, y, 7):
            errors.append(f"{label} ({x},{y}) is not on free floor")

for index, nook in enumerate(nooks):
    x, y = nook["anchor"]
    if not free_box(x, y, 7):
        errors.append(f"nook {index} anchor ({x},{y}) is not on free floor")

for lane, points in enumerate(sweep_lanes):
    for x, y in points:
        if not free_box(x, y, 7):
            errors.append(f"sweep lane {lane} waypoint ({x},{y}) is blocked")

if errors:
    for line in errors:
        print("ERROR:", line, file=sys.stderr)
    raise SystemExit(1)

spec = {
    "name": "vault",
    "width": W,
    "height": H,
    "obstacles": [{"kind": "rect", "x": x, "y": y, "w": w, "h": h}
                  for (x, y, w, h) in obstacles],
    "pen": pen,
    "hider_spawns": hider_spawns,
    "seeker_spawns": seeker_spawns,
    "caught_pen": caught_pen,
    "crates": crates,
    "nooks": nooks,
    "sweep_lanes": sweep_lanes,
    "far_corner": far_corner,
}
print(json.dumps(spec, indent=1))
