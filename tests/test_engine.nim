## The game sends one private view per active model seat before taking actions.

import std/[json, strutils, unicode, unittest]
import curly
import support/helpers
import lantern/[decision, llm, server]

type ExchangeMode = enum valid, invalid, missing, noCredentials
var
  mode: ExchangeMode
  batches: seq[seq[JsonNode]]
  deadlines: seq[int]

proc actionFor(request: JsonNode): string =
  $ %*{
    "type": "action", "protocol": "lantern.player.v2",
    "id": request["id"], "source": "llm",
    "order": {"intent": "hide", "target": [240, 329],
              "crawl": true, "note": "settling behind a crate"}
  }

proc exchange(requests: seq[JsonNode], timeoutMs: int):
    seq[string] {.gcsafe.} =
  {.gcsafe.}:
    batches.add(requests)
    deadlines.add(timeoutMs)
    result = newSeq[string](requests.len)
    for position, request in requests:
      case mode
      of valid: result[position] = actionFor(request)
      of invalid: result[position] = "not json"
      of missing: discard
      of noCredentials:
        result[position] = $ %*{
          "type": "action", "protocol": "lantern.player.v2",
          "id": request["id"], "source": "fallback",
          "cause": "no_credentials"}

proc reset(which: ExchangeMode) =
  mode = which
  batches = @[]
  deadlines = @[]

suite "ordinary player decisions":
  test "all active seats see one pre-action state in one batch":
    let sim = testSim(prep = 240, hunt = 480)
    reset(valid)
    let buildSeats = activeSeats(sim, 1, actBuild)
    let decisions = decideAll(sim, 1, buildSeats,
      newSeq[ScriptKind](sim.seats), false, exchange)
    check batches.len == 1
    check batches[0].len == TeamSize
    for position, request in batches[0]:
      check request["slot"].getInt() == buildSeats[position]
      check request["role"].getStr() == "hider"
      check request["view"]["turn"].getInt() == 0
      check request["view"]["you"]["alias"].getStr() ==
        aliasOfSlot(buildSeats[position])
      check decisions[position].source == osLlm
      check decisions[position].order.intent == inHide
    sim.jumpToHunt()
    reset(valid)
    discard decideAll(sim, 1, activeSeats(sim, 1, actHunt),
      newSeq[ScriptKind](sim.seats), false, exchange)
    check batches.len == 1
    check batches[0].len == Seats
    for request in batches[0]:
      check request["view"]["half"].getInt() == 1

  test "an invalid action retries once and then plays warden":
    let sim = testSim()
    reset(invalid)
    let decisions = decideAll(sim, 1, activeSeats(sim, 1, actBuild),
      newSeq[ScriptKind](sim.seats), false, exchange)
    check deadlines == @[sim.config.attempt1Ms, sim.config.attempt2Ms]
    check batches.len == 2
    for decision in decisions:
      check decision.source == osFallback
      check decision.notes.len == 2
      check decision.notes[0].cause == fcParseError
      check legalFor(decision.order.intent, roHider)

  test "missing replies share bounded deadlines":
    let sim = testSim()
    reset(missing)
    let decisions = decideAll(sim, 1, activeSeats(sim, 1, actBuild),
      newSeq[ScriptKind](sim.seats), false, exchange)
    check batches.len == 2
    check deadlines == @[8500, 3500]
    for decision in decisions:
      check decision.source == osFallback
      check decision.notes[0].cause == fcTimeout

  test "credential-free players report fallback without a retry":
    let sim = testSim()
    reset(noCredentials)
    let decisions = decideAll(sim, 1, activeSeats(sim, 1, actBuild),
      newSeq[ScriptKind](sim.seats), false, exchange)
    check batches.len == 1
    for decision in decisions:
      check decision.source == osFallback
      check decision.notes.len == 1
      check decision.notes[0].cause == fcNoCredentials

  test "scripted seats do not receive decisions":
    let sim = testSim()
    reset(valid)
    var scripted = newSeq[ScriptKind](sim.seats)
    let seats = activeSeats(sim, 1, actBuild)
    scripted[seats[0]] = skWarden
    let decisions = decideAll(sim, 1, seats, scripted, false, exchange)
    check batches[0].len == TeamSize - 1
    check decisions[0].source == osScripted

  test "the budget guard keeps orders game-owned":
    let sim = testSim()
    reset(valid)
    let decisions = decideAll(sim, 1, activeSeats(sim, 1, actBuild),
      newSeq[ScriptKind](sim.seats), true, exchange)
    check batches.len == 0
    for decision in decisions:
      check decision.source == osFallback
      check decision.notes[0].cause == fcBudgetGuard

suite "the roster":
  test "an absent seat plays warden":
    let roster = initRoster(testConfig())
    check policyKind(roster.seats[0]) == "scripted"
    check roster.scriptKinds()[0] == skWarden

  test "prompt and external policies register without sending model instructions":
    var roster = initRoster(testConfig())
    roster.applyRegister(0, %*{"type": "register", "kind": "prompt",
                                "policy": "prompt"})
    roster.applyRegister(1, %*{"type": "register", "kind": "external",
                                "policy": "external"})
    check policyKind(roster.seats[0]) == "llm"
    check policyKind(roster.seats[1]) == "llm"
    check roster.scriptKinds()[0] == skNone
    check roster.scriptKinds()[1] == skNone

  test "invalid registration leaves the warden baseline intact":
    var roster = initRoster(testConfig())
    expect LanternError:
      roster.applyRegister(2, %*{
        "type": "register", "kind": "scripted", "scripted": "unknown"})
    check roster.scriptKinds()[2] == skWarden

suite "provider text remains rune-safe":
  test "a non-ASCII throttle body has valid UTF-8 in its error":
    let client = newLlmClient()
    var response: Response
    response.code = 429
    response.body = "\u{1F526}".repeat(400)
    var message = ""
    try:
      discard client.textOf(response, "", "https://api.anthropic.com")
    except CatchableError as error:
      message = error.msg
    check validateUtf8(message) == -1
    check "\u{1F526}" in message

  test "a non-ASCII authentication body has valid UTF-8":
    let client = newLlmClient()
    var response: Response
    response.code = 401
    response.body = "\u20AC".repeat(500)
    var message = ""
    try:
      discard client.textOf(response, "", "https://api.anthropic.com")
    except CatchableError as error:
      message = error.msg
    check validateUtf8(message) == -1
    check "\u20AC" in message

  test "a cut-off non-ASCII model reply has valid UTF-8":
    let client = newLlmClient()
    var response: Response
    response.code = 200
    response.body = $ %*{
      "stop_reason": "max_tokens",
      "content": [{"type": "text", "text": "alcove \u00E9 " &
        "\u{1F526}".repeat(200)}]}
    var message = ""
    try:
      discard client.textOf(response, "", "https://api.anthropic.com")
    except CatchableError as error:
      message = error.msg
    check validateUtf8(message) == -1
    check "\u{1F526}" in message

suite "result and replay on interrupted episodes":
  test "a sim fault scores one half and keeps a replay":
    let sim = testSim(prep = 240, hunt = 480)
    while sim.tick < 700:
      sim.prepareTick()
      let controls = compileControls(sim)
      for control in controls:
        sim.controls.add(control)
      sim.applyTick(controls)
    let results = sim.scriptedResults(erFault, edSimFault)
    for value in results["scores"]:
      check value.getFloat() == 0.5
    check results["winner"].kind == JNull
    check results["final_tick"].getInt() == 700
    var kinds: seq[string]
    for _ in 0 ..< sim.seats:
      kinds.add("scripted")
    let partial = buildReplay(sim, kinds, results)
    check partial["tick_count"].getInt() == 700
    check partial["keyframes"].len > 0

  test "a wall-clock stop before half two's hunt scores one half":
    let sim = testSim(prep = 240, hunt = 480)
    while sim.tick < 800:
      sim.prepareTick()
      sim.applyTick(compileControls(sim))
    check sim.huntTicksPlayed[1] == 0
    let results = sim.scriptedResults(erDeadline, edWallClock)
    for value in results["scores"]:
      check value.getFloat() == 0.5
    check results["reason"].getStr() == "deadline"
    check results["end_rule"].getStr() == "wall_clock"
