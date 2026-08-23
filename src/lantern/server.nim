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
## Player protocol (lantern.player.v1), all JSON text frames:
##   player -> game: {"type":"register","prompt":...,"scripted":...,"policy":...}
##   game -> player: {"type":"welcome",...}
##                   {"type":"turn","turn":N,"tick":T,"half":H,"act":...,
##                    "role":...,"view":{...},"order_source":...}
##                   {"done":true,"result":{...}}
##
## Decisions are made HERE, not in the player container: the Bedrock sidecar
## credentials and the `anthropic_api_key` coworld secret are injected into
## the GAME pod, phase 60 greps the GAME log for `falling back`, and "one
## parallel batch per turn" is a game-server property. The player container is
## therefore thin: connect, register, receive until done.

import std/[json, locks, os, sets, strutils, tables, times]
import bitworld/runtime
import curly
import mummy, mummy/routers
import types, arena, sim, rules, control, orders, llm,
       render, replay, roster, broadcast, events, labels

const
  DoneBroadcastMs = 3_000
    ## Bounded wait for the final frame to land before the artifacts are
    ## written: the hosted worker tears player pods down as soon as
    ## results.json exists.
  PlayBudgetFraction = 60
    ## Percent of the platform's episode timeout spent playing. An episode
    ## that outruns the timeout is discarded whole, so lantern settles early
    ## rather than overrunning.

type
  GameState = object
    config: GameConfig
    sim: Sim
    roster: Roster
    playerSockets: Table[int, WebSocket]
    socketSlots: Table[WebSocket, int]
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

proc writeArtifact(uri, data, contentType, methodEnv: string) =
  if uri.len == 0:
    return
  let httpMethod = getEnv(methodEnv, "PUT").toUpperAscii()
  if uri.isHttpCogameUri() and httpMethod == "POST":
    let curl = newCurly()
    var headers: HttpHeaders
    headers["content-type"] = contentType
    let response = curl.post(uri, headers, data, 60)
    if response.code < 200 or response.code >= 300:
      raise newException(IOError, "artifact POST failed: " & $response.code)
  else:
    writeCogameUri(uri, data, contentType, methodEnv)

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

proc nowMs(): int = int(epochTime() * 1000.0)

proc runEpisode(runtimeConfig: RuntimeConfig) {.gcsafe.} =
  {.gcsafe.}:
    let config = state.config
    let startMs = nowMs()
    let connectDeadline = startMs + config.playerConnectTimeoutMs
    while nowMs() < connectDeadline:
      var all = false
      withLock stateLock:
        all = state.playerSockets.len >= config.numAgents
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
      try:
        writeArtifact(getEnv("COGAME_PLAYER_FAILURE_URI"),
          $ %*{"slot": missing[0], "reason": "player never connected",
               "slots": missing}, "application/json",
          "COGAME_PLAYER_FAILURE_METHOD")
      except CatchableError as error:
        echo "lantern: could not report the player failure: ", error.msg

    let client = newLlmClient(config)
    var reason = erComplete
    var rule = edFullTime
    var guardEngaged = false
    let total = totalTicks(config)
    let wallDeadline = startMs + config.wallClockBudgetMs

    try:
      while true:
        var done = false
        withLock stateLock:
          done = state.sim.tick >= total
        if done:
          break
        if nowMs() > wallDeadline:
          echo "lantern: wall-clock budget reached at tick ", state.sim.tick
          reason = erDeadline
          rule = edWallClock
          break

        var simRef: Sim
        var half = 1
        var act = actBuild
        var seats: seq[int]
        var prompts: seq[string]
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
            prompts = state.roster.prompts()
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
          ## The budget guard settles early rather than overrunning: once two
          ## more full turn budgets would not fit, every remaining turn is
          ## played on the scripted layer (well under a millisecond a turn),
          ## so the episode ends complete/full_time instead of deadline.
          let remainingMs = wallDeadline - nowMs()
          if not guardEngaged and remainingMs < 2 * config.turnBudgetMs:
            guardEngaged = true
            withLock stateLock:
              state.sim.emit(budgetGuardEvent(state.sim.tick,
                phaseAt(config, state.sim.tick).turn, remainingMs))
            echo "lantern: budget guard engaged with ", remainingMs,
              " ms left; the rest of the match plays scripted"

          let decisions =
            if seats.len == 0: @[]
            else: client.decideAll(simRef, half, seats, prompts, scripted,
                                   guardEngaged)
          var sources: Table[int, string]
          withLock stateLock:
            let phase = phaseAt(config, state.sim.tick)
            for index, slot in seats:
              let decision = decisions[index]
              state.sim.cogs[slot].order = decision.order
              state.sim.cogs[slot].orderSource = decision.source
              state.sim.cogs[slot].hasOrder = true
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

    var results: JsonNode
    var replayData: string
    withLock stateLock:
      if state.finished:
        return
      state.finished = true
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
      let winner = (if results["winner"].kind == JNull: -1
                    else: results["winner"].getInt())
      state.sim.emit(endEvent(state.sim.tick, reason, rule, scoresMilli,
                              fracMicro, winner))
      state.lastResults = results
      replayData = $buildReplay(state.sim, kinds, results)
      let final = %*{"done": true, "result": results}
      for slot, socket in state.playerSockets:
        socket.send($final)
      state.broadcastGlobalLocked()

    ## Bounded wait for the final frame to land, then the artifacts, in the
    ## order the platform expects: replay first, results last, because the
    ## worker tears the pod down the moment results.json exists.
    let doneDeadline = nowMs() + DoneBroadcastMs
    while nowMs() < doneDeadline:
      var open = 0
      withLock stateLock:
        open = state.playerSockets.len
      if open == 0:
        break
      sleep(100)

    echo "lantern: writing replay and results (", reason, "/", rule, ")"
    try:
      writeArtifact(runtimeConfig.replayUri, replayData, "application/json",
                    "COGAME_SAVE_REPLAY_METHOD")
    except CatchableError as error:
      echo "lantern: replay write failed: ", error.msg
    try:
      writeArtifact(runtimeConfig.resultsUri, $results, "application/json",
                    "COGAME_RESULTS_METHOD")
    except CatchableError as error:
      echo "lantern: results write failed: ", error.msg
    sleep(300)
    echo "lantern: episode complete, shutting down"
    quit(0)

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
    var authorised = false
    var duplicate = false
    withLock stateLock:
      authorised = state.roster.authorised(slot, token)
      duplicate = state.playerSockets.hasKey(slot)
    if not authorised:
      request.respond(403)
      return
    if duplicate:
      request.respond(409)
      return
    let websocket = request.upgradeToWebSocket()
    withLock stateLock:
      state.playerSockets[slot] = websocket
      state.socketSlots[websocket] = slot
      state.roster.seats[slot].connected = true
      state.roster.seats[slot].everConnected = true
      echo "lantern: player slot ", slot, " connected (",
        state.playerSockets.len, "/", state.config.numAgents, ")"
      websocket.send($ %*{
        "type": "welcome", "protocol": "lantern.player.v1", "slot": slot,
        "alias": aliasOfSlot(slot), "team": $teamOfSlot(slot),
        "hides_in_half": hidHalfOfSlot(slot),
        "turns": totalTurns(state.config)})

proc globalUpgradeHandler(request: Request) {.gcsafe.} =
  {.gcsafe.}:
    let websocket = request.upgradeToWebSocket()
    withLock stateLock:
      state.globalSockets.incl(websocket)
      websocket.send($snapshotJson(state.sim, state.playerNames(),
                                   state.started, state.connectedFlags()))

proc websocketHandler(websocket: WebSocket, event: WebSocketEvent,
                      message: Message) {.gcsafe.} =
  {.gcsafe.}:
    case event
    of OpenEvent:
      discard
    of MessageEvent:
      ## mummy hands Ping frames to the application; the platform's certifier
      ## pings /global to check the game is alive, so an unanswered ping
      ## fails certification.
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
        if payload{"type"}.getStr() == "register":
          withLock stateLock:
            state.roster.applyRegister(slot, payload)
            echo "lantern: slot ", slot, " registered (",
              policyKind(state.roster.seats[slot]), ", ",
              state.roster.seats[slot].prompt.len, " prompt chars)"
      except CatchableError as error:
        echo "lantern: ignoring bad player frame: ", error.msg
    of ErrorEvent:
      discard
    of CloseEvent:
      withLock stateLock:
        if websocket in state.socketSlots:
          let slot = state.socketSlots[websocket]
          state.socketSlots.del(websocket)
          if state.playerSockets.getOrDefault(slot) == websocket:
            state.playerSockets.del(slot)
          if slot >= 0 and slot < state.roster.seats.len:
            state.roster.seats[slot].connected = false
        state.globalSockets.excl(websocket)

proc buildRouter(replayMode: bool): Router =
  result.get("/healthz", healthzHandler)
  result.get("/client/replay", replayPageHandler)
  result.get("/client/@name", clientAssetHandler)
  result.get("/replay-data", replayDataHandler)
  result.get("/global", globalUpgradeHandler)
  if not replayMode:
    result.get("/player", playerUpgradeHandler)

proc runReplayServer*(runtimeConfig: RuntimeConfig) =
  ## Replay mode serves the recorded bytes to the local broadcast viewer.
  ## The HOSTED viewer never comes here — it is the static wasm bundle,
  ## fed straight from S3.
  replayPayloadGlobal = runtimeConfig.replay
  let router = buildRouter(replayMode = true)
  gameServer = newServer(router, websocketHandler, workerThreads = 4)
  echo "lantern: replay mode on ", runtimeConfig.host, ":", runtimeConfig.port
  gameServer.serve(Port(runtimeConfig.port), runtimeConfig.host)

proc prepareState*(config: GameConfig) =
  ## Everything runGameServer does before it opens a socket. Exposed so
  ## tests/test_server.nim can exercise the websocket contract without a game
  ## thread that would `quit(0)` out from under the test process.
  state.config = config
  state.sim = newSim(config, loadMapSpec(config.mapPath))
  state.roster = initRoster(config)
  state.llmTurns = newSeq[int](config.numAgents)
  state.fallbackTurns = newSeq[int](config.numAgents)
  state.fallbackCauses = newSeq[array[FallbackCause, int]](config.numAgents)
  state.started = false
  state.finished = false

proc serveForTests*(config: GameConfig, port: int, host = "127.0.0.1") =
  ## Blocking. Call `stopTestServer()` from another thread to end it.
  prepareState(config)
  let router = buildRouter(replayMode = false)
  gameServer = newServer(router, websocketHandler, workerThreads = 2)
  gameServer.serve(Port(port), host)

proc stopTestServer*() =
  if gameServer != nil:
    gameServer.close()

proc runGameServer*(config: GameConfig, runtimeConfig: RuntimeConfig) =
  assertFileUri("COGAME_EVENTS_URI")
  assertFileUri("COGAME_METRICS_URI")
  if config.tokens.len < config.numAgents:
    raise newException(LanternError, "tokens and players must align")
  state.config = config
  state.sim = newSim(config, loadMapSpec(config.mapPath))
  state.roster = initRoster(config)
  state.llmTurns = newSeq[int](config.numAgents)
  state.fallbackTurns = newSeq[int](config.numAgents)
  state.fallbackCauses = newSeq[array[FallbackCause, int]](config.numAgents)

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
  gameServer = newServer(router, websocketHandler, workerThreads = 4)
  createThread(gameThread, runEpisode, runtimeConfig)
  echo "lantern: serving on ", runtimeConfig.host, ":", runtimeConfig.port
  gameServer.serve(Port(runtimeConfig.port), runtimeConfig.host)
