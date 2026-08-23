## Shared test helpers.
##
## This file lives in a SUBDIRECTORY on purpose: ci.yml runs every
## `tests/*.nim` file as a standalone program, and a helper module sitting in
## `tests/` would be executed as if it were a test.

import std/[algorithm, json, os, strutils]
import lantern/[types, arena, crates, config, sim, rules, control, baselines,
                replay, labels, orders, render, roster, events, state]

export types, arena, crates, config, sim, rules, control, baselines, replay,
       labels, orders, render, roster, events, state

proc repoRoot*(): string =
  ## Tests are run from the repo root by ci.yml, but resolve upward anyway so
  ## `nim r tests/test_x.nim` works from anywhere.
  result = getCurrentDir()
  for _ in 0 .. 4:
    if fileExists(result / "coworld_manifest_template.json"):
      return result
    result = result.parentDir()
  result = getCurrentDir()

proc testMap*(): MapSpec =
  parseMapSpec(readFile(repoRoot() / "data" / "vault.mapspec.json"))

proc testConfig*(seed = 42, prep = 240, hunt = 480): GameConfig =
  result = defaultGameConfig()
  result.seed = seed
  result.prepTicks = prep
  result.huntTicks = hunt
  result.update("""{"num_agents": 6}""")

proc testSim*(seed = 42, prep = 240, hunt = 480): Sim =
  newSim(testConfig(seed, prep, hunt), testMap())

proc place*(sim: Sim, slot, x, y: int, aim = 0) =
  sim.cogs[slot].x = x * MotionScale
  sim.cogs[slot].y = y * MotionScale
  sim.cogs[slot].vx = 0
  sim.cogs[slot].vy = 0
  sim.cogs[slot].aim = aim
  sim.cogs[slot].unstickAnchorX = sim.cogs[slot].x
  sim.cogs[slot].unstickAnchorY = sim.cogs[slot].y

proc parkEveryoneElse*(sim: Sim, keep: openArray[int]) =
  ## Move every cog not named in `keep` into a far corner so it cannot
  ## collide with the one under test.
  var corner = 1180
  for slot in 0 ..< sim.seats:
    if slot in keep:
      continue
    sim.place(slot, corner, 620)
    corner -= 30

proc drive*(sim: Sim, moveX, moveY: int, ticks: int,
            action: uint8 = 0, aimTurn = 0) =
  ## Hold one control vector for `ticks` ticks, for every seat.
  for _ in 1 .. ticks:
    var controls = newSeq[Control](sim.seats)
    for slot in 0 ..< sim.seats:
      controls[slot] = Control(moveX: int8(moveX), moveY: int8(moveY),
                               aimTurn: int8(aimTurn), action: action)
    sim.prepareTick()
    sim.applyTick(controls)

proc driveOne*(sim: Sim, slot, moveX, moveY, ticks: int,
               action: uint8 = 0, aimTurn = 0) =
  for _ in 1 .. ticks:
    var controls = newSeq[Control](sim.seats)
    controls[slot] = Control(moveX: int8(moveX), moveY: int8(moveY),
                             aimTurn: int8(aimTurn), action: action)
    sim.prepareTick()
    sim.applyTick(controls)

proc jumpToHunt*(sim: Sim) =
  ## Fast-forward to the first tick of the current half's hunt act with every
  ## cog idle, so a vision or detection test starts with the lanterns on.
  while phaseAt(sim.config, sim.tick).act == actBuild:
    sim.prepareTick()
    sim.applyTick(newSeq[Control](sim.seats))

proc runScriptedEpisode*(sim: Sim, kinds: seq[ScriptKind]): int =
  ## A whole match on the scripted layer, recording controls exactly as the
  ## server does. Returns the number of ticks simulated.
  while sim.tick < totalTicks(sim.config):
    sim.prepareTick()
    if isTurnStart(sim.config, sim.tick):
      let half = phaseAt(sim.config, sim.tick).half
      for slot in 0 ..< sim.seats:
        if sim.cogs[slot].found:
          continue
        sim.cogs[slot].order = scriptedOrder(sim, slot, half, kinds[slot])
        sim.cogs[slot].orderSource = osScripted
        sim.cogs[slot].hasOrder = true
    let controls = compileControls(sim)
    for control in controls:
      sim.controls.add(control)
    sim.applyTick(controls)
  sim.tick

proc allWarden*(): seq[ScriptKind] =
  newSeq[ScriptKind](Seats)

proc kindsFor*(moth, owl: ScriptKind): seq[ScriptKind] =
  result = newSeq[ScriptKind](Seats)
  for slot in 0 ..< Seats:
    result[slot] = (if teamOfSlot(slot) == tmMoth: moth else: owl)

proc scriptedResults*(sim: Sim, reason = erComplete,
                      rule = edFullTime): JsonNode =
  var kinds: seq[string]
  for _ in 0 ..< sim.seats:
    kinds.add("scripted")
  let zeros = newSeq[int](sim.seats)
  var causes = newSeq[array[FallbackCause, int]](sim.seats)
  buildResults(sim, kinds, zeros, zeros, causes, reason, rule)

proc countEvents*(sim: Sim, kind: string): int =
  for event in sim.events:
    if event{"type"}.getStr() == kind:
      inc result

proc readRepoFile*(relative: string): string =
  readFile(repoRoot() / relative)

proc sourcePaths*(relativeDir: string, suffix = ".nim"): seq[string] =
  for path in walkDir(repoRoot() / relativeDir):
    if path.kind == pcFile and path.path.endsWith(suffix):
      result.add(path.path)
  result.sort()
