## Lantern game server: the Coworld game contract, the turn loop, and the
## artifact write order.
##
## Routes:
##   GET /healthz                 - liveness
##   GET /client/replay           - the local broadcast viewer
##   GET /client/<asset>          - chrome, art, fonts
##   GET /replay-data             - the replay JSON, in replay mode
##   WS  /player?slot=N&token=T   - the player protocol
##   WS  /global                  - the spectator snapshot stream
##
## Player protocol (lantern.player.v3), all JSON text frames:
##   player -> game: {"type":"register","kind":...,"scripted":...,"policy":...}
##   game -> player: {"type":"welcome",...}
##                   {"type":"decision","decision_id":...,"observation":...}
##   player -> game: {"type":"action","order":...}
##                   {"type":"turn","turn":N,"tick":T,"half":H,"act":...,
##                    "role":...,"view":{...},"order_source":...}
##                   {"done":true,"result":{...}}

import std/[base64, json, locks, math, monotimes, os, sets, strutils, options, sysrand, tables, times]
import bitworld/[runtime, decision_trajectory, artifact_runtime, native_http, native_stop]
import mummy, mummy/routers
import types, arena, sim, rules, control, orders, decision,
       render, replay, roster, broadcast, events, labels, training_capture, llm

type
  GameState = object
    config: GameConfig
    sim: Sim
    roster: Roster
    playerSockets: Table[int, WebSocket]
    socketSlots: Table[WebSocket, int]
    pendingActions: Table[string, tuple[payload: JsonNode, receivedAt: MonoTime]]
    pendingAttempts: Table[string, JsonNode]
    completedAttempts: Table[string, JsonNode]
    decisionSeats: Table[string, int]
    decisionIssuedAt, decisionDeadlines: Table[string, MonoTime]
    decisionObservations: Table[string, JsonNode]
    decisionRetries: Table[string, bool]
    latestDecisions: Table[int, string]
    stoppedSlots, registeredSlots: HashSet[int]
    stopping: bool
    stopId: string
    stopIssuedAt, acknowledgementDeadline, episodeDeadline: MonoTime
    globalSockets: HashSet[WebSocket]
    started: bool
    finished: bool
    llmTurns: seq[int]
    fallbackTurns: seq[int]
    fallbackCauses: seq[array[FallbackCause, int]]
    lastResults: JsonNode

var
  stateLock: Lock
  state: GameState
  gameServer: Server
  replayPayloadGlobal: string

initLock(stateLock)

proc clientDir(): string =
  let appDir = getAppDir()
  for candidate in [appDir / "client", appDir / ".." / "client", "client"]:
    if dirExists(candidate):
      return candidate
  "client"

proc dataDir(): string =
  let appDir = getAppDir()
  for candidate in [appDir / "data", appDir / ".." / "data", "data"]:
    if dirExists(candidate):
      return candidate
  "data"

proc assertFileUri*(name: string) =
  ## COGAME_EVENTS_URI and COGAME_METRICS_URI are file:// only. A signed HTTP
  ## URI here would post per-tick telemetry to the platform on every episode,
  ## so refuse loudly at startup rather than discovering it in production.
  let value = getEnv(name).strip()
  if value.len == 0 or value.startsWith("file://"):
    return
  raise newException(LanternError,
    name & " must be a file:// URI (got " & value.split("://")[0] &
    "://...); lantern refuses to stream telemetry off-box")

proc writeArtifact(uri, data, contentType, methodEnv: string, deadline: MonoTime) =
  if uri.len == 0: return
  let httpMethod = case getEnv(methodEnv, "PUT").toUpperAscii()
    of "PUT": ahPut
    of "POST": ahPost
    else: raise newException(LanternError, "artifact method must be PUT or POST")
  writeCogameArtifact(uri, data, contentType, "lantern", deadline, httpMethod)

proc connectedFlags(gs: GameState): seq[bool] =
  for slot in 0 ..< gs.config.numAgents:
    result.add(gs.playerSockets.hasKey(slot))

proc playerNames(gs: GameState): seq[string] =
  for slot in 0 ..< gs.config.numAgents:
    result.add(if slot < gs.config.players.len: gs.config.players[slot].name
               else: "P" & $(slot + 1))

proc broadcastGlobalLocked(gs: GameState) =
  if gs.globalSockets.len == 0:
    return
  let payload = $snapshotJson(gs.sim, gs.playerNames(), gs.started,
                              gs.connectedFlags())
  for socket in gs.globalSockets:
    socket.send(payload)

proc pushTurnFrames(gs: GameState, sources: Table[int, string]) =
  let phase = phaseAt(gs.config, gs.sim.tick)
  for slot, socket in gs.playerSockets:
    if slot < 0 or slot >= gs.config.numAgents:
      continue
    socket.send($ %*{
      "type": "turn", "turn": phase.turn, "tick": gs.sim.tick,
      "half": phase.half, "act": $phase.act,
      "role": $roleOfSlot(slot, phase.half),
      "view": seatView(gs.sim, slot),
      "order_source": sources.getOrDefault(slot, "scripted")})

proc exchangeDecisions(requests: seq[JsonNode], timeoutMs: int):
    seq[string] {.gcsafe.} =
  ## All private requests leave before waiting on the same absolute budget.
  result = newSeq[string](requests.len)
  {.gcsafe.}:
    if interruptionRequested():
      for position in 0 ..< requests.len:
        result[position] = $(%*{"type": "attempt_interrupted", "training_attempt": nil})
      return
    let deadline = min(state.episodeDeadline - initDuration(seconds = 5),
      getMonoTime() + initDuration(milliseconds = timeoutMs))
    withLock stateLock:
      for request in requests:
        let slot = request["slot"].getInt()
        let id = request["decision_id"].getStr()
        state.decisionSeats[id] = slot
        state.decisionIssuedAt[id] = getMonoTime()
        state.decisionDeadlines[id] = deadline
        state.decisionObservations[id] = copy(request["observation"])
        state.decisionRetries[id] = request["attempt"].getInt() > 1
        state.latestDecisions[slot] = id
        let outbound = copy(request)
        outbound["transport"]["budget_ms"] = %max(0, (deadline - getMonoTime()).inMilliseconds)
        if state.playerSockets.hasKey(slot): state.playerSockets[slot].send($outbound)
    while getMonoTime() < deadline and not interruptionRequested():
      var pending = false
      withLock stateLock:
        for position, request in requests:
          if result[position].len > 0: continue
          let id = request["decision_id"].getStr()
          if state.pendingActions.hasKey(id):
            let received = state.pendingActions[id]
            state.pendingActions.del(id)
            if received.receivedAt >= state.decisionIssuedAt[id] and received.receivedAt <= deadline:
              result[position] = $received.payload
            else: pending = true
          else: pending = true
      if not pending: break
      sleep(10)
    withLock stateLock:
      for position, request in requests:
        let id = request["decision_id"].getStr()
        if result[position].len == 0:
          let kind = if interruptionRequested(): "attempt_interrupted" else: "attempt_timeout"
          if state.completedAttempts.hasKey(id):
            result[position] = $(%*{"type": kind,
              "training_attempt": state.completedAttempts[id]})
          elif state.pendingAttempts.hasKey(id):
            result[position] = $(%*{"type": kind,
              "training_attempt": state.pendingAttempts[id]})
          elif interruptionRequested():
            result[position] = $(%*{"type": kind, "training_attempt": nil})

# ---------------------------------------------------------------------------
# The turn loop.
# ---------------------------------------------------------------------------

proc activeSeats*(sim: Sim, half: int, act: Act): seq[int] =
  ## During a BUILD act only the three hiding seats are queried: the seekers
  ## are locked in the pen, blind and frozen, and are not asked for an order
  ## they could not act on. It also saves three calls per build turn.
  ##
  ## Once the hunt act of this half has ended early - every hider found - no
  ## seat is queried at all. The ticks deliberately keep running so the
  ## scoring denominator stays whole, but nothing that happens in them can
  ## change the result, so the turns those seats would have spent on the
  ## model go back to the wall-clock budget.
  if act == actHunt and sim.actEnded[half - 1]:
    return @[]
  for slot in 0 ..< sim.seats:
    let role = roleOfSlot(slot, half)
    if act == actBuild and role == roSeeker:
      continue
    if role == roHider and sim.cogs[slot].found:
      continue
    result.add(slot)

proc runEpisode(runtimeConfig: RuntimeConfig) {.gcsafe.} =
  {.gcsafe.}:
    defer: gameServer.close()
    let config = state.config
    let trajectoryUri = getEnv(CogameSaveTrajectoryUriEnv)
    let trajectory = if trajectoryUri.len > 0:
      newDecisionTrajectory(getEnv("COWORLD_EPISODE_ID"), "lantern-" & $config.seed,
        "lantern", getEnv("COWORLD_GAME_VERSION"), getEnv("COWORLD_SOURCE_REVISION"))
      else: nil
    var pendingMacros: seq[PendingMacro]
    var completedMacros: seq[CompletedMacro]
    let start = getMonoTime()
    let connectDeadline = min(state.episodeDeadline - initDuration(seconds = 5),
      start + initDuration(milliseconds = config.playerConnectTimeoutMs))
    while getMonoTime() < connectDeadline and not interruptionRequested():
      var all = false
      withLock stateLock:
        all = state.registeredSlots.len >= config.numAgents
      if all:
        break
      sleep(200)

    var missing: seq[int]
    withLock stateLock:
      state.started = true
      for slot in 0 ..< config.numAgents:
        if not state.roster.seats[slot].everConnected:
          missing.add(slot)
      echo "lantern: starting with ", state.playerSockets.len, "/",
        config.numAgents, " players connected"
      state.broadcastGlobalLocked()

    if missing.len > 0:
      ## A seat that never connects does NOT end the episode: its cog plays
      ## the warden baseline for the whole match. Report the LOWEST offending
      ## slot only, as paintbot's declarePlayerFailure does.
      echo "lantern: seat ", missing[0], " never connected; playing warden"

    var reason = erComplete
    var rule = edFullTime
    var guardEngaged = false
    let total = totalTicks(config)
    let wallDeadline = min(state.episodeDeadline - initDuration(seconds = 5),
      start + initDuration(milliseconds = config.wallClockBudgetMs))

    try:
      while true:
        var done = false
        withLock stateLock:
          done = state.sim.tick >= total
        if done:
          break
        if interruptionRequested() or getMonoTime() > wallDeadline:
          echo "lantern: wall-clock budget reached at tick ", state.sim.tick
          reason = erDeadline
          rule = edWallClock
          break

        var simRef: Sim
        var half = 1
        var act = actBuild
        var seats: seq[int]
        var scripted: seq[ScriptKind]
        var isTurn = false
        withLock stateLock:
          state.sim.prepareTick()
          let phase = phaseAt(config, state.sim.tick)
          half = phase.half
          act = phase.act
          isTurn = isTurnStart(config, state.sim.tick)
          simRef = state.sim
          if isTurn:
            seats = activeSeats(state.sim, half, act)
            scripted = state.roster.scriptKinds()
            var hidden: seq[int]
            for team in [tmMoth, tmOwl]:
              var total = 0
              for slot in slotsOfTeam(team, state.sim.seats):
                total += state.sim.cogs[slot].hiddenTicks
              hidden.add(total)
            state.sim.emit(turnStartEvent(state.sim.tick, phase.turn, half,
                                          act, hidden,
                                          state.sim.hidersLeft(half)))

        if isTurn:
          if trajectoryUri.len > 0:
            withLock stateLock:
              completedMacros.add(collectMacros(state.sim, pendingMacros))
          ## The budget guard settles early rather than overrunning: once two
          ## more full turn budgets would not fit, every remaining turn is
          ## played on the scripted layer (well under a millisecond a turn),
          ## so the episode ends complete/full_time instead of deadline.
          let remainingMs = max(0, (wallDeadline - getMonoTime()).inMilliseconds.int)
          if not guardEngaged and remainingMs < 2 * config.turnBudgetMs:
            guardEngaged = true
            withLock stateLock:
              state.sim.emit(budgetGuardEvent(state.sim.tick,
                phaseAt(config, state.sim.tick).turn, remainingMs))
            echo "lantern: budget guard engaged with ", remainingMs,
              " ms left; the rest of the match plays scripted"

          let decisions =
            if seats.len == 0: @[]
            else: decideAll(simRef, half, seats, scripted,
                            guardEngaged, exchangeDecisions)
          if interruptionRequested():
            reason = erDeadline
            rule = edWallClock
            break
          var sources: Table[int, string]
          withLock stateLock:
            let phase = phaseAt(config, state.sim.tick)
            for index, slot in seats:
              let decision = decisions[index]
              state.sim.cogs[slot].order = decision.order
              state.sim.cogs[slot].orderSource = decision.source
              state.sim.cogs[slot].hasOrder = true
              if trajectoryUri.len > 0:
                pendingMacros.add(PendingMacro(seat: slot,
                  startTick: state.sim.tick, decision: decision))
              sources[slot] = $decision.source
              if decision.source == osLlm:
                inc state.llmTurns[slot]
              elif decision.source == osFallback:
                inc state.fallbackTurns[slot]
              for note in decision.notes:
                inc state.fallbackCauses[slot][note.cause]
                state.sim.emit(fallbackEvent(state.sim.tick, phase.turn, slot,
                                             note.attempt, note.cause,
                                             note.detail))
              state.sim.emit(orderEvent(state.sim.tick, phase.turn, slot,
                                        aliasOfSlot(slot),
                                        roleOfSlot(slot, half),
                                        decision.source, decision.latencyMs,
                                        decision.order,
                                        orderCrateId(decision.order)))
            state.pushTurnFrames(sources)
            state.broadcastGlobalLocked()

        withLock stateLock:
          let controls = compileControls(state.sim)
          for control in controls:
            state.sim.controls.add(control)
          state.sim.applyTick(controls)
          if state.sim.tick mod ReplayFps == 0:
            state.sim.checkInvariants()
          if state.sim.tick mod (ReplayFps * 5) == 0:
            state.broadcastGlobalLocked()
    except LanternError as error:
      echo "lantern: sim fault: ", error.msg
      reason = erFault
      rule = edSimFault
    except CatchableError as error:
      echo "lantern: host error: ", error.msg
      reason = erFault
      rule = edHostError

    let cleanupDeadline = min(state.episodeDeadline, getMonoTime() + initDuration(seconds = 5))
    var targets: seq[int]
    withLock stateLock:
      state.stopping = true
      var nonce: array[16, byte]
      doAssert urandom(nonce), "OS entropy unavailable for stop identity"
      for value in nonce: state.stopId.add(value.toHex(2))
      state.stopIssuedAt = getMonoTime()
      state.acknowledgementDeadline = cleanupDeadline - initDuration(seconds = 1)
      for slot in state.registeredSlots:
        targets.add(slot)
        if not state.playerSockets.hasKey(slot): continue
        let id = if state.latestDecisions.hasKey(slot): %state.latestDecisions[slot] else: newJNull()
        state.playerSockets[slot].send($(%*{"type": "stop", "stop_id": state.stopId,
          "decision_id": id,
          "reason": (if interruptionRequested(): "interrupted" elif reason == erComplete: "terminal" else: "episode_deadline"),
          "cleanup_budget_ms": max(0, (state.acknowledgementDeadline - getMonoTime()).inMilliseconds)}))
    while getMonoTime() < state.acknowledgementDeadline:
      var acknowledged = true
      withLock stateLock:
        for slot in targets:
          if slot notin state.stoppedSlots: acknowledged = false
      if acknowledged: break
      sleep(10)

    var results: JsonNode
    var replayData: string
    var joined = true
    withLock stateLock:
      state.finished = true
      if trajectoryUri.len > 0:
        completedMacros.add(collectMacros(state.sim, pendingMacros, terminal = true))
      state.sim.endReason = reason
      state.sim.endRule = rule
      let kinds = state.roster.policyKinds()
      results = buildResults(state.sim, kinds, state.llmTurns,
                             state.fallbackTurns, state.fallbackCauses,
                             reason, rule)
      var scoresMilli: seq[int]
      for value in results["scores"]:
        scoresMilli.add(int(value.getFloat() * 1000.0 + 0.5))
      var fracMicro: seq[int]
      for value in results["team_hidden_frac"]:
        fracMicro.add(int(value.getFloat() * 1_000_000.0 + 0.5))
      let winner = (if results["winner"].kind == JNull: -1 else: results["winner"].getInt())
      state.sim.emit(endEvent(state.sim.tick, reason, rule, scoresMilli, fracMicro, winner))
      var cleanup = newJObject()
      for slot in targets:
        cleanup[$slot] = %(if slot in state.stoppedSlots: "acknowledged" else: "unresolved")
        if slot notin state.stoppedSlots: joined = false
      if trajectoryUri.len > 0:
        var represented = initHashSet[string]()
        for completed in completedMacros.mitems:
          for attempt in completed.pending.decision.attempts.mitems:
            let id = attempt.attemptId[0 ..< attempt.attemptId.rfind('-')]
            represented.incl(id)
            if completed.pending.decision.selectedAttemptId == some(attempt.attemptId): continue
            if state.completedAttempts.hasKey(id):
              var received = readAttemptEvidence(state.completedAttempts[id])
              if received.origin in {aoTeacher, aoHuman}: received.origin = aoUnknown
              received.accepted = attempt.accepted
              received.parsedAction = attempt.parsedAction
              received.rejectionReason = attempt.rejectionReason
              attempt = received
          trajectory.recordMacro(completed)
        # A stop or owner failure can happen after issuance but before order installation.
        # These attempts have no executed action or invented control interval.
        for id, slot in state.decisionSeats:
          if id in represented: continue
          var attempt = if state.completedAttempts.hasKey(id):
            readAttemptEvidence(state.completedAttempts[id])
            elif state.pendingAttempts.hasKey(id): readAttemptEvidence(state.pendingAttempts[id])
            else: newDecisionAttempt(id & "-unknown", "external", aoUnknown)
          if attempt.origin in {aoTeacher, aoHuman}: attempt.origin = aoUnknown
          attempt.accepted = false
          attempt.rejectionReason = some("episode stopped before engine order installation")
          trajectory.recordDecision(id, $slot, state.decisionObservations[id], @[attempt],
            none(string), newJNull(), asMissing, terminal = true)
        var outcomes = newJObject()
        for slot in 0 ..< config.numAgents: outcomes[$slot] = results["scores"][slot]
        let status = if not joined or interruptionRequested() or reason == erDeadline: esTruncated
          elif reason == erComplete: esCompleted else: esFailed
        let privateOutcome = copy(results)
        privateOutcome["player_cleanup"] = cleanup
        trajectory.finish(status, privateOutcome,
          if status == esCompleted: outcomes else: newJNull())
      state.lastResults = results
      replayData = $buildReplay(state.sim, kinds, results)
      if joined and not interruptionRequested():
        let final = %*{"done": true, "result": results}
        for slot, socket in state.playerSockets: socket.send($final)
        state.broadcastGlobalLocked()

    if trajectoryUri.len > 0:
      let httpMethod = case getEnv("COGAME_SAVE_TRAJECTORY_METHOD", "PUT")
        of "PUT": ahPut
        of "POST": ahPost
        else: raise newException(LanternError, "trajectory method must be PUT or POST")
      trajectory.writeTrajectoryArtifact(trajectoryUri, cleanupDeadline, httpMethod)
    if joined and not interruptionRequested():
      if missing.len > 0:
        writeArtifact(getEnv("COGAME_PLAYER_FAILURE_URI"),
          $ %*{"slot": missing[0], "reason": "player never connected", "slots": missing},
          "application/json", "COGAME_PLAYER_FAILURE_METHOD", cleanupDeadline)
      writeArtifact(runtimeConfig.replayUri, replayData, "application/json",
                    "COGAME_SAVE_REPLAY_METHOD", cleanupDeadline)
      writeArtifact(runtimeConfig.resultsUri, $results, "application/json",
                    "COGAME_RESULTS_METHOD", cleanupDeadline)
      ## Preserve the real spectator/ping grace without resetting artifact deadlines.
      let graceDeadline = min(state.episodeDeadline,
        getMonoTime() + initDuration(milliseconds = max(0, config.shutdownGraceMs)))
      while getMonoTime() < graceDeadline and not interruptionRequested(): sleep(50)

var gameThread: Thread[RuntimeConfig]

# ---------------------------------------------------------------------------
# HTTP / WebSocket plumbing.
# ---------------------------------------------------------------------------

proc serveFile(request: Request, path, contentType: string) =
  if fileExists(path):
    var headers: HttpHeaders
    headers["Content-Type"] = contentType
    request.respond(200, headers, readFile(path))
  else:
    request.respond(404)

proc contentTypeFor(name: string): string =
  if name.endsWith(".html"): "text/html; charset=utf-8"
  elif name.endsWith(".js"): "application/javascript; charset=utf-8"
  elif name.endsWith(".css"): "text/css; charset=utf-8"
  elif name.endsWith(".json"): "application/json"
  elif name.endsWith(".png"): "image/png"
  elif name.endsWith(".jpg"): "image/jpeg"
  elif name.endsWith(".webp"): "image/webp"
  elif name.endsWith(".ttf"): "font/ttf"
  else: "application/octet-stream"

proc splicedBroadcastPage(): string =
  ## The broadcast page is served spliced, exactly as the static bundle is:
  ## the three markers become script tags. A raw, unspliced open of the source
  ## HTML has no ChromeCommon and fails loudly rather than half-rendering.
  result = readFile(clientDir() / "replay_broadcast.html")
  result = result.replace("<!-- WIRE_CONSTANTS -->",
    "<script src=\"/client/wire_constants.js\"></script>")
  result = result.replace("<!-- CHROME_COMMON -->",
    "<script src=\"/client/chrome_common.js\"></script>")
  result = result.replace("<!-- BROADCAST_CORE -->",
    "<script src=\"/client/static_replay.js\"></script>")

proc pageHandler(name: string): RequestHandler =
  ## A static page from client/. These two routes are part of the platform's
  ## GAME CONTRACT, not decoration: the episode runner does
  ## `GET /client/player?slot=0&token=<t>` and `GET /client/global` before it
  ## starts a single player container, and a 404 on either fails
  ## certification's smoke-episode with `game_contract_violation`.
  proc handler(request: Request) {.gcsafe.} =
    {.gcsafe.}:
      serveFile(request, clientDir() / name, "text/html; charset=utf-8")
  handler

proc replayPageHandler(request: Request) {.gcsafe.} =
  {.gcsafe.}:
    let path = clientDir() / "replay_broadcast.html"
    if not fileExists(path):
      request.respond(404)
      return
    var headers: HttpHeaders
    headers["Content-Type"] = "text/html; charset=utf-8"
    request.respond(200, headers, splicedBroadcastPage())

proc clientAssetHandler(request: Request) {.gcsafe.} =
  {.gcsafe.}:
    let name = request.pathParams["name"]
    if "/" in name or "\\" in name or name.startsWith("."):
      request.respond(404)
      return
    let fromClient = clientDir() / name
    if fileExists(fromClient):
      serveFile(request, fromClient, contentTypeFor(name))
    else:
      serveFile(request, dataDir() / name, contentTypeFor(name))

proc clientArtHandler(request: Request) {.gcsafe.} =
  ## client/art/* for the live spectator page: broadcast_core.js fetches its
  ## bitmaps from ./art relative to /client/global.
  {.gcsafe.}:
    let name = request.pathParams["name"]
    if "/" in name or "\\" in name or name.startsWith("."):
      request.respond(404)
      return
    serveFile(request, clientDir() / "art" / name, contentTypeFor(name))

proc replayDataHandler(request: Request) {.gcsafe.} =
  {.gcsafe.}:
    if replayPayloadGlobal.len == 0:
      request.respond(404)
      return
    var headers: HttpHeaders
    headers["Content-Type"] = "application/json"
    request.respond(200, headers, replayPayloadGlobal)

proc healthzHandler(request: Request) {.gcsafe.} =
  var headers: HttpHeaders
  headers["Content-Type"] = "application/json"
  request.respond(200, headers, """{"ok": true}""")

proc playerUpgradeHandler(request: Request) {.gcsafe.} =
  {.gcsafe.}:
    let slotText = request.queryParams["slot"]
    let token = request.queryParams["token"]
    var slot = -1
    try:
      slot = parseInt(slotText)
    except ValueError:
      discard
    withLock stateLock:
      if not state.roster.authorised(slot, token):
        request.respond(403)
        return
      if state.started or state.stopping or state.finished or state.playerSockets.hasKey(slot):
        request.respond(409)
        return
      let websocket = request.upgradeToWebSocket()
      state.playerSockets[slot] = websocket
      state.socketSlots[websocket] = slot
      state.roster.seats[slot].connected = true
      state.roster.seats[slot].everConnected = true
      echo "lantern: player slot ", slot, " connected (",
        state.playerSockets.len, "/", state.config.numAgents, ")"
      websocket.send($ %*{
        "type": "welcome", "protocol": "lantern.player.v3", "slot": slot,
        "alias": aliasOfSlot(slot), "team": $teamOfSlot(slot),
        "hides_in_half": hidHalfOfSlot(slot),
        "turns": totalTurns(state.config)})

proc replayUpgradeHandler(request: Request) {.gcsafe.} =
  ## The replay-mode websocket. `verify_replay_loadable` in the platform's
  ## runner opens this and requires ONE non-empty message; lantern's hosted
  ## replays are the static wasm bundle, so that check is skipped, but the
  ## route is cheap and a local viewer uses the same payload.
  {.gcsafe.}:
    let websocket = request.upgradeToWebSocket()
    if replayPayloadGlobal.len > 0:
      websocket.send(replayPayloadGlobal)

proc globalUpgradeHandler(request: Request) {.gcsafe.} =
  {.gcsafe.}:
    let websocket = request.upgradeToWebSocket()
    withLock stateLock:
      state.globalSockets.incl(websocket)
      websocket.send($snapshotJson(state.sim, state.playerNames(),
                                   state.started, state.connectedFlags()))

proc validateAttemptProgress(before, evidence: JsonNode) =
  for key in ["prompt", "request", "decoder", "policy", "origin"]:
    if evidence[key] != before[key]:
      raise newException(ValueError, "native progress changed started request evidence")
  if (before["latency_ms"].kind != JNull or before["response_reader_joined"] == %true) and evidence != before:
    raise newException(ValueError, "finished native evidence is immutable")
  for key in ["response_body_b64", "response_headers_b64"]:
    if before[key].kind != JNull and
        (evidence[key].kind != JString or
          not decode(evidence[key].getStr()).startsWith(decode(before[key].getStr()))):
      raise newException(ValueError, "received native bytes cannot be rewritten")
  if before["response_complete"] == %true:
    for key in ["response_complete", "response_body_b64", "response_headers_b64"]:
      if evidence[key] != before[key]:
        raise newException(ValueError, "complete native bytes are immutable")
  for key in ["http_status", "response_headers", "platform_call_id", "provider_request_id",
      "model_identity", "tokenizer_identity", "chat_template_sha256"]:
    if before[key].kind != JNull and evidence[key] != before[key]:
      raise newException(ValueError, "received native identity is immutable")

proc websocketHandler(
  websocket: WebSocket,
  event: WebSocketEvent,
  message: Message
) {.gcsafe.} =
  {.gcsafe.}:
    case event
    of OpenEvent:
      discard
    of MessageEvent:
      let receivedAt = getMonoTime()
      ## mummy hands Ping frames to the application instead of answering
      ## them itself; the platform's certifier pings /global to check the
      ## game is alive, so an unanswered ping fails certification.
      if message.kind == Ping:
        websocket.send(message.data, Pong)
        return
      if message.kind != TextMessage:
        return
      var slot = -1
      withLock stateLock:
        slot = state.socketSlots.getOrDefault(websocket, -1)
      if slot < 0:
        return
      try:
        let payload = parseJson(message.data)
        let frameType = payload["type"].getStr()
        if frameType == "register":
          withLock stateLock:
            if state.started or state.stopping or state.finished or state.roster.seats[slot].registered:
              raise newException(ValueError, "registration is closed")
            state.roster.applyRegister(slot, payload)
            state.registeredSlots.incl(slot)
        elif frameType in ["attempt_started", "action"]:
          let id = payload["decision_id"].getStr()
          var evidence = newJNull()
          if payload["training_attempt"].kind != JNull:
            evidence = payload["training_attempt"]
            let attempt = readAttemptEvidence(evidence)
            if attempt.attemptId != id & "-model":
              raise newException(ValueError, "attempt identity differs from issued decision")
          withLock stateLock:
            if state.finished: return
            if not state.decisionSeats.hasKey(id) or state.decisionSeats[id] != slot:
              raise newException(ValueError, "decision does not belong to authenticated seat")
            if receivedAt < state.decisionIssuedAt[id]:
              raise newException(ValueError, "player frame preceded issued decision")
            if evidence.kind == JObject:
              if frameType == "action" and readAttemptEvidence(evidence).origin == aoModel and
                  not state.pendingAttempts.hasKey(id):
                raise newException(ValueError, "native completion has no recorded request start")
              if state.pendingAttempts.hasKey(id):
                validateAttemptProgress(state.pendingAttempts[id], evidence)
              if frameType == "attempt_started":
                let attempt = readAttemptEvidence(evidence)
                if attempt.origin != aoModel:
                  raise newException(ValueError, "request start must identify a native model call")
                if attempt.origin == aoModel:
                  if not state.pendingAttempts.hasKey(id) and (
                      attempt.response.kind != JNull or attempt.rawResponse.kind != JNull or
                      attempt.platformCallId.isSome or attempt.providerRequestId.isSome or
                      attempt.responseHeaders.isSome or attempt.responseHeadersB64.isSome or
                      attempt.responseBodyB64.isSome or attempt.responseComplete.isSome or
                      attempt.responseReaderJoined.isSome or attempt.httpStatus.isSome or
                      attempt.latencyMs.isSome or attempt.inputTokens.isSome or attempt.outputTokens.isSome or
                      attempt.promptTokenIds.isSome or attempt.sampledTokenIds.isSome or
                      attempt.behaviorLogprobs.isSome or attempt.stopReason.isSome or attempt.rejectionReason.isSome or
                      attempt.modelIdentity.isSome or attempt.tokenizerIdentity.isSome or attempt.chatTemplateSha256.isSome):
                    raise newException(ValueError, "first model start must precede observed response facts")
                  let view = state.decisionObservations[id]
                  let retry = state.decisionRetries[id]
                  let suffix = userPrompt(view, "", retry)
                  let user = attempt.request["messages"][0]["content"].getStr()
                  if not user.endsWith(suffix):
                    raise newException(ValueError, "native request differs from issued private observation")
                  let prefix = user[0 ..< user.len - suffix.len]
                  var guidance = ""
                  if prefix.len > 0:
                    if not prefix.endsWith("\n\n"):
                      raise newException(ValueError, "native guidance differs from production renderer")
                    guidance = prefix[0 ..< prefix.len - 2]
                  let expected = %*[{"role": "system", "content": SystemPrompt},
                    {"role": "user", "content": userPrompt(view, guidance, retry)}]
                  if attempt.prompt != expected or attempt.request["system"] != %SystemPrompt or
                      attempt.request["messages"] != %*[{"role": "user", "content": user}]:
                    raise newException(ValueError, "native prompt differs from production renderer")
                state.pendingAttempts[id] = evidence
              else:
                if state.completedAttempts.hasKey(id) and state.completedAttempts[id] != evidence:
                  raise newException(ValueError, "completion evidence is immutable")
                state.completedAttempts[id] = evidence
            if frameType == "action":
              let source = payload["source"].getStr()
              if source notin ["llm", "external", "fallback"]:
                raise newException(ValueError, "unknown action source")
              if source == "llm" and evidence.kind == JNull:
                raise newException(ValueError, "native action has no attempt evidence")
              if evidence.kind == JObject and source != "fallback":
                let attempt = readAttemptEvidence(evidence)
                if attempt.origin == aoModel:
                  if attempt.responseComplete != some(true) or
                      attempt.responseReaderJoined != some(true) or
                      attempt.httpStatus != some(200) or attempt.rejectionReason.isSome:
                    raise newException(ValueError, "native completion is not complete and joined")
                  let body = parseJson(attempt.rawResponse.getStr())
                  var text = ""
                  for contentBlock in body["content"]:
                    if contentBlock["type"].getStr() == "text": text.add(contentBlock["text"].getStr())
                  if attempt.response != %text or attempt.model != some(body["model"].getStr()):
                    raise newException(ValueError, "native body differs from completion response or model")
              state.pendingActions[id] = (payload: payload, receivedAt: receivedAt)
        elif frameType == "stopped":
          if payload["worker_status"].getStr() notin ["joined", "no_active_call"]:
            raise newException(ValueError, "unknown stopped worker status")
          if payload["attempts"].kind != JArray:
            raise newException(ValueError, "stop attempts must be an array")
          withLock stateLock:
            if state.finished: return
            let expected = if state.latestDecisions.hasKey(slot):
              %state.latestDecisions[slot] else: newJNull()
            if payload["decision_id"].kind != JNull:
              let id = payload["decision_id"].getStr()
              if not state.decisionSeats.hasKey(id) or state.decisionSeats[id] != slot:
                raise newException(ValueError, "stop acknowledgement belongs to another seat")
              for evidence in payload["attempts"]:
                let attempt = readAttemptEvidence(evidence)
                if attempt.attemptId != id & "-model":
                  raise newException(ValueError, "acknowledged attempt belongs to another decision")
                if receivedAt < state.decisionIssuedAt[id]:
                  raise newException(ValueError, "joined evidence preceded issued decision")
                if attempt.origin == aoModel and not state.pendingAttempts.hasKey(id):
                  raise newException(ValueError, "joined native evidence has no recorded request start")
                if state.pendingAttempts.hasKey(id):
                  validateAttemptProgress(state.pendingAttempts[id], evidence)
                if state.completedAttempts.hasKey(id) and state.completedAttempts[id] != evidence:
                  raise newException(ValueError, "stop changed completed evidence")
                state.completedAttempts[id] = evidence
            elif payload["attempts"].len != 0:
              raise newException(ValueError, "no-active-call acknowledgement has attempt evidence")
            # Confirm immutable fact receipt before the sender tears down its socket.
            # This does not grant stop credit or platform receipt authority.
            if state.playerSockets.hasKey(slot) and state.playerSockets[slot] == websocket:
              websocket.send($(%*{"type": "evidence_received",
                "decision_id": payload["decision_id"], "stop_id": payload["stop_id"]}))
            # Preserve genuine joined transport facts even when the player stops first.
            # They do not grant acknowledgement credit before this engine's stop window.
            if payload["decision_id"] != expected:
              raise newException(ValueError, "stop acknowledgement differs from latest decision")
            if not state.stopping:
              raise newException(ValueError, "stop acknowledgement preceded engine stop")
            if receivedAt < state.stopIssuedAt or receivedAt > state.acknowledgementDeadline:
              raise newException(ValueError, "stop acknowledgement is outside cleanup window")
            if not payload.hasKey("stop_id") or payload["stop_id"] != %state.stopId:
              raise newException(ValueError, "stop acknowledgement differs from engine stop identity")
            for evidence in payload["attempts"]:
              if readAttemptEvidence(evidence).responseReaderJoined == some(false):
                raise newException(ValueError, "stop retains an unjoined native response reader")
            state.stoppedSlots.incl(slot)
        else:
          raise newException(ValueError, "unknown player frame")
      except CatchableError as error:
        echo "lantern: ignoring invalid private player frame"
    of ErrorEvent:
      discard
    of CloseEvent:
      withLock stateLock:
        if websocket in state.socketSlots:
          let slot = state.socketSlots[websocket]
          # Parallel callbacks may dispatch an already-received final frame after close.
          # Keep its authenticated owner binding until this episode seals.
          if state.playerSockets.getOrDefault(slot) == websocket:
            state.playerSockets.del(slot)
            state.roster.seats[slot].connected = false
        state.globalSockets.excl(websocket)

proc buildRouter(replayMode: bool): Router =
  result.get("/healthz", healthzHandler)
  ## The three named client pages come BEFORE the /client/@name asset route:
  ## mummy tests routes in registration order, so the catch-all would
  ## otherwise swallow /client/player and /client/global and serve them as
  ## missing asset files.
  result.get("/client/replay", replayPageHandler)
  result.get("/client/global", pageHandler("global.html"))
  result.get("/client/player", pageHandler("player.html"))
  result.get("/client/art/@name", clientArtHandler)
  result.get("/client/@name", clientAssetHandler)
  result.get("/replay-data", replayDataHandler)
  result.get("/global", globalUpgradeHandler)
  result.get("/replay", replayUpgradeHandler)
  if not replayMode:
    result.get("/player", playerUpgradeHandler)

proc runReplayServer*(runtimeConfig: RuntimeConfig) =
  ## Replay mode serves the recorded bytes to the local broadcast viewer.
  ## The HOSTED viewer never comes here — it is the static wasm bundle,
  ## fed straight from S3.
  replayPayloadGlobal = runtimeConfig.replay
  let router = buildRouter(replayMode = true)
  gameServer = newServer(router, websocketHandler, workerThreads = 4, maxMessageLen = 16 * 1024 * 1024)
  echo "lantern: replay mode on ", runtimeConfig.host, ":", runtimeConfig.port
  gameServer.serve(Port(runtimeConfig.port), runtimeConfig.host)

proc prepareState*(config: GameConfig) =
  ## Everything runGameServer does before it opens a socket. Exposed so
  ## tests/test_server.nim can exercise the websocket contract without an episode
  ## owner closing the shared server.
  state.config = config
  state.sim = newSim(config, loadMapSpec(config.mapPath))
  state.roster = initRoster(config)
  state.pendingActions.clear()
  state.pendingAttempts.clear()
  state.completedAttempts.clear()
  state.decisionSeats.clear()
  state.decisionIssuedAt.clear()
  state.decisionDeadlines.clear()
  state.decisionObservations.clear()
  state.decisionRetries.clear()
  state.latestDecisions.clear()
  state.stoppedSlots.clear()
  state.registeredSlots.clear()
  state.playerSockets.clear()
  state.socketSlots.clear()
  state.globalSockets.clear()
  state.stopping = false
  state.stopId = ""
  state.llmTurns = newSeq[int](config.numAgents)
  state.fallbackTurns = newSeq[int](config.numAgents)
  state.fallbackCauses = newSeq[array[FallbackCause, int]](config.numAgents)
  state.started = false
  state.finished = false

proc serveForTests*(config: GameConfig, port: int, host = "127.0.0.1") =
  ## Blocking. Call `stopTestServer()` from another thread to end it.
  prepareState(config)
  let router = buildRouter(replayMode = false)
  gameServer = newServer(router, websocketHandler, workerThreads = 2, maxMessageLen = 16 * 1024 * 1024)
  gameServer.serve(Port(port), host)

proc stopTestServer*() =
  if gameServer != nil:
    gameServer.close()

proc runGameServer*(config: GameConfig, runtimeConfig: RuntimeConfig) =
  assertFileUri("COGAME_EVENTS_URI")
  assertFileUri("COGAME_METRICS_URI")
  if config.tokens.len < config.numAgents:
    raise newException(LanternError, "tokens and players must align")
  prepareState(config)

  ## Pre-listen bake: the wall mask and the occlusion grid are built by
  ## newSim above, before the socket opens, so a spectator's first frame is
  ## instant rather than waiting on a 800 KB mask.
  var aliases, teams: seq[string]
  var hidIn: seq[int]
  for slot in 0 ..< config.numAgents:
    aliases.add(aliasOfSlot(slot))
    teams.add($teamOfSlot(slot))
    hidIn.add(hidHalfOfSlot(slot))
  state.sim.emit(matchStartEvent(0, config.seed, state.sim.map.name, aliases,
                                 teams, hidIn))
  var hiders, seekers: seq[string]
  for slot in 0 ..< config.numAgents:
    if roleOfSlot(slot, 1) == roHider: hiders.add(aliasOfSlot(slot))
    else: seekers.add(aliasOfSlot(slot))
  state.sim.emit(halfStartEvent(0, 1, hiders, seekers))
  state.sim.emit(actStartEvent(0, 1, actBuild))

  let router = buildRouter(replayMode = false)
  gameServer = newServer(router, websocketHandler, workerThreads = 4, maxMessageLen = 16 * 1024 * 1024)
  let seconds = parseFloat(getEnv("COWORLD_TIMEOUT_SECONDS", $(config.episodeTimeoutMs.float / 1000.0)))
  if classify(seconds) in {fcNan, fcInf, fcNegInf} or seconds <= 0:
    raise newException(LanternError, "episode timeout must be finite and positive")
  state.episodeDeadline = getMonoTime() + initDuration(milliseconds = int64(seconds * 1000))
  installNativeStopHandlers()
  var ownerCreated = false
  echo "lantern: serving on ", runtimeConfig.host, ":", runtimeConfig.port
  try:
    gameServer.serve(Port(runtimeConfig.port), runtimeConfig.host,
      onReady = proc(server: Server) {.gcsafe.} =
        {.gcsafe.}:
          createThread(gameThread, runEpisode, runtimeConfig)
          ownerCreated = true)
  finally:
    requestNativeStop()
    if ownerCreated:
      joinThread(gameThread)
    elif getEnv(CogameSaveTrajectoryUriEnv).len > 0:
      let trajectory = newDecisionTrajectory(getEnv("COWORLD_EPISODE_ID"),
        "lantern-" & $config.seed, "lantern", getEnv("COWORLD_GAME_VERSION"),
        getEnv("COWORLD_SOURCE_REVISION"))
      trajectory.finish(esFailed, %*{"termination": "server-did-not-start",
        "rules_version": GameVersion}, newJNull())
      let httpMethod = case getEnv("COGAME_SAVE_TRAJECTORY_METHOD", "PUT")
        of "PUT": ahPut
        of "POST": ahPost
        else: raise newException(LanternError, "trajectory method must be PUT or POST")
      trajectory.writeTrajectoryArtifact(getEnv(CogameSaveTrajectoryUriEnv),
        min(state.episodeDeadline, getMonoTime() + initDuration(seconds = 5)), httpMethod)
