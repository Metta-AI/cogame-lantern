## Replay bytes and the results document.
##
## Lantern writes UTF-8 JSON, not paintbot's binary `COWLDCTF`: SPEC's
## definition of done fetches the replay from S3 and requires valid UTF-8
## JSON with a matching `protocol` and a legal `results.reason`, and the
## shared `tools/ci/docker_smoke.sh` defaults to SMOKE_REQUIRE_REPLAY_JSON=1.
## The bulk payload — the per-tick control bytes — rides as one base64
## string, so the file stays small and the document stays parseable.
##
## `seed` + `map` + `controls_b64` + the integer sim reproduce the episode
## exactly; `keyframes` carry the per-second state and its digest so the
## viewer (and the tests, and a human reading the JSON) can verify the
## re-derivation without running wasm at all.

import std/[base64, json, math]
import types, arena, config, sim, rules, labels

proc encodeControls*(controls: seq[Control]): string =
  ## tick_count x seats x 4 bytes: (move_x i8, move_y i8, aim_turn i8,
  ## action u8), tick-major, slot-ascending.
  var raw = newString(controls.len * 4)
  for index, control in controls:
    raw[index * 4 + 0] = char(cast[uint8](control.moveX))
    raw[index * 4 + 1] = char(cast[uint8](control.moveY))
    raw[index * 4 + 2] = char(cast[uint8](control.aimTurn))
    raw[index * 4 + 3] = char(control.action)
  encode(raw)

proc decodeControls*(text: string): seq[Control] =
  let raw = decode(text)
  if raw.len mod 4 != 0:
    raise newException(LanternError,
      "controls_b64 does not decode to a whole number of 4-byte records")
  result = newSeq[Control](raw.len div 4)
  for index in 0 ..< result.len:
    result[index].moveX = cast[int8](uint8(raw[index * 4 + 0]))
    result[index].moveY = cast[int8](uint8(raw[index * 4 + 1]))
    result[index].aimTurn = cast[int8](uint8(raw[index * 4 + 2]))
    result[index].action = uint8(raw[index * 4 + 3])

proc phasesJson*(config: GameConfig): JsonNode =
  result = newJArray()
  let span = halfTicks(config)
  for half in 1 .. config.halves:
    let base = (half - 1) * span
    result.add(%*{"half": half, "act": "build", "from": base,
                  "to": base + config.prepTicks - 1})
    result.add(%*{"half": half, "act": "hunt", "from": base + config.prepTicks,
                  "to": base + span - 1})

proc keyframesJson*(sim: Sim): JsonNode =
  result = newJArray()
  for frame in sim.keyframes:
    var cogs = newJArray()
    for entry in frame.cogs:
      cogs.add(%[entry[0], entry[1], entry[2], entry[3]])
    var crates = newJArray()
    for entry in frame.crates:
      crates.add(%[entry[0], entry[1], entry[2]])
    result.add(%*{"t": frame.t, "d": frame.digest.int64, "cogs": cogs,
                  "crates": crates, "hb": frame.hb, "hid": frame.hid})

proc namesJson*(config: GameConfig, policyKinds: seq[string]): JsonNode =
  ## The SPECTATOR name space. Real player names live here and in the results
  ## document; the aliases beside them are the only names the game itself
  ## ever used.
  var players = newJArray()
  var aliases = newJArray()
  var teams = newJArray()
  for slot in 0 ..< config.numAgents:
    players.add(%(if slot < config.players.len: config.players[slot].name
                  else: "P" & $(slot + 1)))
    aliases.add(%aliasOfSlot(slot))
    teams.add(%($teamOfSlot(slot)))
  %*{"players": players, "aliases": aliases, "teams": teams,
     "policy_kinds": policyKinds,
     "colors": {"Moth": teamColor(tmMoth), "Owl": teamColor(tmOwl)}}

proc buildResults*(sim: Sim, policyKinds: seq[string],
                   llmTurns, fallbackTurns: seq[int],
                   fallbackCauses: seq[array[FallbackCause, int]],
                   reason: EndReason, rule: EndRule): JsonNode =
  ## The closed results schema. Adding or removing a key here means editing
  ## coworld_manifest_template.json's `results_schema` in the same commit;
  ## tests/test_manifest.nim compares the two key sets.
  let config = sim.config
  var mothHidden, owlHidden: seq[int]
  for slot in 0 ..< config.numAgents:
    if teamOfSlot(slot) == tmMoth: mothHidden.add(sim.cogs[slot].hiddenTicks)
    else: owlHidden.add(sim.cogs[slot].hiddenTicks)
  let mothMicro = hiddenFracMicro(mothHidden, sim.huntTicksPlayed[0])
  let owlMicro = hiddenFracMicro(owlHidden, sim.huntTicksPlayed[1])
  let comparable = reason != erFault and
    sim.huntTicksPlayed[0] > 0 and sim.huntTicksPlayed[1] > 0
  let (mothMilli, owlMilli) = scoreMilli(mothMicro, owlMicro, comparable)
  let winner = (if comparable: winnerOf(mothMilli) else: -1)

  var names, aliases, teams, hidIn, kinds = newJArray()
  var scores, win, hiddenTicks, hiddenSeconds = newJArray()
  var finds, pushed, locked, broken = newJArray()
  var llm, fallbacks, causes = newJArray()
  for slot in 0 ..< config.numAgents:
    let team = teamOfSlot(slot)
    let milli = (if team == tmMoth: mothMilli else: owlMilli)
    names.add(%(if slot < config.players.len: config.players[slot].name
                else: "P" & $(slot + 1)))
    aliases.add(%aliasOfSlot(slot))
    teams.add(%($team))
    hidIn.add(%hidHalfOfSlot(slot))
    kinds.add(%policyKinds[slot])
    scores.add(%(milli.float / 1000.0))
    win.add(%(comparable and milli > 500))
    hiddenTicks.add(%sim.cogs[slot].hiddenTicks)
    hiddenSeconds.add(%(round(sim.cogs[slot].hiddenTicks.float * 10.0 /
                              TargetFps.float) / 10.0))
    finds.add(%sim.cogs[slot].finds)
    pushed.add(%sim.cogs[slot].cratesPushed)
    locked.add(%sim.cogs[slot].cratesLocked)
    broken.add(%sim.cogs[slot].cratesBroken)
    llm.add(%llmTurns[slot])
    fallbacks.add(%fallbackTurns[slot])
    var causeObject = newJObject()
    for cause in FallbackCause:
      causeObject[$cause] = %fallbackCauses[slot][cause]
    causes.add(causeObject)
  var mothTotal, owlTotal = 0
  for ticks in mothHidden: mothTotal += ticks
  for ticks in owlHidden: owlTotal += ticks
  %*{
    "names": names,
    "aliases": aliases,
    "teams": teams,
    "hid_in_half": hidIn,
    "policy_kinds": kinds,
    "scores": scores,
    "win": win,
    "hidden_ticks": hiddenTicks,
    "hidden_seconds": hiddenSeconds,
    "finds": finds,
    "crates_pushed": pushed,
    "crates_locked": locked,
    "crates_broken": broken,
    "team_hidden_frac": [round(mothMicro.float / 1000.0) / 1000.0,
                         round(owlMicro.float / 1000.0) / 1000.0],
    "team_hidden_seconds": [round(mothTotal.float * 10.0 / TargetFps.float) / 10.0,
                            round(owlTotal.float * 10.0 / TargetFps.float) / 10.0],
    "reason": $reason,
    "end_rule": $rule,
    "winner": (if winner < 0: newJNull() else: %winner),
    "final_tick": sim.tick,
    "final_turn": sim.tick div config.turnTicks,
    "halves_played": (if sim.huntTicksPlayed[1] > 0: 2
                      elif sim.huntTicksPlayed[0] > 0: 1 else: 0),
    "hunt_ticks_played": [sim.huntTicksPlayed[0], sim.huntTicksPlayed[1]],
    "seed": config.seed,
    "llm_turns": llm,
    "fallback_turns": fallbacks,
    "fallback_causes": causes
  }

proc buildReplay*(sim: Sim, policyKinds: seq[string],
                  results: JsonNode): JsonNode =
  var events = newJArray()
  for event in sim.events:
    events.add(event)
  %*{
    "protocol": ReplayProtocol,
    "format_version": ReplayFormatVersion,
    "game_version": GameVersion,
    "seed": sim.config.seed,
    "config": configJson(sim.config),
    "map": sim.map.raw,
    "names": namesJson(sim.config, policyKinds),
    "ticks_per_second": TargetFps,
    "turn_ticks": sim.config.turnTicks,
    "tick_count": sim.controls.len div max(1, sim.config.numAgents),
    "phases": phasesJson(sim.config),
    "controls_b64": encodeControls(sim.controls),
    "keyframes": keyframesJson(sim),
    "events": events,
    "results": results
  }

type
  Rederivation* = object
    ok*: bool
    mismatchTick*: int      ## -1 when every keyframe digest matched
    checked*: int
    tickCount*: int
    sim*: Sim

proc rederive*(replay: JsonNode): Rederivation =
  ## Replay the recorded control bytes through the same integer sim and
  ## compare every keyframe digest. This is what the wasm viewer runs in the
  ## browser, and what tests/test_replay.nim runs natively — same code, so a
  ## rule change that breaks one breaks both.
  result.mismatchTick = -1
  if replay{"protocol"}.getStr() != ReplayProtocol:
    raise newException(LanternError,
      "not a lantern replay: protocol " & replay{"protocol"}.getStr("(none)"))
  let cfg = configFromJson(replay{"config"})
  let map = parseMapSpec($replay{"map"})
  let controls = decodeControls(replay{"controls_b64"}.getStr())
  let tickCount = replay{"tick_count"}.getInt()
  if tickCount < 0 or controls.len != tickCount * cfg.numAgents:
    raise newException(LanternError,
      "controls_b64 holds " & $controls.len & " records; tick_count " &
      $tickCount & " x " & $cfg.numAgents & " seats needs " &
      $(tickCount * cfg.numAgents))
  var digests = newSeq[(int, uint32)]()
  for frame in replay{"keyframes"}:
    digests.add((frame{"t"}.getInt(), uint32(frame{"d"}.getBiggestInt())))
  let world = newSim(cfg, map)
  result.sim = world
  result.tickCount = tickCount
  var next = 0
  while world.tick < tickCount:
    let expected =
      if next < digests.len and digests[next][0] == world.tick:
        inc next
        true
      else:
        false
    world.prepareTick()
    if expected:
      let frame = world.keyframes[^1]
      inc result.checked
      if frame.digest != digests[next - 1][1] and result.mismatchTick < 0:
        result.mismatchTick = world.tick
    let base = world.tick * cfg.numAgents
    world.applyTick(controls[base ..< base + cfg.numAgents])
  result.ok = result.mismatchTick < 0
