## Lantern static replay viewer, wasm side.
##
## JS hands the raw replay bytes to `lt_load_replay`; this module parses them
## and re-derives the whole episode with the SAME Nim sim the game server ran,
## from `seed` + `map` + `controls_b64`. It checks every keyframe digest on the
## way (a mismatch surfaces as the page's `#mmwarn` line and the
## `data-replay-mismatch-tick` attribute) and then serves one frame packet per
## tick to the renderer.
##
## Because the step is integer-only, the emscripten build and the native build
## produce identical digests — which is what makes "the viewer re-derived the
## same match" a claim the viewer can actually prove.

import std/json
import lantern/[types, arena, config, sim, rules, replay, labels]

var
  meta: string
  packet: string
  lastError: string
  stage: string
  controls: seq[Control]
  world: Sim
  worldConfig: GameConfig
  worldMap: MapSpec
  tickCount: int
  mismatchTick = -1

proc bytesFromPointer(data: ptr uint8, length: int): string =
  result = newString(length)
  if length > 0:
    copyMem(result[0].addr, data, length)

proc packetJson(): string =
  let phase = phaseAt(worldConfig, min(world.tick, tickCount - 1))
  var cogs = newJArray()
  var hb = newJArray()
  var hidden = [0, 0]
  var left = 0
  for slot in 0 ..< world.seats:
    let cog = world.cogs[slot]
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
              world.teamLit(cog.px, cog.py))})
    if role == roSeeker:
      hb.add(%bandCode(cog.band))
  var crates = newJArray()
  for crate in world.crates:
    crates.add(%[crate.c.x, crate.c.y, ord(crate.state)])
  var sounds = newJArray()
  for ring in world.sounds:
    sounds.add(%*{"kind": $ring.kind, "pos": [ring.at.x, ring.at.y],
                  "radius": ring.radius, "age_ticks": world.tick - ring.tick})
  $ %*{
    "type": "frame",
    "tick": world.tick, "half": phase.half, "act": $phase.act,
    "turn": phase.turn, "act_left_ticks": phase.actLeft,
    "cogs": cogs, "crates": crates, "sounds": sounds, "hb": hb,
    "hidden_s": [hidden[0].float / TargetFps.float,
                 hidden[1].float / TargetFps.float],
    "hiders_left": left,
    "intermission": world.tick > 0 and isHalfBoundary(worldConfig, world.tick)
  }

proc rebuildWorld() =
  world = newSim(worldConfig, worldMap)

proc stepTo(target: int) =
  ## Seeking backwards restarts from tick 0 and fast-forwards: a whole match
  ## is a fraction of a second of integer sim, so this is cheaper than
  ## keeping 5040 snapshots alive in a 2 GB wasm heap.
  if target < world.tick:
    rebuildWorld()
  while world.tick < target and world.tick < tickCount:
    world.prepareTick()
    let base = world.tick * worldConfig.numAgents
    world.applyTick(controls[base ..< base + worldConfig.numAgents])

proc ltLoadReplay(data: ptr uint8, length: cint): cint
    {.exportc: "lt_load_replay", cdecl.} =
  try:
    lastError = ""
    stage = "parsing the replay JSON"
    let node = parseJson(bytesFromPointer(data, int(length)))
    stage = "re-deriving the episode"
    let checked = rederive(node)
    mismatchTick = checked.mismatchTick
    tickCount = checked.tickCount
    worldConfig = configFromJson(node{"config"})
    worldMap = parseMapSpec($node{"map"})
    controls = decodeControls(node{"controls_b64"}.getStr())
    stage = "collecting the hiders-left series"
    var series = newJArray()
    var replayHiders = newSim(worldConfig, worldMap)
    while replayHiders.tick < tickCount:
      if replayHiders.tick mod ReplayFps == 0:
        let phase = phaseAt(worldConfig, replayHiders.tick)
        series.add(%[replayHiders.tick, replayHiders.hidersLeft(phase.half)])
      replayHiders.prepareTick()
      let base = replayHiders.tick * worldConfig.numAgents
      replayHiders.applyTick(
        controls[base ..< base + worldConfig.numAgents])
    var spans = newJArray()
    for span in node{"phases"}:
      if span{"act"}.getStr() == "build":
        spans.add(%[span{"from"}.getInt(), span{"to"}.getInt()])
    stage = "building the meta payload"
    meta = $ %*{
      "type": "meta",
      "protocol": node{"protocol"}.getStr(),
      "game_version": node{"game_version"}.getStr(),
      "seed": node{"seed"}.getInt(),
      "config": node{"config"},
      "map": node{"map"},
      "names": node{"names"},
      "phases": node{"phases"},
      "events": node{"events"},
      "results": node{"results"},
      "tick_count": tickCount,
      "turns": totalTurns(worldConfig),
      "ticks_per_second": TargetFps,
      "timelapse_spans": spans,
      "hiders_left_series": series,
      "mismatch_tick": mismatchTick
    }
    stage = "ready"
    rebuildWorld()
    packet = packetJson()
    return 1
  except CatchableError as error:
    lastError = error.msg
    return 0

proc ltFrame(): cint {.exportc: "lt_frame", cdecl.} =
  try:
    if world.isNil:
      return -1
    if world.tick >= tickCount:
      packet = packetJson()
      return cint(world.tick)
    world.prepareTick()
    let base = world.tick * worldConfig.numAgents
    world.applyTick(controls[base ..< base + worldConfig.numAgents])
    packet = packetJson()
    cint(world.tick)
  except CatchableError as error:
    lastError = error.msg
    cint(-1)

proc ltSeek(target: cint): cint {.exportc: "lt_seek", cdecl.} =
  try:
    if world.isNil:
      return -1
    stepTo(clampInt(int(target), 0, tickCount))
    packet = packetJson()
    cint(world.tick)
  except CatchableError as error:
    lastError = error.msg
    cint(-1)

proc ltTick(): cint {.exportc: "lt_tick", cdecl.} =
  if world.isNil: cint(0) else: cint(world.tick)

proc ltTickCount(): cint {.exportc: "lt_tick_count", cdecl.} =
  cint(tickCount)

proc ltMismatchTick(): cint {.exportc: "lt_mismatch_tick", cdecl.} =
  cint(mismatchTick)

proc ltMetaPointer(): ptr uint8 {.exportc: "lt_meta_ptr", cdecl.} =
  if meta.len == 0: nil else: cast[ptr uint8](meta[0].addr)

proc ltMetaLength(): cint {.exportc: "lt_meta_len", cdecl.} =
  cint(meta.len)

proc ltPacketPointer(): ptr uint8 {.exportc: "lt_packet_ptr", cdecl.} =
  if packet.len == 0: nil else: cast[ptr uint8](packet[0].addr)

proc ltPacketLength(): cint {.exportc: "lt_packet_len", cdecl.} =
  cint(packet.len)

proc ltErrorPointer(): ptr uint8 {.exportc: "lt_error_ptr", cdecl.} =
  if lastError.len == 0: nil else: cast[ptr uint8](lastError[0].addr)

proc ltErrorLength(): cint {.exportc: "lt_error_len", cdecl.} =
  cint(lastError.len)

proc ltStagePointer(): ptr uint8 {.exportc: "lt_stage_ptr", cdecl.} =
  if stage.len == 0: nil else: cast[ptr uint8](stage[0].addr)

proc ltStageLength(): cint {.exportc: "lt_stage_len", cdecl.} =
  cint(stage.len)

when defined(emscripten):
  proc emscriptenExitWithLiveRuntime() {.
    importc: "emscripten_exit_with_live_runtime", cdecl.}

when isMainModule and defined(emscripten):
  ## Nim's generated main would run module-global destructors on return,
  ## freeing `meta` and friends while JS keeps calling into the module.
  emscriptenExitWithLiveRuntime()
