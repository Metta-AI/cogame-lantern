## The lantern sim: one 24 Hz integer step, in the exact resolution order the
## design note fixes.
##
##   1  phase clock (half reset, keyframe)      9  occlusion rebake
##   2  frozen seats (seekers, build act)      10  lanterns and sight
##   3  control compile          (control.nim) 11  detection
##   4  quantise                 (control.nim) 12  score accrual
##   5  aim                                    13  heartbeat and sound decay
##   6  motion                                 14  keyframe
##   7  crates                                 15  act / half / match end
##   8  lock and pry
##
## The sim consumes ONLY the four quantised control bytes per cog per tick and
## the recorded replay carries only those bytes: that is the determinism
## boundary. Everything here is integer, so the native build and the
## emscripten viewer build agree bit for bit by construction.

import std/json
import types, arena, crates, rules, state, events, labels

proc seats*(sim: Sim): int {.inline.} = sim.cogs.len

proc px*(cog: Cog): int {.inline.} = cog.x div MotionScale
proc py*(cog: Cog): int {.inline.} = cog.y div MotionScale

proc roleOf*(sim: Sim, slot, half: int): Role {.inline.} =
  roleOfSlot(slot, half)

proc emit*(sim: Sim, event: JsonNode) {.inline.} =
  sim.events.add(event)

# ---------------------------------------------------------------------------
# Construction and the half reset.
# ---------------------------------------------------------------------------

proc placeCogs(sim: Sim, half: int) =
  var hiderIndex = 0
  var seekerIndex = 0
  for slot in 0 ..< sim.seats:
    let spawn =
      if roleOfSlot(slot, half) == roHider:
        let p = sim.map.hiderSpawns[hiderIndex mod sim.map.hiderSpawns.len]
        inc hiderIndex
        p
      else:
        let p = sim.map.seekerSpawns[seekerIndex mod sim.map.seekerSpawns.len]
        inc seekerIndex
        p
    var cog = Cog()
    cog.x = spawn.x * MotionScale
    cog.y = spawn.y * MotionScale
    cog.aim = (if roleOfSlot(slot, half) == roHider: 192 else: 64)
    cog.foundTick = -1
    cog.lockTarget = -1
    cog.pryTarget = -1
    cog.lastStepSoundTick = -StepSoundEveryTicks
    cog.lastLitTick = -1
    cog.band = bdCold
    cog.unstickAnchorX = cog.x
    cog.unstickAnchorY = cog.y
    ## Carried across the reset: nothing but the score.
    cog.hiddenTicks = sim.cogs[slot].hiddenTicks
    cog.finds = sim.cogs[slot].finds
    cog.cratesPushed = sim.cogs[slot].cratesPushed
    cog.cratesLocked = sim.cogs[slot].cratesLocked
    cog.cratesBroken = sim.cogs[slot].cratesBroken
    sim.cogs[slot] = cog

proc placeCrates(sim: Sim) =
  sim.crates.setLen(0)
  for index in 0 ..< min(sim.config.crateCount, sim.map.crates.len):
    sim.crates.add(Crate(c: sim.map.crates[index], state: csLoose,
                         lastPushTick: -PushSoundEveryTicks))

proc rebake(sim: Sim) =
  rebakeBlockGrid(sim.blockGrid, sim.staticGrid, sim.crates, sim.map.door,
                  sim.doorSolid)
  sim.blockDirty = false

proc rebakeForTests*(sim: Sim) =
  ## Tests move crates directly to build an exact geometry; the occlusion
  ## grid is normally rebaked by step 9, so expose the same rebake.
  sim.rebake()

proc newSim*(config: GameConfig, map: MapSpec): Sim =
  result = Sim(config: config, map: map)
  result.cogs = newSeq[Cog](config.numAgents)
  result.wallMask = bakeWallMask(map)
  result.staticGrid = bakeStaticGrid(result.wallMask)
  result.blockGrid = newSeq[uint8](FovW * FovH)
  result.rng = initPcg32(config.seed)
  result.doorSolid = true
  result.endReason = erComplete
  result.endRule = edFullTime
  result.placeCogs(1)
  result.placeCrates()
  result.rebake()

proc resetHalf*(sim: Sim, half: int) =
  ## Exact half reset. Every crate returns to its authored start position in
  ## state `loose`; broken crates return; velocities, aims, lock/pry progress
  ## and `locks_used` are zeroed; found hiders leave the caught pen. Nothing
  ## carries across the intermission except the score.
  sim.doorSolid = true
  sim.sounds.setLen(0)
  sim.placeCrates()
  sim.placeCogs(half)
  sim.rebake()

# ---------------------------------------------------------------------------
# Sight. There is no trigonometry: the cone is an integer brad comparison and
# the range is a squared-distance comparison, both against the coarse
# occlusion grid baked in step 9.
# ---------------------------------------------------------------------------

proc hasSight*(sim: Sim, ax, ay, bx, by: int): bool {.inline.} =
  lineOfSight(sim.blockGrid, ax, ay, bx, by)

proc lanternsOn*(sim: Sim): bool {.inline.} =
  phaseAt(sim.config, sim.tick).act == actHunt

proc litBySeeker*(sim: Sim, seeker: int, x, y: int): bool =
  ## The seeker's lit set: everything inside the cone (range + bearing +
  ## sight), plus an omni bubble of `visionBubblePx` with sight.
  let cog = sim.cogs[seeker]
  let sx = cog.px
  let sy = cog.py
  let d2 = dist2(sx, sy, x, y)
  if d2 <= sim.config.visionBubblePx * sim.config.visionBubblePx:
    return sim.hasSight(sx, sy, x, y)
  if d2 > sim.config.lanternRangePx * sim.config.lanternRangePx:
    return false
  let bearing = bearingBrads(x - sx, y - sy)
  if absInt(bradDelta(bearing, cog.aim)) > sim.config.lanternConeBrads:
    return false
  sim.hasSight(sx, sy, x, y)

proc teamLit*(sim: Sim, x, y: int): bool =
  ## The three seekers share one radio: anything one of them lights is in all
  ## three seekers' observations that turn.
  if not sim.lanternsOn():
    return false
  let half = phaseAt(sim.config, sim.tick).half
  for slot in 0 ..< sim.seats:
    if roleOfSlot(slot, half) == roSeeker and sim.litBySeeker(slot, x, y):
      return true
  false

proc beamNear*(sim: Sim, seeker, hx, hy: int): bool =
  ## True when the seeker's lit set covers any point within BeamNearPx of the
  ## hider. Sampled at the hider and at four axis offsets, which is what the
  ## hider's `beams` report is: a bearing and a proximity band, never a
  ## position.
  if not sim.lanternsOn():
    return false
  if sim.litBySeeker(seeker, hx, hy):
    return true
  const offsets = [(BeamNearPx, 0), (-BeamNearPx, 0),
                   (0, BeamNearPx), (0, -BeamNearPx)]
  for (dx, dy) in offsets:
    let x = clampInt(hx + dx, 0, MapWidth - 1)
    let y = clampInt(hy + dy, 0, MapHeight - 1)
    if sim.litBySeeker(seeker, x, y):
      return true
  false

proc nearestUnfoundHider*(sim: Sim, half, fromX, fromY: int): int =
  result = -1
  var best = high(int)
  for slot in 0 ..< sim.seats:
    if roleOfSlot(slot, half) != roHider or sim.cogs[slot].found:
      continue
    let d = dist2(fromX, fromY, sim.cogs[slot].px, sim.cogs[slot].py)
    if d < best:
      best = d
      result = slot

proc hidersLeft*(sim: Sim, half: int): int =
  for slot in 0 ..< sim.seats:
    if roleOfSlot(slot, half) == roHider and not sim.cogs[slot].found:
      inc result

# ---------------------------------------------------------------------------
# Motion (step 6). Paintbot's per-axis integer step: an axis with input
# accelerates and clamps to the cog's top speed, an axis without input decays
# by friction and snaps to zero under StopThreshold.
# ---------------------------------------------------------------------------

proc topSpeed*(role: Role, crawling: bool): int {.inline.} =
  var top = if role == roSeeker: SeekerMaxSpeed else: MaxSpeed
  if crawling:
    top = top * CrawlPercent div 100
  top

proc cogFree(sim: Sim, x, y: int): bool {.inline.} =
  not wallInBox(sim.wallMask, x, y, PlayerHalf)

proc slideAxis(sim: Sim, cog: var Cog, axis: int) =
  ## Move one axis by its velocity, one pixel at a time, sliding along a wall
  ## with a perpendicular scan of up to MovementSlideMaxScan pixels so a cog
  ## never welds itself into a corner.
  let velocity = if axis == 0: cog.vx else: cog.vy
  if velocity == 0:
    return
  let step = signInt(velocity)
  var remaining = absInt(velocity)
  while remaining > 0:
    let bite = min(remaining, MotionScale)
    remaining -= bite
    let before = (if axis == 0: cog.x else: cog.y)
    let after = before + step * bite
    let nx = (if axis == 0: after div MotionScale else: cog.px)
    let ny = (if axis == 0: cog.py else: after div MotionScale)
    if sim.cogFree(nx, ny):
      if axis == 0: cog.x = after else: cog.y = after
      continue
    var slid = false
    for scan in 1 .. MovementSlideMaxScan:
      for direction in [1, -1]:
        let sx = (if axis == 0: nx else: nx + direction * scan)
        let sy = (if axis == 0: ny + direction * scan else: ny)
        if sim.cogFree(sx, sy):
          if axis == 0:
            cog.x = after
            cog.y = sy * MotionScale
          else:
            cog.y = after
            cog.x = sx * MotionScale
          slid = true
          break
      if slid:
        break
    if not slid:
      if axis == 0: cog.vx = 0 else: cog.vy = 0
      return

proc separatePair(sim: Sim, a, b: int) =
  ## Cog-cog overlap, resolved symmetrically so swapping the two slot indices
  ## mirrors the outcome exactly (tests/test_motion.nim asserts it).
  var first = sim.cogs[a]
  var second = sim.cogs[b]
  let boxA = cogBox(first.x, first.y)
  let boxB = cogBox(second.x, second.y)
  if not overlaps(boxA, boxB):
    return
  let dx = first.x - second.x
  let dy = first.y - second.y
  let span = 2 * PlayerHalf + 1
  let overlapX = span * MotionScale - absInt(dx)
  let overlapY = span * MotionScale - absInt(dy)
  if overlapX <= 0 and overlapY <= 0:
    return
  if overlapX <= overlapY:
    let push = (overlapX + 1) div 2
    let dir = (if dx == 0: (if a < b: 1 else: -1) else: signInt(dx))
    first.x += dir * push
    second.x -= dir * push
    let exchange = (first.vx - second.vx) * PlayerBouncePct div 100
    first.vx -= exchange
    second.vx += exchange
  else:
    let push = (overlapY + 1) div 2
    let dir = (if dy == 0: (if a < b: 1 else: -1) else: signInt(dy))
    first.y += dir * push
    second.y -= dir * push
    let exchange = (first.vy - second.vy) * PlayerBouncePct div 100
    first.vy -= exchange
    second.vy += exchange
  if sim.cogFree(first.x div MotionScale, first.y div MotionScale):
    sim.cogs[a] = first
  if sim.cogFree(second.x div MotionScale, second.y div MotionScale):
    sim.cogs[b] = second

# ---------------------------------------------------------------------------
# Sound (step 7 and 13).
# ---------------------------------------------------------------------------

proc addSound(sim: Sim, kind: SoundKind, x, y, radius, jitterPx: int) =
  let at = Point(x: clampInt(x + sim.rng.jitter(jitterPx), 0, MapWidth - 1),
                 y: clampInt(y + sim.rng.jitter(jitterPx), 0, MapHeight - 1))
  sim.sounds.add(SoundRing(kind: kind, at: at, radius: radius, tick: sim.tick))
  sim.emit(soundEvent(sim.tick, kind, at, radius))

proc audibleTo*(sim: Sim, ring: SoundRing, x, y: int): bool {.inline.} =
  dist2(ring.at.x, ring.at.y, x, y) <= ring.radius * ring.radius

# ---------------------------------------------------------------------------
# Keyframes (step 14) and the digest.
# ---------------------------------------------------------------------------

proc appendKeyframe(sim: Sim) =
  let phase = phaseAt(sim.config, sim.tick)
  var frame = Keyframe(t: sim.tick,
                       digest: lanternStateDigest(sim, phase.act == actBuild))
  for slot in 0 ..< sim.seats:
    let cog = sim.cogs[slot]
    let frozen = phase.act == actBuild and roleOfSlot(slot, phase.half) == roSeeker
    frame.cogs.add([cog.px, cog.py, cog.aim, cogStateCode(cog, frozen)])
    frame.hid.add(cog.hiddenTicks)
  for crate in sim.crates:
    frame.crates.add([crate.c.x, crate.c.y, ord(crate.state)])
  for slot in 0 ..< sim.seats:
    if roleOfSlot(slot, phase.half) == roSeeker:
      frame.hb.add(bandCode(sim.cogs[slot].band))
  sim.keyframes.add(frame)

# ---------------------------------------------------------------------------
# Step 1-2: the phase clock. Called before the controls for this tick are
# compiled (live) or read back (replay), so both paths see the same state.
# ---------------------------------------------------------------------------

proc prepareTick*(sim: Sim) =
  if isHalfBoundary(sim.config, sim.tick):
    let ending = sim.tick div halfTicks(sim.config)
    var hidden: seq[int]
    var aliases: seq[string]
    for slot in 0 ..< sim.seats:
      if roleOfSlot(slot, ending) == roHider:
        hidden.add(sim.cogs[slot].hiddenTicks)
        aliases.add(aliasOfSlot(slot))
    sim.emit(halfEndEvent(sim.tick, ending, hidden,
                          sim.huntTicksPlayed[ending - 1], aliases))
    sim.resetHalf(ending + 1)
    var hiders, seekers: seq[string]
    for slot in 0 ..< sim.seats:
      if roleOfSlot(slot, ending + 1) == roHider: hiders.add(aliasOfSlot(slot))
      else: seekers.add(aliasOfSlot(slot))
    sim.emit(halfStartEvent(sim.tick, ending + 1, hiders, seekers))
    sim.emit(actStartEvent(sim.tick, ending + 1, actBuild))
  if sim.tick mod ReplayFps == 0:
    sim.appendKeyframe()

# ---------------------------------------------------------------------------
# Steps 5-15.
# ---------------------------------------------------------------------------

proc applyTick*(sim: Sim, controls: openArray[Control]) =
  let config = sim.config
  let phase = phaseAt(config, sim.tick)
  let half = phase.half
  var moved = newSeq[Point](sim.seats)

  # ---- 2 / 5 / 6: frozen seats, aim, motion ------------------------------
  for slot in 0 ..< sim.seats:
    let role = roleOfSlot(slot, half)
    let frozen = phase.act == actBuild and role == roSeeker
    var cog = sim.cogs[slot]
    let before = Point(x: cog.x, y: cog.y)
    if frozen or cog.found:
      cog.vx = 0
      cog.vy = 0
      cog.crawling = false
      sim.cogs[slot] = cog
      moved[slot] = Point(x: 0, y: 0)
      continue
    let control = controls[slot]
    cog.crawling = (control.action and 0b100'u8) != 0
    cog.aim = (cog.aim + int(control.aimTurn)) and 255
    let top = topSpeed(role, cog.crawling)
    let accel = (if cog.crawling: Accel div 2 else: Accel)
    if control.moveX != 0:
      cog.vx = clampInt(cog.vx + int(control.moveX) * accel div 100, -top, top)
    else:
      cog.vx = cog.vx * FrictionNum div FrictionDen
      if absInt(cog.vx) < StopThreshold:
        cog.vx = 0
    if control.moveY != 0:
      cog.vy = clampInt(cog.vy + int(control.moveY) * accel div 100, -top, top)
    else:
      cog.vy = cog.vy * FrictionNum div FrictionDen
      if absInt(cog.vy) < StopThreshold:
        cog.vy = 0
    if absInt(cog.vx) > top: cog.vx = signInt(cog.vx) * top
    if absInt(cog.vy) > top: cog.vy = signInt(cog.vy) * top
    sim.cogs[slot] = cog
    sim.slideAxis(sim.cogs[slot], 0)
    sim.slideAxis(sim.cogs[slot], 1)
    moved[slot] = Point(x: sim.cogs[slot].x - before.x,
                        y: sim.cogs[slot].y - before.y)

  for a in 0 ..< sim.seats:
    for b in a + 1 ..< sim.seats:
      sim.separatePair(a, b)

  # ---- 7: crates ---------------------------------------------------------
  for crateIndex in 0 ..< sim.crates.len:
    if sim.crates[crateIndex].state == csBroken:
      continue
    for slot in 0 ..< sim.seats:
      let role = roleOfSlot(slot, half)
      if phase.act == actBuild and role == roSeeker:
        continue
      var cog = sim.cogs[slot]
      if cog.found:
        continue
      let body = cogBox(cog.x, cog.y)
      if not overlaps(body, crateRect(sim.crates[crateIndex])):
        continue
      let dx = moved[slot].x
      let dy = moved[slot].y
      let axis = if absInt(dx) >= absInt(dy): 0 else: 1
      let delta = if axis == 0: dx else: dy
      var pushed = false
      if sim.crates[crateIndex].state == csLoose and not cog.crawling and
          delta != 0:
        let distance = signInt(delta) * pushDistance(role)
        let target =
          if axis == 0:
            crateRectAt(sim.crates[crateIndex].c.x + distance,
                        sim.crates[crateIndex].c.y)
          else:
            crateRectAt(sim.crates[crateIndex].c.x,
                        sim.crates[crateIndex].c.y + distance)
        var others: seq[Rect]
        for other in 0 ..< sim.seats:
          if other != slot:
            others.add(cogBox(sim.cogs[other].x, sim.cogs[other].y))
        if crateBoxFree(sim.crates, sim.wallMask, target, crateIndex, others):
          let fromPos = sim.crates[crateIndex].c
          if axis == 0: sim.crates[crateIndex].c.x += distance
          else: sim.crates[crateIndex].c.y += distance
          sim.blockDirty = true
          pushed = true
          inc sim.cogs[slot].cratesPushed
          sim.emit(cratePushEvent(sim.tick, slot, aliasOfSlot(slot),
                                  crateId(crateIndex), fromPos,
                                  sim.crates[crateIndex].c))
          if sim.tick - sim.crates[crateIndex].lastPushTick >=
              PushSoundEveryTicks:
            sim.crates[crateIndex].lastPushTick = sim.tick
            sim.addSound(sndPush, sim.crates[crateIndex].c.x,
                         sim.crates[crateIndex].c.y, PushSoundPx, PushJitterPx)
      if not pushed:
        ## The crate is solid: revert the pusher along the dominant axis.
        if axis == 0:
          sim.cogs[slot].x = sim.cogs[slot].x - dx
          sim.cogs[slot].vx = 0
        else:
          sim.cogs[slot].y = sim.cogs[slot].y - dy
          sim.cogs[slot].vy = 0

  # ---- 8: lock and pry ---------------------------------------------------
  for slot in 0 ..< sim.seats:
    let role = roleOfSlot(slot, half)
    var cog = sim.cogs[slot]
    if cog.found or (phase.act == actBuild and role == roSeeker):
      cog.lockProgress = 0
      cog.pryProgress = 0
      sim.cogs[slot] = cog
      continue
    let control = controls[slot]
    let still = absInt(cog.vx) < StopThreshold and absInt(cog.vy) < StopThreshold
    let wantLock = (control.action and 0b1'u8) != 0 and role == roHider
    let wantPry = (control.action and 0b10'u8) != 0 and role == roSeeker
    if wantLock and still and not lockRefused(cog, config):
      var target = -1
      for index, crate in sim.crates:
        if crate.state == csLoose and
            touchesCrate(crate, cog.px, cog.py, InteractRangePx):
          target = index
          break
      if target < 0:
        cog.lockProgress = 0
        cog.lockTarget = -1
      else:
        if cog.lockTarget != target:
          cog.lockTarget = target
          cog.lockProgress = 0
        inc cog.lockProgress
        if cog.lockProgress >= config.lockTicks:
          sim.crates[target].state = csLocked
          sim.blockDirty = true
          inc cog.locksUsed
          inc cog.cratesLocked
          cog.lockProgress = 0
          cog.lockTarget = -1
          sim.emit(crateLockEvent(sim.tick, slot, aliasOfSlot(slot),
                                  crateId(target), sim.crates[target].c))
    else:
      cog.lockProgress = 0
      cog.lockTarget = -1
    if wantPry and still:
      var target = -1
      for index, crate in sim.crates:
        if crate.state == csLocked and
            touchesCrate(crate, cog.px, cog.py, InteractRangePx):
          target = index
          break
      if target < 0:
        cog.pryProgress = 0
        cog.pryTarget = -1
      else:
        if cog.pryTarget != target:
          cog.pryTarget = target
          cog.pryProgress = 0
        let before = cog.pryProgress * 100 div config.pryTicks
        inc cog.pryProgress
        let after = cog.pryProgress * 100 div config.pryTicks
        for mark in [25, 50, 75]:
          if before < mark and after >= mark:
            sim.emit(cratePryEvent(sim.tick, slot, aliasOfSlot(slot),
                                   crateId(target), mark))
        if cog.pryProgress >= config.pryTicks:
          sim.crates[target].state = csBroken
          sim.blockDirty = true
          inc cog.cratesBroken
          cog.pryProgress = 0
          cog.pryTarget = -1
          sim.emit(crateBreakEvent(sim.tick, slot, aliasOfSlot(slot),
                                   crateId(target), sim.crates[target].c))
          sim.addSound(sndBreak, sim.crates[target].c.x, sim.crates[target].c.y,
                       BreakSoundPx, BreakJitterPx)
    else:
      cog.pryProgress = 0
      cog.pryTarget = -1
    sim.cogs[slot] = cog

  # ---- footstep rings ----------------------------------------------------
  for slot in 0 ..< sim.seats:
    let role = roleOfSlot(slot, half)
    let cog = sim.cogs[slot]
    if cog.found or cog.crawling or (phase.act == actBuild and role == roSeeker):
      continue
    let top = topSpeed(role, false)
    let speed2 = cog.vx * cog.vx + cog.vy * cog.vy
    if speed2 * 4 <= top * top:
      continue
    if sim.tick - cog.lastStepSoundTick < StepSoundEveryTicks:
      continue
    sim.cogs[slot].lastStepSoundTick = sim.tick
    sim.addSound(sndStep, cog.px, cog.py, StepSoundPx, StepJitterPx)

  # ---- 9: occlusion rebake ----------------------------------------------
  if sim.blockDirty:
    sim.rebake()

  # ---- 10-12: lanterns, detection, score accrual -------------------------
  if phase.act == actHunt:
    for slot in 0 ..< sim.seats:
      if roleOfSlot(slot, half) != roHider or sim.cogs[slot].found:
        continue
      var cog = sim.cogs[slot]
      var litBy = -1
      for other in 0 ..< sim.seats:
        if roleOfSlot(other, half) == roSeeker and
            sim.litBySeeker(other, cog.px, cog.py):
          litBy = other
          break
      if litBy >= 0:
        inc cog.litStreak
        sim.cogs[litBy].lastLit = Point(x: cog.px, y: cog.py)
        sim.cogs[litBy].lastLitTick = sim.tick
        if cog.litStreak == 1:
          sim.emit(spotEvent(sim.tick, aliasOfSlot(litBy), aliasOfSlot(slot),
                             distPx(sim.cogs[litBy].px, sim.cogs[litBy].py,
                                    cog.px, cog.py)))
      else:
        cog.litStreak = 0
      var mode = ""
      var finder = -1
      if litBy >= 0 and cog.litStreak >= config.lockOnTicks:
        mode = "beam"
        finder = litBy
      else:
        for other in 0 ..< sim.seats:
          if roleOfSlot(other, half) != roSeeker:
            continue
          let seeker = sim.cogs[other]
          if dist2(seeker.px, seeker.py, cog.px, cog.py) <=
              TouchTagPx * TouchTagPx and
              sim.hasSight(seeker.px, seeker.py, cog.px, cog.py):
            mode = "tag"
            finder = other
            break
      if finder >= 0:
        cog.found = true
        cog.foundTick = sim.tick
        cog.litStreak = 0
        let index = indexInTeam(slot)
        cog.x = (sim.map.caughtPen.x + 24 * index) * MotionScale
        cog.y = sim.map.caughtPen.y * MotionScale
        cog.vx = 0
        cog.vy = 0
        sim.cogs[slot] = cog
        inc sim.cogs[finder].finds
        sim.emit(foundEvent(sim.tick, half, aliasOfSlot(slot),
                            aliasOfSlot(finder), mode, cog.hiddenTicks,
                            sim.hidersLeft(half)))
      else:
        inc cog.hiddenTicks
        sim.cogs[slot] = cog
    inc sim.huntTicksPlayed[half - 1]

  # ---- 13: heartbeat and sound decay -------------------------------------
  for slot in 0 ..< sim.seats:
    if roleOfSlot(slot, half) != roSeeker:
      continue
    var nearest = high(int)
    for other in 0 ..< sim.seats:
      if roleOfSlot(other, half) != roHider or sim.cogs[other].found:
        continue
      let d = distPx(sim.cogs[slot].px, sim.cogs[slot].py,
                     sim.cogs[other].px, sim.cogs[other].py)
      if d < nearest:
        nearest = d
    sim.cogs[slot].band =
      if phase.act != actHunt or nearest == high(int): bdCold
      else: bandFor(nearest)
  var live: seq[SoundRing]
  for ring in sim.sounds:
    if sim.tick - ring.tick < SoundLifeTicks:
      live.add(ring)
  sim.sounds = live

  # ---- 15: act / half / match end ----------------------------------------
  let next = sim.tick + 1
  let span = halfTicks(config)
  if phase.act == actBuild and next mod span == config.prepTicks:
    sim.emit(actEndEvent(next, half, actBuild, "time"))
    sim.emit(actStartEvent(next, half, actHunt))
    sim.doorSolid = false
    sim.rebake()
  if phase.act == actHunt and not sim.actEnded[half - 1] and
      sim.hidersLeft(half) == 0:
    sim.actEnded[half - 1] = true
    sim.emit(actEndEvent(next, half, actHunt, "all_found"))
  elif phase.act == actHunt and next mod span == 0 and
      not sim.actEnded[half - 1]:
    sim.actEnded[half - 1] = true
    sim.emit(actEndEvent(next, half, actHunt, "time"))
  sim.tick = next
  if sim.tick >= totalTicks(config):
    sim.finished = true

proc checkInvariants*(sim: Sim) =
  ## The sim-fault guard. A tripped invariant ends the episode
  ## `fault/sim_fault` with 0.5 for every seat and a partial replay, which is
  ## an honest "the game broke" rather than a silently wrong score.
  for slot in 0 ..< sim.seats:
    let cog = sim.cogs[slot]
    if cog.px < 0 or cog.py < 0 or cog.px >= MapWidth or cog.py >= MapHeight:
      raise newException(LanternError,
        "cog " & $slot & " left the arena at (" & $cog.px & "," & $cog.py & ")")
    if cog.hiddenTicks < 0:
      raise newException(LanternError,
        "cog " & $slot & " has a negative hidden-tick count")
  for index, crate in sim.crates:
    if crate.state == csBroken:
      continue
    if wallInRect(sim.wallMask, crateRect(crate)):
      raise newException(LanternError,
        "crate C" & $index & " overlaps a wall at (" & $crate.c.x & "," &
        $crate.c.y & ")")

proc runTick*(sim: Sim, controls: openArray[Control]) =
  sim.prepareTick()
  sim.applyTick(controls)
