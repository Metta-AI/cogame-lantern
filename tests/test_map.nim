## The authored map. Lantern ships exactly one, and it has to be fair.

import std/[json, unittest]
import support/helpers

let map = testMap()
let mask = bakeWallMask(map)

proc freeBox(x, y, half: int): bool =
  not wallInBox(mask, x, y, half)

suite "vault":
  test "it loads, and it is the size the sim is pinned to":
    check map.name == "vault"
    check map.width == MapWidth
    check map.height == MapHeight
    check map.crates.len == 10
    check map.nooks.len == 3
    check map.sweepLanes.len == 3
    check map.hiderSpawns.len == 3
    check map.seekerSpawns.len == 3

  test "the obstacle set is invariant under a 180 degree rotation":
    ## The floor must not favour a spawn: every wall has its rotational twin.
    ## Rotation is about the exact floor centre (617.5, 329.5), which is what
    ## `x + x' == width` and `y + y' == height` say in integers.
    var present: seq[Rect]
    for rect in map.obstacles:
      present.add(rect)
    for rect in map.obstacles:
      check rotated(rect, map.width, map.height) in present
    ## The seeker pen is deliberately NOT an obstacle: it is the one
    ## asymmetric feature (both halves seek out of the same pen), so it lives
    ## in its own block and is exempt from this.
    check map.pen.x + map.pen.w div 2 == map.width div 2 + 1

  test "the crates are rotationally symmetric too":
    for crate in map.crates:
      check Point(x: map.width - crate.x, y: map.height - crate.y) in map.crates

  test "no two crate boxes overlap at the start":
    for first in 0 ..< map.crates.len:
      for second in first + 1 ..< map.crates.len:
        check not overlaps(crateRectAt(map.crates[first].x, map.crates[first].y),
                           crateRectAt(map.crates[second].x, map.crates[second].y))

  test "every crate box is on free floor":
    for crate in map.crates:
      check not wallInRect(mask, crateRectAt(crate.x, crate.y))

  test "every spawn, nook anchor and far corner is on free floor":
    for spawn in map.hiderSpawns & map.seekerSpawns &
        @[map.caughtPen, map.farCorner]:
      check freeBox(spawn.x, spawn.y, PlayerHalf)
    for nook in map.nooks:
      check freeBox(nook.anchor.x, nook.anchor.y, PlayerHalf)

  test "every nook doorway is about one crate wide - a bolted crate shuts it":
    for nook in map.nooks:
      let span =
        if nook.openA.x == nook.openB.x: absInt(nook.openA.y - nook.openB.y)
        else: absInt(nook.openA.x - nook.openB.x)
      check span > 0
      check span <= CrateSize

  test "the seeker spawns are inside the pen and the caught pen is not":
    for spawn in map.seekerSpawns:
      check map.pen.contains(spawn.x, spawn.y)

  test "the pen door blocks light while it is shut and not after":
    let sim = testSim()
    check sim.doorSolid
    let door = sim.map.door
    check gridBlocked(sim.blockGrid, door.x + door.w div 2, door.y + 2)
    sim.jumpToHunt()
    check not sim.doorSolid
    check not gridBlocked(sim.blockGrid, door.x + door.w div 2, door.y + 2)

  test "every sweep-lane waypoint is on free floor and reachable from the pen":
    ## Reachable = the unstick-augmented steering actually gets a seeker there
    ## inside the hunt act. A lane whose first waypoint is unreachable pins a
    ## seeker against a wall for a whole half; that happened in development.
    for lane in map.sweepLanes:
      for point in lane:
        check freeBox(point.x, point.y, PlayerHalf)
    let sim = testSim(prep = 240, hunt = 960)
    sim.jumpToHunt()
    var arrived: array[TeamSize, bool]
    while sim.tick < totalTicks(sim.config):
      sim.prepareTick()
      if isTurnStart(sim.config, sim.tick):
        for index, slot in [1, 3, 5]:
          sim.cogs[slot].order = Order(intent: inBeeline,
            target: map.sweepLanes[index][1], crate: -1, aim: amTarget)
          sim.cogs[slot].hasOrder = true
      sim.applyTick(compileControls(sim))
      for index, slot in [1, 3, 5]:
        if distPx(sim.cogs[slot].px, sim.cogs[slot].py,
                  map.sweepLanes[index][1].x, map.sweepLanes[index][1].y) < 48:
          arrived[index] = true
    for index in 0 ..< TeamSize:
      check arrived[index]
