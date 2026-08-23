## Arena geometry: load the authored map, bake the wall mask, answer the
## pixel and line-of-sight queries the step needs.
##
## Lantern ships ONE authored map (`data/vault.mapspec.json`). Paintbot's
## procedural generator, validators, curated pool and map-size knobs are all
## dropped: both halves of a lantern match must be geometrically identical
## for the two hide fractions to compare like with like, and a hiding game
## wants a hand-tuned distribution of alcoves and sightlines rather than a
## seeded draw.
##
## Integer only. `pointInPolygon` keeps paintbot's STRICT-STRADDLE even-odd
## convention so a mask baked here is bit-identical under emscripten.

import std/[json, os]
import types

proc pointJson(node: JsonNode): Point =
  Point(x: node[0].getInt(), y: node[1].getInt())

proc rectJson(node: JsonNode): Rect =
  Rect(x: node{"x"}.getInt(), y: node{"y"}.getInt(),
       w: node{"w"}.getInt(), h: node{"h"}.getInt())

proc contains*(rect: Rect, x, y: int): bool {.inline.} =
  x >= rect.x and x < rect.x + rect.w and y >= rect.y and y < rect.y + rect.h

proc overlaps*(a, b: Rect): bool {.inline.} =
  a.x < b.x + b.w and b.x < a.x + a.w and a.y < b.y + b.h and b.y < a.y + a.h

proc rotated*(rect: Rect, width, height: int): Rect =
  ## The 180-degree rotation of `rect` about the floor centre. The obstacle
  ## set is invariant under this map — tests/test_map.nim asserts it, because
  ## a floor that favours one half would make the two halves incomparable.
  Rect(x: width - rect.x - rect.w, y: height - rect.y - rect.h,
       w: rect.w, h: rect.h)

proc parseMapSpec*(text: string): MapSpec =
  let node = parseJson(text)
  result.raw = node
  result.name = node{"name"}.getStr("vault")
  result.width = node{"width"}.getInt(MapWidth)
  result.height = node{"height"}.getInt(MapHeight)
  if result.width != MapWidth or result.height != MapHeight:
    raise newException(LanternError,
      "map " & result.name & " is " & $result.width & "x" & $result.height &
      "; lantern is pinned to " & $MapWidth & "x" & $MapHeight)
  for shape in node{"obstacles"}:
    if shape{"kind"}.getStr("rect") != "rect":
      raise newException(LanternError,
        "unsupported obstacle kind: " & shape{"kind"}.getStr())
    result.obstacles.add(rectJson(shape))
  let pen = node{"pen"}
  if pen.isNil or pen.kind != JObject:
    raise newException(LanternError, "map has no pen block")
  result.pen = rectJson(pen)
  result.door = rectJson(pen{"door"})
  for point in node{"hider_spawns"}:
    result.hiderSpawns.add(pointJson(point))
  for point in node{"seeker_spawns"}:
    result.seekerSpawns.add(pointJson(point))
  result.caughtPen = pointJson(node{"caught_pen"})
  for point in node{"crates"}:
    result.crates.add(pointJson(point))
  for nook in node{"nooks"}:
    result.nooks.add(Nook(
      anchor: pointJson(nook{"anchor"}),
      openA: pointJson(nook{"opening"}[0]),
      openB: pointJson(nook{"opening"}[1])))
  for lane in node{"sweep_lanes"}:
    var waypoints: seq[Point]
    for point in lane:
      waypoints.add(pointJson(point))
    result.sweepLanes.add(waypoints)
  result.farCorner = pointJson(node{"far_corner"})
  if result.hiderSpawns.len < TeamSize or result.seekerSpawns.len < TeamSize:
    raise newException(LanternError, "map must declare three spawns per side")
  if result.nooks.len < TeamSize or result.sweepLanes.len < TeamSize:
    raise newException(LanternError, "map must declare three nooks and lanes")

proc mapSearchDirs(): seq[string] =
  let appDir = getAppDir()
  @[appDir / "data", appDir / ".." / "data", "data", "../data"]

proc loadMapSpec*(name: string): MapSpec =
  ## `mapPath: "vault"` resolves to data/vault.mapspec.json next to the binary
  ## (the run image copies ./data), then to the repo layout for tests.
  let file = name & ".mapspec.json"
  for dir in mapSearchDirs():
    let candidate = dir / file
    if fileExists(candidate):
      return parseMapSpec(readFile(candidate))
  raise newException(LanternError, "map not found: " & file)

# ---------------------------------------------------------------------------
# Masks.
# ---------------------------------------------------------------------------

proc stampRect(mask: var seq[uint8], rect: Rect) =
  let x0 = clampInt(rect.x, 0, MapWidth)
  let x1 = clampInt(rect.x + rect.w, 0, MapWidth)
  let y0 = clampInt(rect.y, 0, MapHeight)
  let y1 = clampInt(rect.y + rect.h, 0, MapHeight)
  for y in y0 ..< y1:
    let row = y * MapWidth
    for x in x0 ..< x1:
      mask[row + x] = 1

proc bakeWallMask*(map: MapSpec): seq[uint8] =
  ## Static geometry only: the outer wall, the authored obstacles, and the
  ## seeker pen's two side walls. The pen DOOR is dynamic (solid during a
  ## build act, open during a hunt) and lives in the coarse block grid.
  result = newSeq[uint8](MapWidth * MapHeight)
  for rect in map.obstacles:
    stampRect(result, rect)
  stampRect(result, Rect(x: map.pen.x, y: map.pen.y, w: 8, h: map.pen.h))
  stampRect(result, Rect(x: map.pen.x + map.pen.w - 8, y: map.pen.y,
                         w: 8, h: map.pen.h))

proc wallAt*(mask: seq[uint8], x, y: int): bool {.inline.} =
  if x < 0 or y < 0 or x >= MapWidth or y >= MapHeight:
    return true
  mask[y * MapWidth + x] != 0

proc wallInBox*(mask: seq[uint8], cx, cy, half: int): bool =
  ## True when any pixel of the axis-aligned box touches static geometry.
  let x0 = cx - half
  let x1 = cx + half
  let y0 = cy - half
  let y1 = cy + half
  if x0 < 0 or y0 < 0 or x1 >= MapWidth or y1 >= MapHeight:
    return true
  for y in y0 .. y1:
    let row = y * MapWidth
    for x in x0 .. x1:
      if mask[row + x] != 0:
        return true
  false

proc wallInRect*(mask: seq[uint8], rect: Rect): bool =
  if rect.x < 0 or rect.y < 0 or
      rect.x + rect.w > MapWidth or rect.y + rect.h > MapHeight:
    return true
  for y in rect.y ..< rect.y + rect.h:
    let row = y * MapWidth
    for x in rect.x ..< rect.x + rect.w:
      if mask[row + x] != 0:
        return true
  false

proc crateRect*(crate: Crate): Rect {.inline.} =
  Rect(x: crate.c.x - CrateHalf, y: crate.c.y - CrateHalf,
       w: CrateSize, h: CrateSize)

proc crateRectAt*(cx, cy: int): Rect {.inline.} =
  Rect(x: cx - CrateHalf, y: cy - CrateHalf, w: CrateSize, h: CrateSize)

# ---- coarse occlusion grid -------------------------------------------------

proc gridIndex*(x, y: int): int {.inline.} =
  (y div FovCell) * FovW + (x div FovCell)

proc stampGridRect(grid: var seq[uint8], rect: Rect) =
  let x0 = clampInt(rect.x div FovCell, 0, FovW - 1)
  let x1 = clampInt((rect.x + rect.w - 1) div FovCell, 0, FovW - 1)
  let y0 = clampInt(rect.y div FovCell, 0, FovH - 1)
  let y1 = clampInt((rect.y + rect.h - 1) div FovCell, 0, FovH - 1)
  for cy in y0 .. y1:
    let row = cy * FovW
    for cx in x0 .. x1:
      grid[row + cx] = 1

proc bakeStaticGrid*(mask: seq[uint8]): seq[uint8] =
  ## A cell is opaque when any pixel inside it is. Baked once from the wall
  ## mask; crates and the pen door are stamped on top every rebake.
  result = newSeq[uint8](FovW * FovH)
  for cy in 0 ..< FovH:
    let y1 = min((cy + 1) * FovCell, MapHeight)
    for cx in 0 ..< FovW:
      let x1 = min((cx + 1) * FovCell, MapWidth)
      var opaque = false
      for y in cy * FovCell ..< y1:
        let row = y * MapWidth
        for x in cx * FovCell ..< x1:
          if mask[row + x] != 0:
            opaque = true
            break
        if opaque:
          break
      if opaque:
        result[cy * FovW + cx] = 1

proc rebakeBlockGrid*(grid: var seq[uint8], staticGrid: seq[uint8],
                      crates: seq[Crate], door: Rect, doorSolid: bool) =
  ## Step 9 of the resolution order: `blockMask` = static geometry OR the
  ## footprints of all non-broken crates (OR the pen door while it is shut).
  ## Ten AABB stamps over 12 865 cells — bounded, and cheap enough to run on
  ## any tick a crate moved, locked or broke.
  for index in 0 ..< grid.len:
    grid[index] = staticGrid[index]
  if doorSolid:
    stampGridRect(grid, door)
  for crate in crates:
    if crate.state != csBroken:
      stampGridRect(grid, crateRect(crate))

proc gridBlocked*(grid: seq[uint8], x, y: int): bool {.inline.} =
  if x < 0 or y < 0 or x >= MapWidth or y >= MapHeight:
    return true
  grid[(y div FovCell) * FovW + (x div FovCell)] != 0

proc lineOfSight*(grid: seq[uint8], ax, ay, bx, by: int): bool =
  ## Integer DDA over the coarse occlusion grid. Endpoint cells are exempt:
  ## a cog standing against a crate can still see out, and a crate's own cell
  ## must not hide the crate from the lantern lighting it.
  let acx = ax div FovCell
  let acy = ay div FovCell
  let bcx = bx div FovCell
  let bcy = by div FovCell
  if acx == bcx and acy == bcy:
    return true
  var dx = absInt(bcx - acx)
  var dy = absInt(bcy - acy)
  let sx = signInt(bcx - acx)
  let sy = signInt(bcy - acy)
  var cx = acx
  var cy = acy
  var err = dx - dy
  while true:
    if cx == bcx and cy == bcy:
      return true
    let e2 = 2 * err
    if e2 > -dy:
      err -= dy
      cx += sx
    if e2 < dx:
      err += dx
      cy += sy
    if cx == bcx and cy == bcy:
      return true
    if cx < 0 or cy < 0 or cx >= FovW or cy >= FovH:
      return false
    if grid[cy * FovW + cx] != 0:
      return false
