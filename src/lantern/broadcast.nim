## The spectator stream.
##
## `/global` serves a whole-world snapshot (nothing is hidden from a
## spectator: that is the point of the second name space) and the same shape
## is what `client/replay_broadcast.html` draws from when the game server
## hosts a local viewing of a replay. Hosted replays never touch this — they
## are the static wasm bundle, fed from S3.

import std/[base64, json]
import types, config, sim, rules, render, labels

proc cogsJson*(sim: Sim, half: int): JsonNode =
  result = newJArray()
  for slot in 0 ..< sim.seats:
    let cog = sim.cogs[slot]
    result.add(%*{
      "slot": slot,
      "alias": aliasOfSlot(slot),
      "team": $teamOfSlot(slot),
      "role": $roleOfSlot(slot, half),
      "pos": [cog.px, cog.py],
      "aim": cog.aim,
      "crawl": cog.crawling,
      "found": cog.found,
      "hidden_ticks": cog.hiddenTicks,
      "locks_used": cog.locksUsed,
      "heartbeat": $cog.band,
      "intent": $cog.order.intent,
      "note": cog.order.note,
      "say": cog.order.say,
      "source": $cog.orderSource})

proc cratesJson*(sim: Sim): JsonNode =
  result = newJArray()
  for index, crate in sim.crates:
    result.add(%*{"id": "C" & $index, "pos": [crate.c.x, crate.c.y],
                  "state": $crate.state})

proc soundsJson*(sim: Sim): JsonNode =
  result = newJArray()
  for ring in sim.sounds:
    result.add(%*{"kind": $ring.kind, "pos": [ring.at.x, ring.at.y],
                  "radius": ring.radius, "age_ticks": sim.tick - ring.tick})

# ---- the frame packet ------------------------------------------------------
# ONE shape for both viewers: the wasm replay module serves it per tick, and
# the live /global snapshot carries it as `frame`, so client/global.html and
# the static bundle draw with the same broadcast_core.js off the same data.

proc litMaskBytes*(sim: Sim): seq[uint8] =
  ## The seekers' lit set on the FovCell grid, one byte per cell: exactly
  ## `teamLit` at the cell centre, so a renderer that masks its light with
  ## this paints the same occlusion the detection rule sees.
  result = newSeq[uint8](FovW * FovH)
  if not sim.lanternsOn():
    return
  for cy in 0 ..< FovH:
    let y = min(cy * FovCell + FovCell div 2, MapHeight - 1)
    for cx in 0 ..< FovW:
      let x = min(cx * FovCell + FovCell div 2, MapWidth - 1)
      if sim.teamLit(x, y):
        result[cy * FovW + cx] = 1

proc litMaskB64*(mask: seq[uint8]): string =
  ## Bit-packed, LSB first, for the live socket (12 865 cells -> ~2 KB).
  var packed = newString((mask.len + 7) div 8)
  for index, value in mask:
    if value != 0:
      packed[index shr 3] = char(uint8(packed[index shr 3]) or (1'u8 shl (index and 7)))
  encode(packed)

proc framePacket*(sim: Sim, bursts: seq[array[2, int]]): JsonNode =
  let tickCount = totalTicks(sim.config)
  let phase = phaseAt(sim.config, min(sim.tick, tickCount - 1))
  var cogs = newJArray()
  var hb = newJArray()
  var hidden = [0, 0]
  var left = 0
  for slot in 0 ..< sim.seats:
    let cog = sim.cogs[slot]
    let role = roleOfSlot(slot, phase.half)
    let frozen = phase.act == actBuild and role == roSeeker
    if teamOfSlot(slot) == tmMoth: hidden[0] += cog.hiddenTicks
    else: hidden[1] += cog.hiddenTicks
    if role == roHider and not cog.found:
      inc left
    cogs.add(%*{
      "alias": aliasOfSlot(slot), "team": $teamOfSlot(slot), "role": $role,
      "x": cog.px, "y": cog.py, "aim": cog.aim,
      "state": (if cog.found: 3 elif frozen: 1 elif cog.crawling: 2 else: 0),
      "lit": (role == roHider and not cog.found and
              sim.teamLit(cog.px, cog.py))})
    if role == roSeeker:
      hb.add(%bandCode(cog.band))
  var crates = newJArray()
  for crate in sim.crates:
    crates.add(%[crate.c.x, crate.c.y, ord(crate.state)])
  var flashes = newJArray()
  for burst in bursts:
    flashes.add(%[burst[0], burst[1]])
  %*{
    "type": "frame",
    "tick": sim.tick, "half": phase.half, "act": $phase.act,
    "turn": phase.turn, "act_left_ticks": phase.actLeft,
    "cogs": cogs, "crates": crates, "sounds": soundsJson(sim), "hb": hb,
    "hidden_s": [hidden[0].float / TargetFps.float,
                 hidden[1].float / TargetFps.float],
    "hiders_left": left,
    "bursts": flashes,
    "intermission": sim.tick > 0 and isHalfBoundary(sim.config, sim.tick)
  }

proc frameMeta*(sim: Sim): JsonNode =
  ## What broadcast_core needs once, before the first frame: the blueprint
  ## and the lantern numbers. The static bundle gets the same keys (and
  ## more) from the replay file.
  %*{"type": "meta", "map": sim.map.raw, "config": configJson(sim.config),
     "tick_count": totalTicks(sim.config),
     "lit_grid": [FovW, FovH, FovCell]}

proc snapshotJson*(sim: Sim, playerNames: seq[string], started: bool,
                   connected: seq[bool]): JsonNode =
  let phase = phaseAt(sim.config, min(sim.tick, totalTicks(sim.config) - 1))
  var names = newJArray()
  for name in playerNames:
    names.add(%name)
  var flags = newJArray()
  for flag in connected:
    flags.add(%flag)
  %*{
    "type": "state",
    "game": "lantern",
    "tick": sim.tick,
    "turn": phase.turn,
    "turns": totalTurns(sim.config),
    "half": phase.half,
    "act": $phase.act,
    "act_left_ticks": phase.actLeft,
    "map": mapBlock(sim.map),
    "cogs": cogsJson(sim, phase.half),
    "crates": cratesJson(sim),
    "sounds": soundsJson(sim),
    "policyNames": names,
    "colors": {"Moth": teamColor(tmMoth), "Owl": teamColor(tmOwl)},
    "started": started,
    "done": sim.finished,
    "connected": flags,
    "meta": frameMeta(sim),
    "frame": framePacket(sim, @[]),
    "lit_b64": litMaskB64(litMaskBytes(sim))
  }
