## Persistent JSONL bridge for Metta RL and native PufferLib.
## nim c -d:release --path:src -o:lantern-train-bridge tools/train_bridge.nim

import std/[json, os]
import lantern/[arena, baselines, config, control, crates, labels, llm, orders, render,
                replay, rules, server, sim, types]

const
  OperatorPrompt = "Play both roles to maximize your team's hidden time advantage."
  Variants = ["default", "sprint"]
  Intents = ["push", "lock", "hide", "flee", "scout", "wait", "sweep",
    "beeline", "chase", "pry", "hold"]
  Aims = ["sweep", "hold", "track", "target"]
  States = ["loose", "locked", "broken"]
  Bands = ["cold", "cool", "warm", "hot", "burning"]
  Sounds = ["step", "push", "break"]

proc seedOf(value: string): int =
  var hash = 2166136261'u32
  for ch in value:
    hash = (hash xor uint32(ord(ch))) * 16777619'u32
  int(hash and 0x7fffffff'u32) + 1

proc heads(): JsonNode =
  result = newJArray()
  for name in ["intent", "target_x", "target_y", "crate", "aim", "crawl"]:
    var options = newJArray()
    case name
    of "intent":
      for value in Intents: options.add(%value)
    of "target_x":
      for value in TargetMinX .. TargetMaxX: options.add(%value)
    of "target_y":
      for value in TargetMinY .. TargetMaxY: options.add(%value)
    of "crate":
      for value in -1 .. 9: options.add(%value)
    of "aim":
      for value in Aims: options.add(%value)
    of "crawl": options = %*[false, true]
    else: raise newException(ValueError, "unknown action head")
    result.add(%*{"name": name, "choices": options})

proc number(node: JsonNode): float =
  case node.kind
  of JInt: node.getInt().float
  of JFloat: node.getFloat()
  else: raise newException(ValueError, "expected numeric observation")

proc addNumbers(values: var JsonNode, node: JsonNode) =
  for item in node: values.add(%item.number())

proc code(text: string, options: openArray[string]): int =
  for index, value in options:
    if text == value: return index + 1
  raise newException(ValueError, "unknown observation category: " & text)

proc aliasCode(text: string): int =
  for seat in 0 ..< Seats:
    if text == aliasOfSlot(seat): return seat + 1
  raise newException(ValueError, "unknown seat alias: " & text)

proc addActors(values: var JsonNode, rows: JsonNode, limit: int,
    fields: openArray[string]) =
  doAssert rows.len <= limit
  values.add(%rows.len)
  for index in 0 ..< limit:
    if index < rows.len:
      let row = rows[index]
      values.add(%1)
      values.add(%aliasCode(row["alias"].getStr()))
      for field in fields:
        values.add(%row[field].number())
      values.addNumbers(row["pos"])
      values.add(%(if row.hasKey("lit_by"):
        aliasCode(row["lit_by"].getStr()) else: 0))
    else:
      for _ in 0 ..< fields.len + 5: values.add(%0)

proc values(view: JsonNode, variant: string, seat: int): JsonNode =
  result = newJArray()
  for name in Variants: result.add(%(if variant == name: 1 else: 0))
  for index in 0 ..< Seats: result.add(%(if seat == index: 1 else: 0))
  for field in ["turn", "of", "half"]: result.add(%view[field].number())
  result.add(%(if view["act"].getStr() == "build": 0 else: 1))
  result.add(%view["clock"]["act_left_s"].number())
  let isHider = view.hasKey("crates")
  result.add(%(if isHider: 1 else: 0))
  result.add(%(if isHider and view["clock"].hasKey("hunt_left_s"):
    view["clock"]["hunt_left_s"].number() else: 0.0))
  let me = view["you"]
  result.addNumbers(me["pos"])
  result.add(%me["aim"].number())
  result.add(%(if isHider and me["crawl"].getBool(): 1 else: 0))
  result.add(%(if isHider and me["found"].getBool(): 1 else: 0))
  result.add(%(if isHider: me["hidden_s"].number() else: 0.0))
  result.add(%(if isHider: me["locks_left"].number() else: 0.0))
  result.add(%(if isHider: 0 else: code(me["heartbeat"].getStr(), Bands)))
  result.add(%(if isHider or me["prying"].kind == JNull: 0
    else: parseCrateId(me["prying"].getStr(), 10) + 1))
  let map = view["map"]
  for field in ["w", "h"]: result.add(%map[field].number())
  result.addNumbers(map["pen"])
  doAssert map["walls"].len == 36 and map["nooks"].len == 3
  for wall in map["walls"]: result.addNumbers(wall)
  for nook in map["nooks"]:
    result.addNumbers(nook["anchor"])
    for edge in nook["opening"]: result.addNumbers(edge)
  let crates = if isHider: view["crates"] else: view["lit"]["crates"]
  doAssert crates.len <= 10
  result.add(%crates.len)
  for index in 0 ..< 10:
    if index < crates.len:
      let crate = crates[index]
      result.add(%(parseCrateId(crate["id"].getStr(), 10) + 1))
      result.addNumbers(crate["pos"])
      result.add(%code(crate["state"].getStr(), States))
    else:
      for _ in 0 ..< 4: result.add(%0)
  let team = view["team"]
  doAssert team.len == 3
  for mate in team:
    result.addNumbers(mate["pos"])
    if isHider:
      result.add(%(if mate["found"].getBool(): 1 else: 0))
      result.add(%mate["hidden_s"].number())
    else:
      result.add(%mate["aim"].number())
      result.add(%code(mate["heartbeat"].getStr(), Bands))
  if isHider:
    result.addActors(view["seekers_seen"], 3, ["aim", "dist"])
    let beams = view["beams"]
    doAssert beams.len <= 3
    result.add(%beams.len)
    for index in 0 ..< 3:
      if index < beams.len:
        result.add(%beams[index]["bearing"].number())
        result.add(%code(beams[index]["band"].getStr(), ["near", "mid", "far"]))
      else:
        result.add(%0)
        result.add(%0)
    result.add(%0)
    for _ in 0 ..< 3:
      for _ in 0 ..< 6: result.add(%0)
    result.add(%0)
    for _ in 0 ..< 3:
      for _ in 0 ..< 4: result.add(%0)
    result.add(%0)
  else:
    result.add(%0)
    for _ in 0 ..< 3:
      for _ in 0 ..< 7: result.add(%0)
    result.add(%0)
    for _ in 0 ..< 3:
      for _ in 0 ..< 2: result.add(%0)
    result.addActors(view["lit"]["hiders"], 3, ["streak_ticks"])
    result.add(%view["found"].len)
    doAssert view["found"].len <= 3
    for index in 0 ..< 3:
      if index < view["found"].len:
        let found = view["found"][index]
        result.add(%aliasCode(found["alias"].getStr()))
        result.add(%found["at_s"].number())
        result.add(%aliasCode(found["by"].getStr()))
        result.add(%code(found["mode"].getStr(), ["beam", "tag"]))
      else:
        for _ in 0 ..< 4: result.add(%0)
    result.add(%view["hiders_left"].number())
  let sounds = view["sounds"]
  doAssert sounds.len <= 64
  result.add(%sounds.len)
  for index in 0 ..< 64:
    if index < sounds.len:
      let sound = sounds[index]
      result.add(%code(sound["kind"].getStr(), Sounds))
      result.addNumbers(sound["pos"])
      result.add(%sound["age_ticks"].number())
    else:
      for _ in 0 ..< 4: result.add(%0)
  result.add(%view["found_count"].number())
  let last = view["your_last_order"]
  result.add(%(if last.kind == JNull: 0 else: 1))
  if last.kind == JNull:
    for _ in 0 ..< 7: result.add(%0)
  else:
    result.add(%code(last["intent"].getStr(), Intents))
    result.addNumbers(last["target"])
    result.add(%(if last["crate"].kind == JNull: 0
      else: parseCrateId(last["crate"].getStr(), 10) + 1))
    result.add(%code(last["aim"].getStr(), Aims))
    result.add(%(if last["crawl"].getBool(): 1 else: 0))
    result.add(%0)

proc action(order: Order): JsonNode =
  %*{"intent": $order.intent, "target_x": order.target.x,
    "target_y": order.target.y, "crate": order.crate,
    "aim": $order.aim, "crawl": order.crawl}

proc hostedOrder(candidate: JsonNode): JsonNode =
  %*{"intent": candidate["intent"], "target": [candidate["target_x"],
    candidate["target_y"]], "crate": candidate["crate"],
    "aim": candidate["aim"], "crawl": candidate["crawl"]}

proc decision(view: JsonNode, seat, id: int): JsonNode =
  var properties = newJObject()
  var required = newJArray()
  for head in heads():
    let name = head["name"].getStr()
    properties[name] = %*{"enum": head["choices"]}
    required.add(%name)
  %*{"kind": "decision", "game": "lantern", "decision_id": id,
    "seat": seat, "engine_seat": seat, "turn": view["turn"],
    "semantic_view": view, "inbox": [],
    "messages": [{"role": "system", "content": SystemPrompt},
      {"role": "user", "content": OperatorPrompt & "\n\n" & $view}],
    "speech_messages": [],
    "action_schema": {"type": "object", "properties": properties,
      "required": required}, "typed_question": newJNull()}

when isMainModule:
  let args = commandLineParams()
  if args.len != 2: quit("usage: lantern-train-bridge MANIFEST VARIANT", 1)
  let variant = args[1]
  doAssert variant in Variants
  let manifest = parseFile(args[0])
  var variantConfig: JsonNode
  for entry in manifest["variants"]:
    if entry["id"].getStr() == variant: variantConfig = entry["game_config"]
  doAssert not variantConfig.isNil
  var game: Sim
  var active: seq[int]
  var views: array[Seats, JsonNode]
  var id = 0
  var index = 0
  while not stdin.endOfFile:
    let request = parseJson(stdin.readLine())
    var response: JsonNode
    case request["kind"].getStr()
    of "reset":
      doAssert request["players"].getInt() == Seats
      var gameConfig = defaultGameConfig()
      let runtime = copy(variantConfig)
      runtime["tokens"] = %*["t0", "t1", "t2", "t3", "t4", "t5"]
      runtime["seed"] = %seedOf(request["seed"].getStr())
      gameConfig.update($runtime)
      let mapFile = parentDir(args[0]) / "data" /
        (gameConfig.mapPath & ".mapspec.json")
      game = newSim(gameConfig, parseMapSpec(readFile(mapFile)))
      game.prepareTick()
      let phase = phaseAt(gameConfig, game.tick)
      active = activeSeats(game, phase.half, phase.act)
      doAssert active.len > 0
      for seat in active: views[seat] = seatView(game, seat)
      index = 0
      id = 0
      response = views[active[index]].decision(active[index], id)
    of "encode":
      doAssert game.tick < totalTicks(game.config)
      let seat = active[index]
      response = %*{"decision_id": id,
        "values": views[seat].values(variant, seat), "action_heads": heads()}
    of "teacher":
      doAssert game.tick < totalTicks(game.config)
      let phase = phaseAt(game.config, game.tick)
      let seat = active[index]
      response = %*{"response": $action(scriptedOrder(game, seat, phase.half,
        if seat mod 2 == 0: skWarden else: skMoth))}
    of "step":
      doAssert game.tick < totalTicks(game.config) and
        request["decision_id"].getInt() == id
      let candidate = parseJson(request["response"].getStr())
      for head in heads():
        doAssert candidate[head["name"].getStr()] in head["choices"]
      let seat = active[index]
      let phase = phaseAt(game.config, game.tick)
      let cog = game.cogs[seat]
      let parsed = parseOrder(candidate.hostedOrder(),
        roleOfSlot(seat, phase.half), Point(x: cog.px, y: cog.py), game.crates)
      game.cogs[seat].order = parsed
      game.cogs[seat].orderSource = osLlm
      game.cogs[seat].hasOrder = true
      inc id
      inc index
      var observation: JsonNode
      if index < active.len:
        observation = views[active[index]].decision(active[index], id)
      else:
        while game.tick < totalTicks(game.config):
          game.applyTick(compileControls(game))
          if game.tick < totalTicks(game.config):
            game.prepareTick()
            if isTurnStart(game.config, game.tick):
              let nextPhase = phaseAt(game.config, game.tick)
              active = activeSeats(game, nextPhase.half, nextPhase.act)
              if active.len > 0:
                for actor in active: views[actor] = seatView(game, actor)
                break
        if game.tick == totalTicks(game.config):
          let kinds = @["scripted", "scripted", "scripted", "scripted",
            "scripted", "scripted"]
          let zeros = newSeq[int](Seats)
          let causes = newSeq[array[FallbackCause, int]](Seats)
          let outcome = buildResults(game, kinds, zeros, zeros, causes,
            erComplete, edFullTime)
          var scores = newJObject()
          for actor in 0 ..< Seats: scores[$actor] = outcome["scores"][actor]
          observation = %*{"kind": "terminal", "scores": scores}
        else:
          index = 0
          observation = views[active[index]].decision(active[index], id)
      response = %*{"kind": "accepted", "action": candidate,
        "observation": observation}
    else:
      raise newException(ValueError, "unknown command: " & request["kind"].getStr())
    stdout.writeLine($response)
    stdout.flushFile()
