## The game sends one private view per active model seat before taking actions.

import std/[json, options, strutils, unicode, unittest]
import bitworld/decision_trajectory
import support/helpers
import lantern/[decision, llm, server]

type ExchangeMode = enum valid, invalid, missing, noCredentials, canceled
var
  mode: ExchangeMode
  batches: seq[seq[JsonNode]]
  deadlines: seq[int]

proc actionFor(request: JsonNode): string =
  $ %*{
    "type": "action", "protocol": "lantern.player.v3",
    "decision_id": request["decision_id"], "source": "external", "training_attempt": nil,
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
      of canceled:
        result[position] = $(%*{"type": "attempt_interrupted", "training_attempt": nil})
      of noCredentials:
        result[position] = $ %*{
          "type": "action", "protocol": "lantern.player.v3",
          "decision_id": request["decision_id"], "source": "fallback",
          "cause": "no_endpoint", "training_attempt": nil}

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
      check request["observation"]["turn"].getInt() == 0
      check request["observation"]["you"]["alias"].getStr() ==
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
      check request["observation"]["half"].getInt() == 1

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

  test "external policies cannot assert server-owned teacher or human origins":
    let sim = testSim(prep = 240, hunt = 480)
    for origin in [aoTeacher, aoHuman]:
      let evidence = newDecisionAttempt("asserted", "external-policy", origin)
      let reply = %*{"type": "action", "protocol": "lantern.player.v3", "decision_id": "fixture-1",
        "source": "llm", "order": {"intent": "wait"},
        "training_attempt": evidence.attemptEvidenceJson()}
      let proposal = playerProposal($reply, "fixture-1", 0, 1, sim)
      check proposal.kind == pkAccepted
      check proposal.evidence.origin == aoUnknown
      check proposal.evidence.accepted

  test "model evidence cannot label a different installed order":
    let sim = testSim(prep = 240, hunt = 480)
    var evidence = newDecisionAttempt("sampled", "model-policy", aoModel)
    evidence.response = %"{\"intent\":\"wait\"}"
    let reply = %*{"type": "action", "protocol": "lantern.player.v3", "decision_id": "fixture-1",
      "source": "llm", "order": {"intent": "hide", "target": [240, 329]},
      "training_attempt": evidence.attemptEvidenceJson()}
    let proposal = playerProposal($reply, "fixture-1", 0, 1, sim)
    check proposal.kind == pkRejected
    check not proposal.evidence.accepted
    check proposal.evidence.parsedAction["intent"].getStr() == "wait"

  test "unjoined or partial received completions cannot select a model action":
    let sim = testSim(prep = 240, hunt = 480)
    for (complete, joined) in [(false, true), (true, false), (true, true)]:
      var evidence = newDecisionAttempt("fixture-1-model", "model-policy", aoModel)
      evidence.response = %"{\"intent\":\"wait\"}"
      evidence.model = some("actual-model")
      evidence.rawResponse = %($(%*{"model": "actual-model",
        "content": [{"type": "text", "text": evidence.response.getStr()}]}))
      evidence.responseComplete = some(complete)
      evidence.responseReaderJoined = some(joined)
      evidence.httpStatus = some(200)
      let reply = %*{"type": "action", "protocol": "lantern.player.v3", "decision_id": "fixture-1",
        "source": "llm", "response": evidence.response,
        "training_attempt": evidence.attemptEvidenceJson()}
      let proposal = playerProposal($reply, "fixture-1", 0, 1, sim)
      check proposal.kind == (if complete and joined: pkAccepted else: pkRejected)
      check proposal.evidence.accepted == (complete and joined)

  test "interruption ends the shared retry budget before another request":
    let sim = testSim(prep = 240, hunt = 480)
    reset(canceled)
    let decisions = decideAll(sim, 1, activeSeats(sim, 1, actBuild),
      newSeq[ScriptKind](sim.seats), false, exchange)
    check batches.len == 1
    for decision in decisions:
      check decision.selectedAttemptId.isNone
      check decision.attempts.len == 1
      check not decision.attempts[0].accepted
      check decision.attempts[0].rejectionReason == some("episode interrupted before engine order installation")

  test "configured short turns cap both shared retry windows":
    let sim = testSim(prep = 240, hunt = 480)
    sim.config.turnBudgetMs = 100
    reset(invalid)
    discard decideAll(sim, 1, activeSeats(sim, 1, actBuild),
      newSeq[ScriptKind](sim.seats), false, exchange)
    check deadlines.len == 2
    check deadlines[0] <= 100 and deadlines[0] > 0
    check deadlines[1] <= deadlines[0] and deadlines[1] > 0
