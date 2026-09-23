## Export complete Lantern matches as Metta post-training examples.
## Usage: nim r --path:src tools/export_posttrain.nim OUTPUT MATCHES [FIRST_SEED] [VARIANT]

import std/[json, os, osproc, strutils]
import lantern/[arena, baselines, config, control, labels, llm, orders, replay, rules,
                server, sim, types]

const OperatorPrompt = "Play both roles to maximize your team's hidden time advantage."
const Variants = ["default", "sprint"]

when isMainModule:
  let args = commandLineParams()
  if args.len notin 2 .. 4:
    quit("usage: export_posttrain OUTPUT MATCHES [FIRST_SEED] [VARIANT]", 1)
  let output = args[0]
  let matches = parseInt(args[1])
  let firstSeed = if args.len >= 3: parseInt(args[2]) else: 1
  let variant = if args.len == 4: args[3] else: Variants[0]
  if matches < 10 or firstSeed < 1:
    quit("at least ten matches and a positive first seed are required", 1)
  if variant notin Variants:
    quit("unknown variant: " & variant, 1)
  if dirExists(output) or fileExists(output):
    quit("output already exists: " & output, 1)
  createDir(output)
  let sourceRevision = execProcess("git rev-parse HEAD").strip()
  let manifest = parseFile("coworld_manifest_template.json")
  var variantConfig: JsonNode
  for entry in manifest["variants"]:
    if entry["id"].getStr() == variant:
      variantConfig = entry["game_config"]
  doAssert not variantConfig.isNil
  var
    trainRows: seq[string]
    validationRows: seq[string]
    runs = newJArray()
  for seed in firstSeed ..< firstSeed + matches:
    var config = defaultGameConfig()
    let runtimeConfig = copy(variantConfig)
    runtimeConfig["tokens"] = newJArray()
    for seat in 0 ..< Seats:
      runtimeConfig["tokens"].add(%("t" & $seat))
    runtimeConfig["seed"] = %seed
    config.update($runtimeConfig)
    let map = loadMapSpec(config.mapPath)
    let sim = newSim(config, map)
    var rows: seq[string]
    while sim.tick < totalTicks(config):
      sim.prepareTick()
      if isTurnStart(config, sim.tick):
        let phase = phaseAt(config, sim.tick)
        for seat in activeSeats(sim, phase.half, phase.act):
          let teacher = scriptedOrder(sim, seat, phase.half,
            if seat mod 2 == 0: skWarden else: skMoth)
          let completion = orderJson(teacher)
          let cog = sim.cogs[seat]
          let parsed = parseOrderText($completion, roleOfSlot(seat, phase.half),
            Point(x: cog.px, y: cog.py), sim.crates)
          doAssert parsed == teacher
          rows.add($(%*{
            "episode_id": "lantern-" & variant & "-" & $seed,
            "seed": "lantern-" & variant & "-" & $seed,
            "decision_id": rows.len,
            "prompt": [
              {"role": "system", "content": SystemPrompt},
              {"role": "user", "content": userPrompt(sim, seat,
                OperatorPrompt, false)}
            ],
            "completion": [{"role": "assistant", "content": $completion}],
            "game": "lantern",
            "action_schema_revision": "lantern-order-v1"
          }))
          sim.cogs[seat].order = parsed
          sim.cogs[seat].orderSource = osScripted
          sim.cogs[seat].hasOrder = true
      let controls = compileControls(sim)
      sim.applyTick(controls)
    doAssert sim.tick == totalTicks(config) and rows.len > 0
    let kinds = @["scripted", "scripted", "scripted", "scripted",
      "scripted", "scripted"]
    let zeros = newSeq[int](Seats)
    let causes = newSeq[array[FallbackCause, int]](Seats)
    let outcome = buildResults(sim, kinds, zeros, zeros, causes,
      erComplete, edFullTime)
    if seed mod 5 == 0:
      validationRows.add(rows)
    else:
      trainRows.add(rows)
    runs.add(%*{"seed": seed, "decisions": rows.len,
      "scores": outcome["scores"], "ticks_played": sim.tick})
  writeFile(output / "train.jsonl", trainRows.join("\n") & "\n")
  writeFile(output / "validation.jsonl", validationRows.join("\n") & "\n")
  writeFile(output / "manifest.json", pretty(%*{
    "schema_version": 1,
    "game": "lantern",
    "variant": variant,
    "source_revision": sourceRevision,
    "teacher": "scripted-warden-and-moth",
    "operator_prompt": OperatorPrompt,
    "train_examples": trainRows.len,
    "validation_examples": validationRows.len,
    "runs": runs
  }) & "\n")
  echo "train=", trainRows.len, " validation=", validationRows.len
