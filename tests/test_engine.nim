## The decision loop against a FAKE LLM client.
##
## The property this file exists for: lantern is a simultaneous-decision game,
## so every open seat's request goes out in ONE PARALLEL BATCH per turn. A
## sequential walk over six seats is what blows the play budget, and it is
## invisible from the outside unless something counts the batches.

import std/[json, os, strutils, times, unicode, unittest]
import curly
import support/helpers
import lantern/[llm, server]

type Recorded = object
  batchSizes: seq[int]
  timeouts: seq[int]
  windows: seq[(int, int)]
  seatsSeen: seq[seq[int]]

var recorded: Recorded

proc resetRecorder() =
  recorded = Recorded()

proc fakeSender(reply: string, delayMs = 0): auto =
  ## A batch transport that answers every request with the same text and
  ## records the in-flight window each request had. One call = one parallel
  ## batch, so every request in a batch shares a window and they all
  ## intersect; a sequential implementation could not produce that.
  proc sender(client: LlmClient, requests: seq[LlmRequest],
              timeoutSeconds: int): seq[LlmReply] {.gcsafe.} =
    {.gcsafe.}:
      let started = int(epochTime() * 1000.0)
      if delayMs > 0:
        sleep(delayMs)
      let ended = int(epochTime() * 1000.0)
      recorded.batchSizes.add(requests.len)
      recorded.timeouts.add(timeoutSeconds)
      recorded.windows.add((started, ended))
      var seats: seq[int]
      for request in requests:
        seats.add(request.seat)
      recorded.seatsSeen.add(seats)
      result = newSeq[LlmReply](requests.len)
      for index in 0 ..< requests.len:
        result[index] = LlmReply(text: reply, startMs: started, endMs: ended)
  sender

proc timeoutSender(): auto =
  proc sender(client: LlmClient, requests: seq[LlmRequest],
              timeoutSeconds: int): seq[LlmReply] {.gcsafe.} =
    {.gcsafe.}:
      recorded.batchSizes.add(requests.len)
      recorded.timeouts.add(timeoutSeconds)
      result = newSeq[LlmReply](requests.len)
      for index in 0 ..< requests.len:
        result[index] = LlmReply(error: "Operation timed out after 8500 ms")
  sender

proc testClient(sender: auto): LlmClient =
  result = newLlmClient(testConfig())
  result.disabled = false
  result.transport = ltAnthropic
  result.sender = sender

const GoodHider = """{"intent":"hide","target":[240,329],"crawl":true,
  "note":"settling in behind the crate","say":"holding"}"""

suite "one parallel batch per turn":
  test "a hunt turn batches six requests and a build turn three":
    let sim = testSim(prep = 240, hunt = 480)
    let scripted = newSeq[ScriptKind](sim.seats)
    let prompts = newSeq[string](sim.seats)

    resetRecorder()
    var client = testClient(fakeSender(GoodHider))
    let buildSeats = activeSeats(sim, 1, actBuild)
    check buildSeats.len == TeamSize
    discard client.decideAll(sim, 1, buildSeats, prompts, scripted, false)
    check recorded.batchSizes == @[TeamSize]

    sim.jumpToHunt()
    resetRecorder()
    client = testClient(fakeSender(GoodHider))
    let huntSeats = activeSeats(sim, 1, actHunt)
    check huntSeats.len == Seats
    discard client.decideAll(sim, 1, huntSeats, prompts, scripted, false)
    check recorded.batchSizes == @[Seats]
    ## Every request in the batch shares one in-flight window, so they all
    ## intersect. A sequential loop over six seats cannot do that.
    check recorded.windows.len == 1
    check recorded.seatsSeen[0] == huntSeats

  test "the two attempt deadlines are 9 s then 4 s, and fit the turn budget":
    let sim = testSim()
    resetRecorder()
    let client = testClient(timeoutSender())
    let seats = activeSeats(sim, 1, actBuild)
    let decisions = client.decideAll(sim, 1, seats,
      newSeq[string](sim.seats), newSeq[ScriptKind](sim.seats), false)
    check recorded.timeouts == @[9, 4]
    check recorded.timeouts[0] + recorded.timeouts[1] <=
      sim.config.turnBudgetMs div 1000
    for decision in decisions:
      check decision.source == osFallback
      check decision.notes.len == 2
      check decision.notes[0].cause == fcTimeout
      check legalFor(decision.order.intent, roHider)

  test "a hung client is bounded by the per-turn budget, not by the model":
    let sim = testSim()
    resetRecorder()
    let client = testClient(fakeSender("this is not JSON", delayMs = 40))
    let started = epochTime()
    let decisions = client.decideAll(sim, 1, activeSeats(sim, 1, actBuild),
      newSeq[string](sim.seats), newSeq[ScriptKind](sim.seats), false)
    ## Exactly two attempts, then the scripted order - never a third.
    check recorded.batchSizes.len == 2
    check epochTime() - started < 5.0
    for decision in decisions:
      check decision.source == osFallback
      check decision.notes[0].cause == fcParseError

  test "one bad reply then one good reply costs exactly one retry":
    var attempt = 0
    proc sender(client: LlmClient, requests: seq[LlmRequest],
                timeoutSeconds: int): seq[LlmReply] {.gcsafe.} =
      {.gcsafe.}:
        inc attempt
        recorded.batchSizes.add(requests.len)
        result = newSeq[LlmReply](requests.len)
        for index in 0 ..< requests.len:
          result[index] = LlmReply(
            text: (if attempt == 1: "sorry, no" else: GoodHider))
    let sim = testSim()
    resetRecorder()
    let client = testClient(sender)
    let decisions = client.decideAll(sim, 1, activeSeats(sim, 1, actBuild),
      newSeq[string](sim.seats), newSeq[ScriptKind](sim.seats), false)
    check recorded.batchSizes == @[TeamSize, TeamSize]
    for decision in decisions:
      check decision.source == osLlm
      check decision.order.intent == inHide
      check decision.notes.len == 1
      check decision.notes[0].attempt == 1

suite "degrade, never hang":
  test "the budget guard plays scripted and records why":
    let sim = testSim()
    resetRecorder()
    let client = testClient(fakeSender(GoodHider))
    let decisions = client.decideAll(sim, 1, activeSeats(sim, 1, actBuild),
      newSeq[string](sim.seats), newSeq[ScriptKind](sim.seats), true)
    check recorded.batchSizes.len == 0        ## no LLM call at all
    for decision in decisions:
      check decision.source == osFallback
      check decision.notes[0].cause == fcBudgetGuard
      check legalFor(decision.order.intent, roHider)

  test "no credentials at all falls back instantly with no network wait":
    let sim = testSim()
    resetRecorder()
    let client = newLlmClient(testConfig())   ## no env: transport ltNone
    check client.disabled
    let decisions = client.decideAll(sim, 1, activeSeats(sim, 1, actBuild),
      newSeq[string](sim.seats), newSeq[ScriptKind](sim.seats), false)
    check recorded.batchSizes.len == 0
    for decision in decisions:
      check decision.source == osFallback
      check decision.notes[0].cause == fcNoCredentials

  test "a scripted seat is never sent to the model":
    let sim = testSim()
    resetRecorder()
    let client = testClient(fakeSender(GoodHider))
    var scripted = newSeq[ScriptKind](sim.seats)
    let seats = activeSeats(sim, 1, actBuild)
    scripted[seats[0]] = skWarden
    let decisions = client.decideAll(sim, 1, seats,
      newSeq[string](sim.seats), scripted, false)
    check recorded.batchSizes == @[TeamSize - 1]
    check decisions[0].source == osScripted

  test "an episode that ends in a fault scores 0.5 and keeps its replay":
    let sim = testSim(prep = 240, hunt = 480)
    ## Stop half way, as the fault path does, and build the results from
    ## whatever was simulated.
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
    for _ in 0 ..< sim.seats: kinds.add("scripted")
    let partial = buildReplay(sim, kinds, results)
    check partial["tick_count"].getInt() == 700
    check partial["keyframes"].len > 0

  test "a wall-clock stop before half 2's hunt is a 0.5 deadline":
    let sim = testSim(prep = 240, hunt = 480)
    while sim.tick < 800:                 ## half 2 build, no half-2 hunt yet
      sim.prepareTick()
      sim.applyTick(compileControls(sim))
    check sim.huntTicksPlayed[1] == 0
    let results = sim.scriptedResults(erDeadline, edWallClock)
    for value in results["scores"]:
      check value.getFloat() == 0.5
    check results["reason"].getStr() == "deadline"
    check results["end_rule"].getStr() == "wall_clock"
    check results["halves_played"].getInt() == 1

suite "the roster":
  test "a seat that never registers plays warden, and says so":
    var roster = initRoster(testConfig())
    check roster.seats[0].scripted == skNone
    check policyKind(roster.seats[0]) == "scripted"
    let sim = testSim()
    let order = scriptedOrder(sim, 0, 1, roster.seats[0].scripted)
    check legalFor(order.intent, roHider)

  test "registering a prompt makes the seat an llm seat and caps the prompt":
    var roster = initRoster(testConfig())
    roster.applyRegister(0, %*{"type": "register", "prompt": "hide well",
                               "policy": "lantern-warren"})
    check policyKind(roster.seats[0]) == "llm"
    check roster.prompts()[0] == "hide well"
    roster.applyRegister(1, %*{"type": "register",
                               "prompt": "x".repeat(MaxPromptRunes + 500)})
    check roster.seats[1].prompt.runeLen == MaxPromptRunes

  test "a mid-match disconnect degrades to warden and revives on reconnect":
    var roster = initRoster(testConfig())
    roster.applyRegister(2, %*{"type": "register", "prompt": "seek by sound"})
    check policyKind(roster.seats[2]) == "llm"
    roster.seats[2].connected = false
    ## The prompt survives the socket: a seat that comes back is the same
    ## policy it was, and while it is away the server plays its cog.
    check roster.prompts()[2] == "seek by sound"
    roster.seats[2].connected = true
    check policyKind(roster.seats[2]) == "llm"

suite "captured provider errors are rune-safe all the way to the replay":
  ## `textOf` slices provider and model text into the message it raises;
  ## `curlySender` stores that message verbatim, `decideAll` copies it into
  ## the fallback note, and the server emits it as a `fallback` event. A byte
  ## slice anywhere on that path puts half a codepoint in the replay, which
  ## renders in a browser and then fails the platform's strict parse.
  const Torch = "\u{1F526}"            ## 4 bytes per rune
  const Accent = "\u00e9"              ## 2 bytes per rune
  const Euro = "\u20AC"                ## 3 bytes per rune: 400 is not a multiple

  proc capturedSender(response: Response): auto =
    ## Exactly `curlySender`'s capture: `textOf` raises, the message is
    ## stored in `LlmReply.error` verbatim.
    proc sender(client: LlmClient, requests: seq[LlmRequest],
                timeoutSeconds: int): seq[LlmReply] {.gcsafe.} =
      {.gcsafe.}:
        result = newSeq[LlmReply](requests.len)
        for index in 0 ..< requests.len:
          try:
            result[index].text = client.textOf(response, "",
                                               "https://api.anthropic.com")
          except CatchableError as error:
            result[index].error = error.msg
    sender

  proc replayBytesFor(response: Response): (string, seq[string]) =
    ## Drive the whole path once and hand back the replay bytes plus every
    ## `fallback` detail that reached them.
    let sim = testSim()
    let client = testClient(capturedSender(response))
    let seats = activeSeats(sim, 1, actBuild)
    let decisions = client.decideAll(sim, 1, seats,
      newSeq[string](sim.seats), newSeq[ScriptKind](sim.seats), false)
    var details: seq[string]
    var noted = 0
    for index, slot in seats:
      check decisions[index].source == osFallback
      check decisions[index].notes.len >= 1
      for note in decisions[index].notes:
        inc noted
        sim.emit(fallbackEvent(sim.tick, 0, slot, note.attempt, note.cause,
                               note.detail))
    for event in sim.events:
      if event{"type"}.getStr() == "fallback":
        details.add(event["detail"].getStr())
    check details.len == noted
    var kinds: seq[string]
    for _ in 0 ..< sim.seats: kinds.add("scripted")
    ($buildReplay(sim, kinds, sim.scriptedResults()), details)

  test "a 429 body of 4-byte runes lands in the replay as valid UTF-8":
    var response: Response
    response.code = 429
    response.body = Torch.repeat(400)     ## 1600 bytes, 400 runes
    let (bytes, details) = replayBytesFor(response)
    check validateUtf8(bytes) == -1
    for detail in details:
      check validateUtf8(detail) == -1
      check detail.runeLen <= MaxDetailRunes
      check Torch in detail

  test "a 401 body of 3-byte runes lands in the replay as valid UTF-8":
    var response: Response
    response.code = 401
    response.body = Euro.repeat(500)      ## byte 400 lands inside a rune
    let (bytes, details) = replayBytesFor(response)
    check validateUtf8(bytes) == -1
    for detail in details:
      check validateUtf8(detail) == -1

  test "a max_tokens reply of the MODEL's own non-ASCII text is rune-safe":
    ## The most reachable of the four slices: `result` here is the model's
    ## generated text, and the system prompt invites non-ASCII in `note`/`say`.
    var response: Response
    response.code = 200
    response.body = $ %*{
      "stop_reason": "max_tokens",
      "content": [{"type": "text",
                   "text": "alcove " & Accent & " " & Torch.repeat(200)}]}
    let (bytes, details) = replayBytesFor(response)
    check validateUtf8(bytes) == -1
    for detail in details:
      check validateUtf8(detail) == -1
      check detail.runeLen <= MaxDetailRunes
