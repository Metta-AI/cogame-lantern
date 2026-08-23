## Crates: the prop the whole game turns on.
##
## Paintbot's barrier grown up — same "prop with a footprint, a state and a
## touch radius" shape, now 48 px, opaque, pushable, lockable and pryable.
## A crate is solid (blocks movement) and opaque (blocks light and sight);
## `loose` crates can be shoved, `locked` ones cannot be moved by anybody and
## only a pry breaks them, `broken` ones are gone from the world.
##
## Integer only — this is on the sim path.

import types, arena

proc crateId*(index: int): string {.inline.} =
  "C" & $index

proc parseCrateId*(text: string, count: int): int =
  ## "C4" / "c4" / "4" -> 4; anything else -> -1. Case-insensitive, and the
  ## caller has already capped the string at MaxCrateIdRunes.
  if text.len == 0 or text.len > 3:
    return -1
  var digits = text
  if digits[0] == 'C' or digits[0] == 'c':
    digits = digits[1 .. ^1]
  if digits.len == 0:
    return -1
  var value = 0
  for character in digits:
    if character < '0' or character > '9':
      return -1
    value = value * 10 + (ord(character) - ord('0'))
  if value < 0 or value >= count:
    return -1
  value

proc crateIndexAt*(crates: seq[Crate], x, y: int): int =
  ## The live crate whose box contains this pixel, or -1.
  result = -1
  for index, crate in crates:
    if crate.state == csBroken:
      continue
    if crateRect(crate).contains(x, y):
      return index

proc crateBoxFree*(crates: seq[Crate], mask: seq[uint8], box: Rect,
                   skip: int, cogBoxes: seq[Rect]): bool =
  ## True when a crate box may legally occupy `box`: clear of static walls,
  ## of every other live crate, and of every cog other than the pusher.
  if wallInRect(mask, box):
    return false
  for index, crate in crates:
    if index == skip or crate.state == csBroken:
      continue
    if overlaps(box, crateRect(crate)):
      return false
  for cogBox in cogBoxes:
    if overlaps(box, cogBox):
      return false
  true

proc cogBox*(x, y: int): Rect {.inline.} =
  ## The cog footprint in whole pixels, from a sub-pixel position.
  Rect(x: x div MotionScale - PlayerHalf, y: y div MotionScale - PlayerHalf,
       w: 2 * PlayerHalf + 1, h: 2 * PlayerHalf + 1)

proc touchesCrate*(crate: Crate, px, py, range: int): bool =
  ## True when a body centre is within `range` px of the crate's box.
  let box = crateRect(crate)
  let dx = max(max(box.x - px, 0), px - (box.x + box.w - 1))
  let dy = max(max(box.y - py, 0), py - (box.y + box.h - 1))
  dx * dx + dy * dy <= range * range

proc nearestCrate*(crates: seq[Crate], px, py: int,
                   want: set[CrateState]): int =
  ## The nearest crate in one of `want`, or -1. Ties break on the lower
  ## index so the choice is deterministic.
  result = -1
  var best = high(int)
  for index, crate in crates:
    if crate.state notin want:
      continue
    let d = dist2(px, py, crate.c.x, crate.c.y)
    if d < best:
      best = d
      result = index

proc pushDistance*(role: Role): int {.inline.} =
  ## A hider shoves 6 px a tick; a seeker can move a loose crate, but not
  ## fast — 4 px. A locked crate moves for nobody.
  if role == roHider: HiderPushPx else: SeekerPushPx

proc lockRefused*(cog: Cog, config: GameConfig): bool {.inline.} =
  cog.locksUsed >= config.maxLocksPerHider
