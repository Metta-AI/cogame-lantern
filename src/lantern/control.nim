## The control layer: the deterministic reflexes that execute an order.
##
## The LLM is the tactician at 0.2 Hz; this is the driver at 24 Hz. LLM
## orders and scripted orders are compiled by the SAME code, so the two
## policy kinds are strictly comparable and the recorded control bytes are
## the whole truth about what a cog did.
##
## There is no pathfinder. A target chosen behind a wall is a bad order, and
## that is part of the skill; the unstick rule only guarantees a cog never
## welds itself into a corner.
##
## Integer only — this is on the sim path.

import types, arena, crates, rules, sim, labels

const
  ArriveEpsilonPx = 8
  BehindSlackPx = 10
  FleeReachPx = 200
  SweepPeriod = 96          ## 4 s triangle: +24 ticks, -48, +24
  SweepSeatOffset = 16

proc crateEdgePoint(crate: Crate, fromX, fromY: int): Point =
  ## The midpoint of the crate edge nearest the cog.
  let box = crateRect(crate)
  let left = absInt(fromX - box.x)
  let right = absInt(fromX - (box.x + box.w))
  let top = absInt(fromY - box.y)
  let bottom = absInt(fromY - (box.y + box.h))
  var best = left
  var point = Point(x: box.x - PlayerHalf - 1, y: crate.c.y)
  if right < best:
    best = right
    point = Point(x: box.x + box.w + PlayerHalf + 1, y: crate.c.y)
  if top < best:
    best = top
    point = Point(x: crate.c.x, y: box.y - PlayerHalf - 1)
  if bottom < best:
    best = bottom
    point = Point(x: crate.c.x, y: box.y + box.h + PlayerHalf + 1)
  Point(x: clampInt(point.x, 1, MapWidth - 2),
        y: clampInt(point.y, 1, MapHeight - 2))

proc threatPoint(sim: Sim, slot, half: int): Point =
  ## What a hider is fleeing FROM: the nearest seen seeker, else the source
  ## of the nearest reported beam, else the nearest heard ring, else the map
  ## centre. Recomputed every tick, as the design note requires.
  let me = sim.cogs[slot]
  var best = high(int)
  var found = false
  var point = Point(x: MapWidth div 2, y: MapHeight div 2)
  for other in 0 ..< sim.seats:
    if roleOfSlot(other, half) != roSeeker:
      continue
    let seeker = sim.cogs[other]
    let d = dist2(me.px, me.py, seeker.px, seeker.py)
    if d <= SeekerSeenPx * SeekerSeenPx and
        sim.hasSight(me.px, me.py, seeker.px, seeker.py) and d < best:
      best = d
      found = true
      point = Point(x: seeker.px, y: seeker.py)
  if not found:
    for other in 0 ..< sim.seats:
      if roleOfSlot(other, half) != roSeeker:
        continue
      if sim.beamNear(other, me.px, me.py):
        let seeker = sim.cogs[other]
        let d = dist2(me.px, me.py, seeker.px, seeker.py)
        if d < best:
          best = d
          found = true
          point = Point(x: seeker.px, y: seeker.py)
  if not found:
    for ring in sim.sounds:
      if ring.kind != sndBreak:
        continue
      let d = dist2(me.px, me.py, ring.at.x, ring.at.y)
      if d < best:
        best = d
        found = true
        point = ring.at
  point

proc newestRing(sim: Sim, kinds: set[SoundKind], px, py: int,
                heard: var bool): Point =
  heard = false
  var newest = -1
  var point = Point(x: px, y: py)
  for ring in sim.sounds:
    if ring.kind notin kinds:
      continue
    if not sim.audibleTo(ring, px, py):
      continue
    if ring.tick > newest:
      newest = ring.tick
      heard = true
      point = ring.at
  point

proc litHiderPoint(sim: Sim, slot, half: int, found: var bool): Point =
  found = false
  var best = high(int)
  var point = Point(x: 0, y: 0)
  let me = sim.cogs[slot]
  for other in 0 ..< sim.seats:
    if roleOfSlot(other, half) != roHider or sim.cogs[other].found:
      continue
    let hider = sim.cogs[other]
    if not sim.teamLit(hider.px, hider.py):
      continue
    let d = dist2(me.px, me.py, hider.px, hider.py)
    if d < best:
      best = d
      found = true
      point = Point(x: hider.px, y: hider.py)
  point

proc steeringPoint(sim: Sim, slot, half: int, role: Role,
                   wantLock, wantPry: var bool): Point =
  let cog = sim.cogs[slot]
  let here = Point(x: cog.px, y: cog.py)
  let order = cog.order
  wantLock = false
  wantPry = false
  case order.intent
  of inPush:
    ## Get behind the crate, then shove it at the target. A crate only ever
    ## moves along the DOMINANT axis of the pusher's displacement, so the
    ## staging point is axis-aligned: standing diagonally behind a crate and
    ## leaning on it moves it in whichever direction happens to win the tick.
    ##
    ## A cog on the WRONG side of the crate cannot walk to the staging point
    ## through the crate — it would shove it the wrong way the whole trip —
    ## so it swings wide around the corner first. This is the note's
    ## "get behind the crate, else steer at the target" rule with the
    ## approach made axis-aligned and the wrong-side case spelled out;
    ## without it a pusher plows its own crate away from the target.
    if order.crate < 0 or order.crate >= sim.crates.len:
      return order.target
    let centre = sim.crates[order.crate].c
    let deltaX = order.target.x - centre.x
    let deltaY = order.target.y - centre.y
    let axisX = absInt(deltaX) >= absInt(deltaY)
    let dir = signInt(if axisX: deltaX else: deltaY)
    if dir == 0:
      return order.target
    let standOff = CrateHalf + PlayerHalf + 3
    let clearance = CrateHalf + PlayerHalf + 12
    let behind =
      if axisX: Point(x: centre.x - dir * standOff, y: centre.y)
      else: Point(x: centre.x, y: centre.y - dir * standOff)
    let mine = (if axisX: here.x else: here.y)
    let theirs = (if axisX: centre.x else: centre.y)
    let onSide = signInt(mine - theirs) == -dir
    if onSide:
      if distPx(here.x, here.y, behind.x, behind.y) > BehindSlackPx:
        Point(x: clampInt(behind.x, 1, MapWidth - 2),
              y: clampInt(behind.y, 1, MapHeight - 2))
      else:
        order.target
    else:
      let sideways =
        if axisX: (if signInt(here.y - centre.y) == 0: 1
                   else: signInt(here.y - centre.y))
        else: (if signInt(here.x - centre.x) == 0: 1
               else: signInt(here.x - centre.x))
      let corner =
        if axisX: Point(x: centre.x - dir * standOff,
                        y: centre.y + sideways * clearance)
        else: Point(x: centre.x + sideways * clearance,
                    y: centre.y - dir * standOff)
      Point(x: clampInt(corner.x, 1, MapWidth - 2),
            y: clampInt(corner.y, 1, MapHeight - 2))
  of inLock, inPry:
    if order.crate < 0 or order.crate >= sim.crates.len:
      return order.target
    let edge = crateEdgePoint(sim.crates[order.crate], here.x, here.y)
    if touchesCrate(sim.crates[order.crate], here.x, here.y, InteractRangePx):
      if order.intent == inLock: wantLock = true else: wantPry = true
      here
    else:
      edge
  of inFlee:
    let threat = threatPoint(sim, slot, half)
    let away = scaleTo(here.x - threat.x, here.y - threat.y, FleeReachPx)
    if away.x == 0 and away.y == 0:
      order.target
    else:
      Point(x: clampInt(here.x + away.x, 1, MapWidth - 2),
            y: clampInt(here.y + away.y, 1, MapHeight - 2))
  of inChase:
    var lit = false
    let point = litHiderPoint(sim, slot, half, lit)
    if lit:
      point
    elif cog.lastLitTick >= 0:
      cog.lastLit
    else:
      order.target
  of inWait:
    here
  else:
    ## hide / scout / hold / beeline / sweep all steer straight at the target.
    order.target

proc aimTurnFor(sim: Sim, slot, half: int, role: Role, target: Point): int =
  let cog = sim.cogs[slot]
  if role == roHider:
    ## Hiders carry no lantern; their aim only matters for the sprite, so it
    ## tracks where they are going and never sweeps.
    return clampInt(bradDelta(bearingBrads(target.x - cog.px,
                                           target.y - cog.py), cog.aim),
                    -AimTurnRate, AimTurnRate)
  ## HOLD-ON-CONTACT REFLEX. The order-level aim mode is a 5 s intention; a
  ## beam is lost in a fifth of that. A swept beam crosses a body in about
  ## 36 / aimTurnRate = 7 ticks, which is less than lockOnTicks, so without
  ## this reflex a sweeping seeker could NEVER hold a hider in the beam long
  ## enough to find one and the whole spot -> found path would be dead. So
  ## whenever a hider is lit RIGHT NOW, the aim turns onto it, whatever the
  ## order said — except under `hold`, which is the explicit "do not move the
  ## beam" instruction. It keys on the TEAM's lit set, not this seeker's own
  ## lantern, because the detection streak is itself team-wide
  ## (`sim.applyTick` step 11 counts a hider as lit if ANY seeker lights it):
  ## holding a contact is a team job, so all three swing onto the hider the
  ## moment one of them lights it.
  if cog.order.aim != amHold:
    var litNow = false
    let point = litHiderPoint(sim, slot, half, litNow)
    if litNow:
      return clampInt(bradDelta(bearingBrads(point.x - cog.px,
                                             point.y - cog.py), cog.aim),
                      -AimTurnRate, AimTurnRate)
  case cog.order.aim
  of amHold:
    0
  of amSweep:
    let phase = (sim.tick + slot * SweepSeatOffset) mod SweepPeriod
    if phase < 24: AimTurnRate
    elif phase < 72: -AimTurnRate
    else: AimTurnRate
  of amTrack:
    var heard = false
    let ring = newestRing(sim, {sndStep, sndPush, sndBreak},
                          cog.px, cog.py, heard)
    let point = (if heard: ring else: target)
    clampInt(bradDelta(bearingBrads(point.x - cog.px, point.y - cog.py),
                       cog.aim), -AimTurnRate, AimTurnRate)
  of amTarget:
    clampInt(bradDelta(bearingBrads(target.x - cog.px, target.y - cog.py),
                       cog.aim), -AimTurnRate, AimTurnRate)

proc compileControl*(sim: Sim, slot, half: int): Control =
  ## Steps 3 and 4 of the resolution order: read the world and the seat's
  ## active order, produce (move_x, move_y, aim_turn, action), quantised.
  let role = roleOfSlot(slot, half)
  let phase = phaseAt(sim.config, sim.tick)
  if sim.cogs[slot].found or (phase.act == actBuild and role == roSeeker):
    return Control()
  var wantLock, wantPry = false
  let target = steeringPoint(sim, slot, half, role, wantLock, wantPry)
  var cog = sim.cogs[slot]
  var dx = target.x - cog.px
  var dy = target.y - cog.py
  var moveX = 0
  var moveY = 0
  if dx * dx + dy * dy > ArriveEpsilonPx * ArriveEpsilonPx:
    var bearing = bearingBrads(dx, dy)
    if cog.unstickRot != 0:
      bearing = (bearing + cog.unstickRot * 32) and 255
    let vector = aimVector(bearing)
    moveX = clampInt(vector.x * 100 div UnitScale, -100, 100)
    moveY = clampInt(vector.y * 100 div UnitScale, -100, 100)

  ## Unstick: a cog that has moved less than UnstickPx in the last 24 ticks
  ## while asking to move rotates its command by an eighth of a turn, once
  ## per 24 ticks, until it comes free.
  if sim.tick - cog.unstickTick >= UnstickTicks:
    let travelled = distPx(cog.x div MotionScale, cog.y div MotionScale,
                           cog.unstickAnchorX div MotionScale,
                           cog.unstickAnchorY div MotionScale)
    if (moveX != 0 or moveY != 0) and travelled < UnstickPx:
      cog.unstickRot = (cog.unstickRot + 1) and 7
    else:
      cog.unstickRot = 0
    cog.unstickAnchorX = cog.x
    cog.unstickAnchorY = cog.y
    cog.unstickTick = sim.tick
  sim.cogs[slot] = cog

  result.moveX = int8(moveX)
  result.moveY = int8(moveY)
  result.aimTurn = int8(clampInt(aimTurnFor(sim, slot, half, role, target),
                                 -AimTurnRate, AimTurnRate))
  var action = 0'u8
  if wantLock: action = action or 0b1'u8
  if wantPry: action = action or 0b10'u8
  let pushing = cog.order.intent == inPush and cog.order.crate >= 0 and
    cog.order.crate < sim.crates.len and
    touchesCrate(sim.crates[cog.order.crate], cog.px, cog.py, InteractRangePx)
  if cog.order.crawl and not pushing and role == roHider:
    action = action or 0b100'u8
  result.action = action

proc compileControls*(sim: Sim): seq[Control] =
  let half = phaseAt(sim.config, sim.tick).half
  result = newSeq[Control](sim.seats)
  for slot in 0 ..< sim.seats:
    result[slot] = compileControl(sim, slot, half)
