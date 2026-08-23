## The grid harness the `warden` baseline's parameters were tuned with.
##
##   nim r --path:src tools/tune_baselines.nim
##
## Sweeps `WardenParams` — the nook-coverage gate, the build-act lock budget
## and the hot-turns-before-a-pry counter — over the full 3x3x3 cross product
## of the values below, on four seeds, and writes the whole table to
## `tests/fixtures/tuning_grid.json`. `baselines.ShippedWardenParams` is that
## table's argmax; `tests/test_tuning.nim` re-derives the argmax from the
## committed table, re-runs two of its cells against this code and asserts
## both, so "the baseline's parameters were tuned, not guessed" is a claim the
## repo can prove rather than assert.
##
## The metric is head-to-head score, the only thing that matters for a ladder
## baseline. Each cell plays, for every seed, two full matches with the
## candidate warden on the Moth seats:
##
##   * against `moth`, the other shipped baseline;
##   * against `ReferenceWardenParams`, the hand-guessed starting point
##     (60 / 2 / 2, the numbers the design note pinned before any sweep).
##
## The reference is a FIXED constant, not `ShippedWardenParams`: if the
## opponent moved with the shipped values the table would chase its own tail
## and the recorded numbers would stop being reproducible.
##
## Because the sides swap at half time and the score is exactly zero-sum,
## `scores[0]` (a Moth seat) in milli is the whole result of one match. An
## episode is a full-length match (720 prep + 1800 hunt ticks per half), which
## is the length the parameters actually have to work at: at the certification
## fixture's 240/480 the build act is two turns long and every cell of the
## grid scores identically. The whole sweep is about 20 s of integer sim.

import std/[json, os]
import lantern/[types, arena, config, sim, rules, control, baselines, replay,
                labels]

const
  Seeds* = [1, 7, 42, 99]
  CoverageGates* = [40, 60, 80]
  BuildLocks* = [1, 2, 3]
  PryHotTurns* = [1, 2, 3]
  Prep* = 720
  Hunt* = 1800
  ReferenceWardenParams* = WardenParams(coverageGatePct: 60, buildLocks: 2,
                                        pryHotTurns: 2)
    ## The pre-sweep guess, and the fixed sparring partner for the grid.

type
  GridCell* = object
    params*: WardenParams
    vsMothMilli*: seq[int]        ## one per seed
    vsReferenceMilli*: seq[int]   ## one per seed
    meanMilli*: int               ## mean of both columns over all seeds

proc mapSpecPath(): string =
  ## The tool runs from the repo root; the test that imports it resolves
  ## upward the same way `tests/support/helpers.nim` does.
  var root = getCurrentDir()
  for _ in 0 .. 4:
    if fileExists(root / "data" / "vault.mapspec.json"):
      return root / "data" / "vault.mapspec.json"
    root = root.parentDir()
  "data" / "vault.mapspec.json"

proc matchScoreMilli*(seed: int, moth: WardenParams, owlKind: ScriptKind,
                      owl: WardenParams): int =
  ## One full match, warden(`moth`) on the Moth seats against `owlKind` on the
  ## Owl seats. Returns the Moth side's score in milli.
  var config = defaultGameConfig()
  config.seed = seed
  config.prepTicks = Prep
  config.huntTicks = Hunt
  config.update("""{"num_agents": 6}""")
  let world = newSim(config, parseMapSpec(readFile(mapSpecPath())))
  while world.tick < totalTicks(config):
    world.prepareTick()
    if isTurnStart(config, world.tick):
      let half = phaseAt(config, world.tick).half
      for slot in 0 ..< world.seats:
        if world.cogs[slot].found:
          continue
        world.cogs[slot].order =
          if teamOfSlot(slot) == tmMoth:
            scriptedOrder(world, slot, half, skWarden, moth)
          else:
            scriptedOrder(world, slot, half, owlKind, owl)
        world.cogs[slot].orderSource = osScripted
        world.cogs[slot].hasOrder = true
    world.applyTick(compileControls(world))
  var kinds: seq[string]
  for _ in 0 ..< world.seats:
    kinds.add("scripted")
  let zeros = newSeq[int](world.seats)
  var causes = newSeq[array[FallbackCause, int]](world.seats)
  let results = buildResults(world, kinds, zeros, zeros, causes, erComplete,
                             edFullTime)
  int(results["scores"][0].getFloat() * 1000.0 + 0.5)

proc scoreVsMoth*(seed: int, params: WardenParams): int =
  matchScoreMilli(seed, params, skMoth, ReferenceWardenParams)

proc scoreVsReference*(seed: int, params: WardenParams): int =
  matchScoreMilli(seed, params, skWarden, ReferenceWardenParams)

proc evaluate*(params: WardenParams): GridCell =
  result.params = params
  var total = 0
  for seed in Seeds:
    let againstMoth = scoreVsMoth(seed, params)
    let againstReference = scoreVsReference(seed, params)
    result.vsMothMilli.add(againstMoth)
    result.vsReferenceMilli.add(againstReference)
    total += againstMoth + againstReference
  result.meanMilli = total div (2 * Seeds.len)

proc gridPoints*(): seq[WardenParams] =
  for gate in CoverageGates:
    for locks in BuildLocks:
      for hot in PryHotTurns:
        result.add(WardenParams(coverageGatePct: gate, buildLocks: locks,
                                pryHotTurns: hot))

proc sweep*(): seq[GridCell] =
  for params in gridPoints():
    result.add(evaluate(params))

proc distanceToReference(params: WardenParams): int =
  ## Ties are broken toward the hand-guessed reference: a parameter only moves
  ## when the grid shows it winning, never on a coin flip.
  abs(params.coverageGatePct - ReferenceWardenParams.coverageGatePct) +
    10 * abs(params.buildLocks - ReferenceWardenParams.buildLocks) +
    10 * abs(params.pryHotTurns - ReferenceWardenParams.pryHotTurns)

proc bestOf*(cells: seq[GridCell]): GridCell =
  ## The argmax, ties broken toward the reference point, so the choice is a
  ## pure function of the table.
  result = cells[0]
  for cell in cells:
    if cell.meanMilli > result.meanMilli or
        (cell.meanMilli == result.meanMilli and
         distanceToReference(cell.params) <
           distanceToReference(result.params)):
      result = cell

proc paramsJson*(params: WardenParams): JsonNode =
  %*{"coverage_gate_pct": params.coverageGatePct,
     "build_locks": params.buildLocks,
     "pry_hot_turns": params.pryHotTurns}

proc paramsOf*(node: JsonNode): WardenParams =
  WardenParams(coverageGatePct: node["coverage_gate_pct"].getInt(),
               buildLocks: node["build_locks"].getInt(),
               pryHotTurns: node["pry_hot_turns"].getInt())

proc cellsOf*(record: JsonNode): seq[GridCell] =
  for row in record["grid"]:
    var cell = GridCell(params: paramsOf(row["params"]),
                        meanMilli: row["mean_milli"].getInt())
    for value in row["vs_moth_milli"]:
      cell.vsMothMilli.add(value.getInt())
    for value in row["vs_reference_milli"]:
      cell.vsReferenceMilli.add(value.getInt())
    result.add(cell)

proc recordJson*(cells: seq[GridCell]): JsonNode =
  var rows = newJArray()
  for cell in cells:
    rows.add(%*{"params": paramsJson(cell.params),
                "vs_moth_milli": cell.vsMothMilli,
                "vs_reference_milli": cell.vsReferenceMilli,
                "mean_milli": cell.meanMilli})
  %*{"harness": "tools/tune_baselines.nim",
     "metric": "warden(candidate) score in milli on the Moth seats, " &
       "averaged over both opponents and every seed",
     "opponents": ["moth", "warden(reference)"],
     "reference": paramsJson(ReferenceWardenParams),
     "seeds": @Seeds,
     "prep_ticks": Prep,
     "hunt_ticks": Hunt,
     "game_version": GameVersion,
     "chosen": paramsJson(bestOf(cells).params),
     "chosen_mean_milli": bestOf(cells).meanMilli,
     "grid": rows}

when isMainModule:
  import std/[algorithm, strutils]

  let cells = sweep()
  let best = bestOf(cells)
  var ranked = cells
  ranked.sort(proc (a, b: GridCell): int = cmp(b.meanMilli, a.meanMilli))
  echo "gate locks hot |  mean | vs moth | vs reference"
  for cell in ranked:
    echo align($cell.params.coverageGatePct, 4),
      align($cell.params.buildLocks, 6), align($cell.params.pryHotTurns, 4),
      " | ", align($cell.meanMilli, 5), " | ", cell.vsMothMilli, " | ",
      cell.vsReferenceMilli
  echo "argmax:  ", best.params, "  mean ", best.meanMilli
  echo "shipped: ", ShippedWardenParams,
    (if best.params == ShippedWardenParams: "  (== argmax)"
     else: "  *** DIFFERS FROM THE ARGMAX ***")
  createDir("tests" / "fixtures")
  writeFile("tests" / "fixtures" / "tuning_grid.json",
    pretty(recordJson(cells)) & "\n")
  echo "wrote tests/fixtures/tuning_grid.json"
