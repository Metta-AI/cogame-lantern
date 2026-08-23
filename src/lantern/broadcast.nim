## The spectator stream.
##
## `/global` serves a whole-world snapshot (nothing is hidden from a
## spectator: that is the point of the second name space) and the same shape
## is what `client/replay_broadcast.html` draws from when the game server
## hosts a local viewing of a replay. Hosted replays never touch this — they
## are the static wasm bundle, fed from S3.

import std/json
import types, sim, rules, render, labels

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
    "connected": flags
  }
