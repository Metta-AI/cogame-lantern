## The two scripted baselines.
##
## `warden` is the certification player, the default, and the stronger of the
## two. `moth` is deliberately weaker and different in SHAPE, so the ladder
## has a spread rather than two copies of one idea.
##
## Both emit the identical order JSON on the identical 5 s cadence as an LLM
## seat, so their output is legal by construction and directly comparable —
## which is what makes the bounded-orders assertion in tests/test_baselines.nim
## meaningful. Both are pure functions of the world state plus their own
## per-seat scratch; the only randomness is the episode seed.
##
## Integer only — this is on the sim path.

import std/strutils
import types, arena, crates, rules, sim, state, labels

proc parseScriptKind*(text: string): ScriptKind =
  ## PLAYER_SCRIPTED values, following bullwhip's parser: "1"/"true"/"yes"/
  ## "warden" play the warden, "moth" the moth, anything else nothing.
  case text.strip().toLowerAscii()
  of "1", "true", "yes", "warden": skWarden
  of "moth": skMoth
  else: skNone

type
  WardenParams* = object
    ## The three numbers the `warden` baseline is tuned on. They are
    ## parameters rather than literals because `tools/tune_baselines.nim`
    ## sweeps them over a grid of seeds; the shipped values below are that
    ## sweep's argmax, recorded in `tests/fixtures/tuning_grid.json` and
    ## re-derived by `tests/test_tuning.nim`.
    coverageGatePct*: int  ## screen this much of the nook mouth, then bolt
    buildLocks*: int       ## locks the hider spends during the build act
    pryHotTurns*: int      ## hot/burning turns with nothing lit before a pry

const
  ShippedWardenParams* = WardenParams(coverageGatePct: 60, buildLocks: 3,
                                      pryHotTurns: 3)

proc openingSpan(nook: Nook): (bool, int, int, int) =
  ## (vertical?, lo, hi, fixed) for the nook's opening segment.
  if nook.openA.x == nook.openB.x:
    (true, min(nook.openA.y, nook.openB.y), max(nook.openA.y, nook.openB.y),
     nook.openA.x)
  else:
    (false, min(nook.openA.x, nook.openB.x), max(nook.openA.x, nook.openB.x),
     nook.openA.y)

proc openingMid(nook: Nook): Point =
  Point(x: (nook.openA.x + nook.openB.x) div 2,
        y: (nook.openA.y + nook.openB.y) div 2)

proc coveragePct*(nook: Nook, crate: Crate): int =
  ## How much of the nook's opening this crate's box screens, in percent.
  let (vertical, lo, hi, fixed) = openingSpan(nook)
  let box = crateRect(crate)
  let span = max(1, hi - lo)
  if vertical:
    if fixed < box.x - 8 or fixed > box.x + box.w + 8:
      return 0
    let overlap = min(hi, box.y + box.h) - max(lo, box.y)
    return clampInt(overlap * 100 div span, 0, 100)
  if fixed < box.y - 8 or fixed > box.y + box.h + 8:
    return 0
  let overlap = min(hi, box.x + box.w) - max(lo, box.x)
  clampInt(overlap * 100 div span, 0, 100)

proc wardenHide(sim: Sim, slot, half: int, params: WardenParams): Order =
  let config = sim.config
  let cog = sim.cogs[slot]
  let here = Point(x: cog.px, y: cog.py)
  let nook = sim.map.nooks[indexInTeam(slot) mod sim.map.nooks.len]
  let phase = phaseAt(sim.config, sim.tick)
  if phase.act == actBuild:
    if cog.locksUsed < params.buildLocks:
      let mid = openingMid(nook)
      ## Nearest loose crate TO THE DOORWAY, not to the cog: a crate on the
      ## far side of the alcove's own back wall cannot be shoved into the
      ## mouth without a pathfinder, and there is no pathfinder.
      let target = nearestCrate(sim.crates, mid.x, mid.y, {csLoose})
      if target >= 0:
        let seated = coveragePct(nook, sim.crates[target]) >=
          params.coverageGatePct or
          distPx(sim.crates[target].c.x, sim.crates[target].c.y,
                 mid.x, mid.y) <= 36
        ## Two turns of shoving is the whole budget for one crate. A crate
        ## that has not reached the mouth by then is jammed on something, and
        ## a bolted crate where it stands still screens SOMETHING — far
        ## better than spending the entire build act pushing a stuck box.
        let stalled = cog.memo[1] >= 2
        ## Always spend a lock on the LAST build turn: an unbolted crate is
        ## a crate the seekers can simply shove out of the way.
        let lastBuildTurn = phase.actLeft <= config.turnTicks
        if seated or stalled or lastBuildTurn:
          let reachable =
            if touchesCrate(sim.crates[target], here.x, here.y, 96): target
            else: nearestCrate(sim.crates, here.x, here.y, {csLoose})
          sim.cogs[slot].memo[1] = 0
          if reachable >= 0:
            return Order(intent: inLock, target: sim.crates[reachable].c,
                         crate: reachable, aim: amTarget, crawl: false,
                         note: "bolting " & crateId(reachable) &
                           " across the opening", say: "bolting down")
        sim.cogs[slot].memo[1] = cog.memo[1] + 1
        return Order(intent: inPush, target: mid, crate: target,
                     aim: amTarget, crawl: false,
                     note: "shoving " & crateId(target) &
                       " toward my alcove mouth", say: "screening")
    return Order(intent: inHide, target: nook.anchor, crate: -1,
                 aim: amTarget, crawl: false,
                 note: "alcove is screened; settling in", say: "set")
  ## Hunt act: hold still behind the screen, and break contact around a
  ## corner when a beam is reported nearby.
  var beamed = false
  for other in 0 ..< sim.seats:
    if roleOfSlot(other, half) == roSeeker and
        sim.beamNear(other, here.x, here.y):
      beamed = true
      break
  if beamed:
    sim.cogs[slot].memo[3] = sim.cogs[slot].memo[3] + 1
    return Order(intent: inFlee, target: here, crate: -1, aim: amTarget,
                 crawl: true, note: "beam on me; breaking around the corner",
                 say: "moving")
  let cycled = sim.map.nooks[(indexInTeam(slot) + cog.memo[3]) mod
                             sim.map.nooks.len]
  Order(intent: inHide, target: cycled.anchor, crate: -1, aim: amTarget,
        crawl: true, note: "still and dark behind the crate", say: "holding")

proc wardenSeek(sim: Sim, slot, half: int, params: WardenParams): Order =
  var cog = sim.cogs[slot]
  let here = Point(x: cog.px, y: cog.py)
  ## Anything lit is worth everything else put together.
  var bestLit = -1
  var bestDistance = high(int)
  for other in 0 ..< sim.seats:
    if roleOfSlot(other, half) != roHider or sim.cogs[other].found:
      continue
    let hider = sim.cogs[other]
    if not sim.teamLit(hider.px, hider.py):
      continue
    let d = dist2(here.x, here.y, hider.px, hider.py)
    if d < bestDistance:
      bestDistance = d
      bestLit = other
  if bestLit >= 0:
    sim.cogs[slot].memo[2] = 0
    return Order(intent: inChase, target: Point(x: sim.cogs[bestLit].px,
                                                y: sim.cogs[bestLit].py),
                 crate: -1, aim: amTrack, crawl: false,
                 note: "beam is on " & aliasOfSlot(bestLit) & "; staying on it",
                 say: "on them")
  ## Two turns of a hot heartbeat with nothing lit means the hider is behind
  ## something: breach it.
  if cog.band in {bdHot, bdBurning}:
    sim.cogs[slot].memo[2] = cog.memo[2] + 1
  else:
    sim.cogs[slot].memo[2] = 0
  if sim.cogs[slot].memo[2] >= params.pryHotTurns:
    let target = nearestCrate(sim.crates, here.x, here.y, {csLocked})
    if target >= 0:
      return Order(intent: inPry, target: sim.crates[target].c, crate: target,
                   aim: amTarget, crawl: false,
                   note: "hot with nothing lit; prying " & crateId(target),
                   say: "breaching")
  let lane = sim.map.sweepLanes[indexInTeam(slot) mod sim.map.sweepLanes.len]
  var index = clampInt(cog.memo[0], 0, lane.len - 1)
  if distPx(here.x, here.y, lane[index].x, lane[index].y) < 40:
    index = (index + 1) mod lane.len
  sim.cogs[slot].memo[0] = index
  Order(intent: inSweep, target: lane[index], crate: -1, aim: amSweep,
        crawl: false, note: "sweeping my third of the floor", say: "sweeping")

proc mothHide(sim: Sim, slot: int): Order =
  ## Never touches a crate: walks to the floor cell farthest from the pen and
  ## stands still.
  let cog = sim.cogs[slot]
  let far = sim.map.farCorner
  if distPx(cog.px, cog.py, far.x, far.y) > 24:
    return Order(intent: inScout, target: far, crate: -1, aim: amTarget,
                 crawl: true, note: "walking to the far corner", say: "far side")
  Order(intent: inHide, target: far, crate: -1, aim: amTarget, crawl: true,
        note: "standing still in the far corner", say: "still")

proc mothSeek(sim: Sim, slot, half: int): Order =
  let cog = sim.cogs[slot]
  let here = Point(x: cog.px, y: cog.py)
  for other in 0 ..< sim.seats:
    if roleOfSlot(other, half) != roHider or sim.cogs[other].found:
      continue
    let hider = sim.cogs[other]
    if sim.teamLit(hider.px, hider.py):
      return Order(intent: inChase, target: Point(x: hider.px, y: hider.py),
                   crate: -1, aim: amTrack, crawl: false,
                   note: "something is lit", say: "chasing")
  let centre = Point(x: MapWidth div 2, y: MapHeight div 2)
  let turn = sim.tick div sim.config.turnTicks
  if distPx(here.x, here.y, centre.x, centre.y) > 120 and turn mod 4 == 0:
    return Order(intent: inBeeline, target: centre, crate: -1, aim: amSweep,
                 crawl: false, note: "heading for the middle", say: "centre")
  ## A fresh waypoint every four turns, drawn from a per-seat PCG32 stream so
  ## the draw is a pure function of (seed, seat, turn).
  var rng = initPcg32(sim.config.seed xor (slot shl 8))
  for _ in 0 .. turn div 4:
    discard rng.nextUint32()
  let target = Point(x: clampInt(rng.nextRange(MapWidth), 24, MapWidth - 24),
                     y: clampInt(rng.nextRange(MapHeight), 24, MapHeight - 24))
  Order(intent: inSweep, target: target, crate: -1, aim: amSweep, crawl: false,
        note: "sweeping toward a fresh corner", say: "looking")

proc scriptedOrder*(sim: Sim, slot, half: int, kind: ScriptKind,
                    params = ShippedWardenParams): Order =
  ## The always-legal order for `slot` this turn. `skNone` plays the warden:
  ## a seat with no policy at all still plays the game. `params` is only ever
  ## non-default in the tuning harness.
  let role = roleOfSlot(slot, half)
  let effective = if kind == skNone: skWarden else: kind
  case effective
  of skMoth:
    if role == roHider: mothHide(sim, slot) else: mothSeek(sim, slot, half)
  else:
    if role == roHider: wardenHide(sim, slot, half, params)
    else: wardenSeek(sim, slot, half, params)
