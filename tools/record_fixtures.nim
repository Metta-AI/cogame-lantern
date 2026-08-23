## Records the committed test fixtures.
##
##   nim r --path:src tools/record_fixtures.nim
##
## Writes:
##   tests/fixtures/golden_digests.json  the keyframe digests for seed 42 over
##                                       the certification-fixture length, so
##                                       any rule change shows up in the diff;
##   tests/fixtures/smoke_replay.json    a full recorded replay for the node
##                                       wasm viewer harness.
##
## Re-record deliberately, never to make a red test green: a diff here IS the
## rule change, and it belongs in the same commit as the rule.

import std/[json, os]
import lantern/[types, arena, config, sim, rules, control, baselines, replay,
                labels]

const
  Seed = 42
  Prep = 240
  Hunt = 480

proc recordEpisode(): Sim =
  var config = defaultGameConfig()
  config.seed = Seed
  config.prepTicks = Prep
  config.huntTicks = Hunt
  config.update("""{"num_agents": 6}""")
  let map = parseMapSpec(readFile("data" / "vault.mapspec.json"))
  result = newSim(config, map)
  while result.tick < totalTicks(config):
    result.prepareTick()
    if isTurnStart(config, result.tick):
      let half = phaseAt(config, result.tick).half
      for slot in 0 ..< result.seats:
        if result.cogs[slot].found:
          continue
        result.cogs[slot].order = scriptedOrder(result, slot, half,
          (if teamOfSlot(slot) == tmMoth: skWarden else: skMoth))
        result.cogs[slot].orderSource = osScripted
        result.cogs[slot].hasOrder = true
    let controls = compileControls(result)
    for control in controls:
      result.controls.add(control)
    result.applyTick(controls)

when isMainModule:
  let world = recordEpisode()
  var digests = newJArray()
  for frame in world.keyframes:
    digests.add(%*{"t": frame.t, "d": frame.digest.int64})
  createDir("tests" / "fixtures")
  writeFile("tests" / "fixtures" / "golden_digests.json",
    pretty(%*{"seed": Seed, "prepTicks": Prep, "huntTicks": Hunt,
              "game_version": GameVersion, "digests": digests}) & "\n")

  var kinds: seq[string]
  for _ in 0 ..< world.seats:
    kinds.add("scripted")
  let zeros = newSeq[int](world.seats)
  var causes = newSeq[array[FallbackCause, int]](world.seats)
  let results = buildResults(world, kinds, zeros, zeros, causes, erComplete,
                             edFullTime)
  writeFile("tests" / "fixtures" / "smoke_replay.json",
    $buildReplay(world, kinds, results))
  echo "recorded ", world.keyframes.len, " keyframes, ",
    world.events.len, " events, ", world.tick, " ticks"
