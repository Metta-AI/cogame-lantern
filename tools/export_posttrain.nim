## Export complete Lantern matches as Metta post-training examples.
## Usage: nim r --path:src tools/export_posttrain.nim OUTPUT MATCHES FIRST_SEED VARIANT GAME_VERSION

import std/[json, options, os, osproc, strutils]
import bitworld/decision_trajectory
import lantern/[decision, render, training_policy, training_capture, arena, baselines, config, control, labels, llm, orders, replay, rules,
                server, sim, types]

const OperatorPrompt = "Play both roles to maximize your team's hidden time advantage."
const Variants = ["default", "sprint"]

when isMainModule:
  let args = commandLineParams()
  if args.len != 5:
    quit("usage: export_posttrain OUTPUT MATCHES FIRST_SEED VARIANT GAME_VERSION", 1)
  let output = args[0]
  let matches = parseInt(args[1])
  let firstSeed = parseInt(args[2])
  let variant = args[3]
  let gameVersion = args[4]
  doAssert gameVersion.len > 0
  if matches < 10 or firstSeed < 1:
    quit("at least ten matches and a positive first seed are required", 1)
  if variant notin Variants:
    quit("unknown variant: " & variant, 1)
  if dirExists(output) or fileExists(output):
    quit("output already exists: " & output, 1)
  createDir(output)
  setFilePermissions(output, {fpUserRead, fpUserWrite, fpUserExec})
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
    trajectoryRows: seq[string]
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
    let episodeId = "lantern-" & variant & "-" & $seed
    let trajectory = newDecisionTrajectory(episodeId, episodeId,
      "lantern", gameVersion, sourceRevision)
    var pending: seq[PendingMacro]
    var rows: seq[string]
    while sim.tick < totalTicks(config):
      sim.prepareTick()
      if isTurnStart(config, sim.tick):
        trajectory.recordMacros(sim, pending)
        let phase = phaseAt(config, sim.tick)
        let seats = activeSeats(sim, phase.half, phase.act)
        var views = newSeq[JsonNode](Seats)
        for seat in seats: views[seat] = seatView(sim, seat)
        for seat in seats:
          let view = views[seat]
          let proposed = teacherReply(view)
          let cog = sim.cogs[seat]
          let parsed = parseOrderText($proposed, roleOfSlot(seat, phase.half),
            Point(x: cog.px, y: cog.py), sim.crates)
          let completion = orderJson(parsed)
          let prompt = %*[{"role": "system", "content": SystemPrompt},
            {"role": "user", "content": userPrompt(view, OperatorPrompt, false)}]
          var evidence = newDecisionAttempt($sim.tick & "-" & $seat & "-teacher",
            "private-view-teacher", aoTeacher)
          evidence.model = some("private-view-teacher")
          evidence.modelIdentity = some(sourceRevision)
          evidence.prompt = prompt
          evidence.request = %*{"teacher": "private-view-teacher", "observation": view}
          evidence.response = %($proposed)
          evidence.rawResponse = %($proposed)
          evidence.decoder = %*{"method": "deterministic"}
          evidence.parsedAction = completion
          evidence.accepted = true
          pending.add(PendingMacro(seat: seat, startTick: sim.tick,
            decision: Decision(order: parsed, source: osScripted, observation: view,
              attempts: @[evidence], selectedAttemptId: some(evidence.attemptId))))
          rows.add($(%*{
            "episode_id": "lantern-" & variant & "-" & $seed,
            "seed": "lantern-" & variant & "-" & $seed,
            "decision_id": rows.len,
            "observation": view, "prompt": prompt,
            "completion": [{"role": "assistant", "content": $completion}],
            "game": "lantern",
            "action_schema_revision": "lantern-order-v1"
          }))
          sim.cogs[seat].order = parsed
          sim.cogs[seat].orderSource = osScripted
          sim.cogs[seat].hasOrder = true
      let controls = compileControls(sim)
      sim.controls.add(controls)
      sim.applyTick(controls)
    trajectory.recordMacros(sim, pending, terminal = true)
    doAssert sim.tick == totalTicks(config) and rows.len > 0
    let kinds = @["scripted", "scripted", "scripted", "scripted",
      "scripted", "scripted"]
    let zeros = newSeq[int](Seats)
    let causes = newSeq[array[FallbackCause, int]](Seats)
    let outcome = buildResults(sim, kinds, zeros, zeros, causes,
      erComplete, edFullTime)
    var outcomes = newJObject()
    for seat in 0 ..< Seats: outcomes[$seat] = outcome["scores"][seat]
    trajectory.finish(esCompleted, outcome, outcomes)
    trajectoryRows.add(trajectory.eventsJsonl().strip())
    if seed mod 5 == 0:
      validationRows.add(rows)
    else:
      trainRows.add(rows)
    runs.add(%*{"seed": seed, "decisions": rows.len,
      "scores": outcome["scores"], "ticks_played": sim.tick})
  writeFile(output / "train.jsonl", trainRows.join("\n") & "\n")
  writeFile(output / "validation.jsonl", validationRows.join("\n") & "\n")
  writeFile(output / "trajectories.jsonl", trajectoryRows.join("\n") & "\n")
  writeFile(output / "manifest.json", pretty(%*{
    "schema_version": 1,
    "game": "lantern",
    "variant": variant,
    "source_revision": sourceRevision,
    "game_version": gameVersion,
    "teacher": "private-view-teacher",
    "operator_prompt": OperatorPrompt,
    "train_examples": trainRows.len,
    "validation_examples": validationRows.len,
    "runs": runs
  }) & "\n")
  for name in ["train.jsonl", "validation.jsonl", "trajectories.jsonl", "manifest.json"]:
    setFilePermissions(output / name, {fpUserRead, fpUserWrite})
  echo "train=", trainRows.len, " validation=", validationRows.len
