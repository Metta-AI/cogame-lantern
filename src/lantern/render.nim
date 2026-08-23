## The per-seat view: exactly what a seat can see, and nothing else.
##
## Two shapes, one per role. A hider knows the fort it built (all ten crate
## positions and states) and sees seekers only within 700 px with sight; a
## seeker sees only what the team's three lanterns currently light, plus the
## sound rings it can hear and its own heartbeat band.
##
## Hidden from EVERYONE, both roles: the opponent's prompts, notes and `say`
## strings (they exist only in the replay, for spectators), the real player
## names behind the aliases, and future ticks.

import std/json
import types, crates, rules, sim, orders, labels

proc mapBlock*(map: MapSpec): JsonNode =
  ## Static geometry is NOT secret: the warehouse blueprint is in every
  ## seat's observation, both roles, always. What the dark hides is where the
  ## crates ended up and where the bodies are.
  var walls = newJArray()
  for rect in map.obstacles:
    walls.add(%[rect.x, rect.y, rect.w, rect.h])
  var nooks = newJArray()
  for nook in map.nooks:
    nooks.add(%*{"anchor": [nook.anchor.x, nook.anchor.y],
                 "opening": [[nook.openA.x, nook.openA.y],
                             [nook.openB.x, nook.openB.y]]})
  %*{"w": map.width, "h": map.height, "walls": walls, "nooks": nooks,
     "pen": [map.pen.x, map.pen.y, map.pen.w, map.pen.h]}

proc clockBlock(sim: Sim, phase: Phase, role: Role): JsonNode =
  result = %*{"act_left_s": phase.actLeft.float / TargetFps.float}
  if role == roHider and phase.act == actBuild:
    result["hunt_left_s"] = %(sim.config.huntTicks.float / TargetFps.float)

proc crateList(sim: Sim): JsonNode =
  result = newJArray()
  for index, crate in sim.crates:
    result.add(%*{"id": crateId(index), "pos": [crate.c.x, crate.c.y],
                  "state": $crate.state})

proc lastOrderJson(cog: Cog): JsonNode =
  if cog.hasOrder: orderJson(cog.order) else: newJNull()

proc hiderView*(sim: Sim, slot: int): JsonNode =
  let config = sim.config
  let phase = phaseAt(config, sim.tick)
  let me = sim.cogs[slot]
  var team = newJArray()
  for other in 0 ..< sim.seats:
    if roleOfSlot(other, phase.half) != roHider:
      continue
    let mate = sim.cogs[other]
    team.add(%*{"alias": aliasOfSlot(other), "pos": [mate.px, mate.py],
                "found": mate.found,
                "hidden_s": mate.hiddenTicks.float / TargetFps.float})
  var seen = newJArray()
  var beams = newJArray()
  for other in 0 ..< sim.seats:
    if roleOfSlot(other, phase.half) != roSeeker:
      continue
    let seeker = sim.cogs[other]
    let distance = distPx(me.px, me.py, seeker.px, seeker.py)
    if distance <= SeekerSeenPx and
        sim.hasSight(me.px, me.py, seeker.px, seeker.py):
      seen.add(%*{"alias": aliasOfSlot(other), "pos": [seeker.px, seeker.py],
                  "aim": seeker.aim, "dist": distance})
    if sim.beamNear(other, me.px, me.py):
      ## A beam is reported as a BEARING and a band, never as a position:
      ## the hider knows a light is sweeping toward it, not where from.
      beams.add(%*{"bearing": bearingBrads(seeker.px - me.px,
                                           seeker.py - me.py),
                   "band": (if distance <= BeamNearPx: "near"
                            elif distance <= BandWarmPx: "mid" else: "far")})
  var sounds = newJArray()
  for ring in sim.sounds:
    ## Hiders hear only break rings; footsteps and pushes are their own noise.
    if ring.kind != sndBreak or not sim.audibleTo(ring, me.px, me.py):
      continue
    sounds.add(%*{"kind": $ring.kind, "pos": [ring.at.x, ring.at.y],
                  "age_ticks": sim.tick - ring.tick})
  var foundCount = 0
  for other in 0 ..< sim.seats:
    if roleOfSlot(other, phase.half) == roHider and sim.cogs[other].found:
      inc foundCount
  %*{"turn": phase.turn, "of": totalTurns(config), "half": phase.half,
     "act": $phase.act,
     "clock": clockBlock(sim, phase, roHider),
     "you": {"alias": aliasOfSlot(slot), "pos": [me.px, me.py], "aim": me.aim,
             "crawl": me.crawling, "found": me.found,
             "hidden_s": me.hiddenTicks.float / TargetFps.float,
             "locks_left": max(0, config.maxLocksPerHider - me.locksUsed)},
     "map": mapBlock(sim.map),
     "crates": crateList(sim),
     "team": team,
     "seekers_seen": seen,
     "beams": beams,
     "sounds": sounds,
     "found_count": foundCount,
     "your_last_order": lastOrderJson(me)}

proc seekerView*(sim: Sim, slot: int): JsonNode =
  let config = sim.config
  let phase = phaseAt(config, sim.tick)
  let me = sim.cogs[slot]
  var litCrates = newJArray()
  for index, crate in sim.crates:
    if crate.state == csBroken:
      continue
    if not sim.teamLit(crate.c.x, crate.c.y):
      continue
    litCrates.add(%*{"id": crateId(index), "pos": [crate.c.x, crate.c.y],
                     "state": $crate.state})
  var litHiders = newJArray()
  var found = newJArray()
  var left = 0
  for other in 0 ..< sim.seats:
    if roleOfSlot(other, phase.half) != roHider:
      continue
    let hider = sim.cogs[other]
    if hider.found:
      found.add(%*{"alias": aliasOfSlot(other),
                   "at_s": hider.foundTick.float / TargetFps.float})
      continue
    inc left
    var by = ""
    for other2 in 0 ..< sim.seats:
      if roleOfSlot(other2, phase.half) == roSeeker and
          sim.litBySeeker(other2, hider.px, hider.py):
        by = aliasOfSlot(other2)
        break
    if by.len > 0:
      litHiders.add(%*{"alias": aliasOfSlot(other), "pos": [hider.px, hider.py],
                       "lit_by": by, "streak_ticks": hider.litStreak})
  var team = newJArray()
  for other in 0 ..< sim.seats:
    if roleOfSlot(other, phase.half) != roSeeker:
      continue
    let mate = sim.cogs[other]
    team.add(%*{"alias": aliasOfSlot(other), "pos": [mate.px, mate.py],
                "aim": mate.aim, "heartbeat": $mate.band})
  var sounds = newJArray()
  for ring in sim.sounds:
    if not sim.audibleTo(ring, me.px, me.py):
      continue
    sounds.add(%*{"kind": $ring.kind, "pos": [ring.at.x, ring.at.y],
                  "age_ticks": sim.tick - ring.tick})
  %*{"turn": phase.turn, "of": totalTurns(config), "half": phase.half,
     "act": $phase.act,
     "clock": clockBlock(sim, phase, roSeeker),
     "you": {"alias": aliasOfSlot(slot), "pos": [me.px, me.py], "aim": me.aim,
             "heartbeat": $me.band,
             "prying": (if me.pryTarget >= 0: %crateId(me.pryTarget)
                        else: newJNull())},
     "map": mapBlock(sim.map),
     "lit": {"crates": litCrates, "hiders": litHiders},
     "team": team,
     "sounds": sounds,
     "found": found,
     "found_count": found.len,
     "hiders_left": left,
     "your_last_order": lastOrderJson(me)}

proc seatView*(sim: Sim, slot: int): JsonNode =
  let half = phaseAt(sim.config, sim.tick).half
  if roleOfSlot(slot, half) == roHider: hiderView(sim, slot)
  else: seekerView(sim, slot)
