## Native sidecar player: one owned request per canonical private operation.

import std/[atomics, json, locks, monotimes, options, os, strutils, times]
import bitworld/[decision_trajectory, native_stop, native_websocket]
import lantern/llm

const
  DefaultPrompt = """
Play both roles well, because you will play both.
As a hider: spend the build act pushing one crate into the mouth of the
alcove nearest your spawn and bolting it there with intent "lock", then hide
at that alcove and set crawl true the moment the hunt starts - a still cog
behind an opaque crate is invisible, and footsteps are what give a good
hiding place away. Only "flee" when a beam is reported close, and break
contact around a corner rather than down a straight lane.
As a seeker: claim a third of the map on the first hunt order and sweep it
with intent "sweep" and aim "sweep"; read the heartbeat every turn, push
deeper on cold or cool, slow down on warm, and stop advancing and sweep in
place on hot or burning. The instant anything is lit, switch to "chase" with
aim "track" and stay on it - half a second in the beam is a find.
"""
  ConnectAttempts = 12
  ConnectDelayMs = 500


type PlayerCall = object
  socket: NativeWebSocket
  decisionId, view, prompt, policy: string
  deadline: MonoTime
  retry: bool
  slot: int

var
  worker: Thread[PlayerCall]
  workerCreated = false
  workerFinished: Atomic[bool]
  evidenceLock: Lock
  workerEvidence: string

initLock(evidenceLock)

proc joinWorker() =
  if workerCreated:
    joinThread(worker)
    workerCreated = false

proc runDecision(call: PlayerCall) {.gcsafe.} =
  defer: workerFinished.store(true)
  let client = newLlmClient()
  let view = parseJson(call.view)
  var reply = %*{"type": "action", "protocol": "lantern.player.v3",
    "decision_id": call.decisionId, "source": "fallback",
    "training_attempt": newJNull()}
  if client.disabled:
    reply["cause"] = %"no_endpoint"
  else:
    proc started(attempt: DecisionAttempt) {.gcsafe.} =
      let evidence = attempt.attemptEvidenceJson()
      {.gcsafe.}:
        withLock evidenceLock: workerEvidence = $evidence
      let sent = call.socket.sendNativeText($(%*{"type": "attempt_started", "decision_id": call.decisionId,
        "training_attempt": evidence}), call.deadline)
      if sent.kind != wsReady: raise newException(ValueError, "native attempt start was not delivered")
    try:
      reply["response"] = %client.call(view, call.prompt,
        call.retry, call.deadline, call.slot, call.decisionId & "-model", call.policy, started)
      reply["source"] = %"llm"
    except CatchableError as error:
      client.lastAttempt.rejectionReason = some(error.msg)
      reply["cause"] = %"transport"
    reply["training_attempt"] = client.lastAttempt.attemptEvidenceJson()
    {.gcsafe.}:
      withLock evidenceLock: workerEvidence = $reply["training_attempt"]
  if not interruptionRequested():
    discard call.socket.sendNativeText($reply, call.deadline)

proc stopAndAcknowledge(socket: NativeWebSocket, decisionId, stopId: JsonNode,
    cleanupDeadline: MonoTime): bool =
  requestNativeStop()
  let hadWorker = workerCreated
  joinWorker()
  var attempts = newJArray()
  withLock evidenceLock:
    if workerEvidence.len > 0: attempts.add(parseJson(workerEvidence))
  let sent = socket.sendCleanupText($(%*{"type": "stopped", "decision_id": decisionId, "stop_id": stopId,
    "worker_status": (if hadWorker: "joined" else: "no_active_call"), "attempts": attempts}), cleanupDeadline)
  if sent.kind != wsReady: return false
  while getMonoTime() < cleanupDeadline:
    let received = socket.receiveCleanupText(cleanupDeadline)
    if received.kind != wsMessage: return false
    let frame = parseJson(received.data)
    if frame["type"].getStr() == "evidence_received" and
        frame["decision_id"] == decisionId and frame["stop_id"] == stopId: return true
  false

when isMainModule:
  installNativeStopHandlers()
  let url = getEnv("COWORLD_PLAYER_WS_URL").strip()
  if url.len == 0: quit("lantern player: COWORLD_PLAYER_WS_URL is not set", 1)
  var prompt = getEnv("PLAYER_PROMPT")
  let scripted = getEnv("PLAYER_SCRIPTED").strip()
  if prompt.strip().len == 0 and scripted.len == 0: prompt = DefaultPrompt
  let kind = if scripted.len > 0: "scripted" else: "prompt"
  let label = getEnv("PLAYER_POLICY_LABEL").strip()
  ## A bounded connect retry: the game container and the player containers
  ## start together, so the first dial often lands before the socket is up.
  ## After the last attempt the player exits 0 — a seat that cannot connect
  ## is played by the server's warden baseline, and a non-zero exit here
  ## would fail the episode for a condition the game already handles.
  var socket: NativeWebSocket
  let connectDeadline = getMonoTime() + initDuration(milliseconds = ConnectAttempts * ConnectDelayMs)
  for attempt in 1 .. ConnectAttempts:
    let connected = connectNativeWebSocket(url,
      min(connectDeadline, getMonoTime() + initDuration(milliseconds = ConnectDelayMs)), 16 * 1024 * 1024)
    case connected.kind
    of wsReady:
      socket = connected.socket
      break
    of wsInterrupted: quit(0)
    else:
      if attempt == ConnectAttempts or getMonoTime() >= connectDeadline:
        echo "lantern player: could not reach the game; the server will play this seat"
        quit(0)
      sleep(int(min(ConnectDelayMs.int64, max(0'i64, (connectDeadline - getMonoTime()).inMilliseconds))))
  let registered = socket.sendNativeText($(%*{"type": "register", "kind": kind,
    "scripted": (if scripted.len == 0: newJNull() else: %scripted), "policy": label}), connectDeadline)
  if registered.kind != wsReady:
    closeNativeWebSocket(socket)
    quit(0)
  var decisionId = newJNull()
  var acknowledged = false
  var cleanupBudgetMs = 0
  var finalDeadline: MonoTime
  var cleanupStarted = false
  try:
    while true:
      if workerCreated and workerFinished.load(): joinWorker()
      if interruptionRequested() and not acknowledged:
        finalDeadline = getMonoTime() + initDuration(milliseconds = cleanupBudgetMs)
        cleanupStarted = true
        acknowledged = stopAndAcknowledge(socket, decisionId, newJNull(), finalDeadline)
        break
      if acknowledged and getMonoTime() >= finalDeadline: break
      let received = socket.receiveNativeText(getMonoTime() + initDuration(milliseconds = 50))
      case received.kind
      of wsDeadline, wsInterrupted: continue
      of wsClosed: break
      of wsMessage: discard
      else: raise newException(ValueError, "native player socket failed")
      let payload = parseJson(received.data)
      if payload.hasKey("done") and payload["done"].getBool(): break
      case payload["type"].getStr()
      of "welcome": echo "lantern player: seated at slot ", payload["slot"].getInt()
      of "turn", "state", "evidence_received": discard
      of "decision":
        if acknowledged or kind != "prompt":
          raise newException(ValueError, "decision does not belong to an active prompt player")
        let issuedId = payload["decision_id"]
        if issuedId.kind != JString or issuedId.getStr().len == 0:
          raise newException(ValueError, "decision identity must be a nonempty string")
        let receivedAt = getMonoTime()
        let budget = payload["transport"]["budget_ms"].getInt()
        cleanupBudgetMs = payload["transport"]["cleanup_budget_ms"].getInt()
        if budget <= 0 or cleanupBudgetMs < 0:
          raise newException(ValueError, "decision transport budget is invalid")
        joinWorker()
        if interruptionRequested(): break
        decisionId = issuedId
        withLock evidenceLock: workerEvidence.setLen(0)
        workerFinished.store(false)
        createThread(worker, runDecision, PlayerCall(socket: socket,
          decisionId: decisionId.getStr(), view: $payload["observation"], prompt: prompt,
          policy: (if label.len > 0: label else: "prompt"), retry: payload["attempt"].getInt() > 1,
          slot: payload["slot"].getInt(), deadline: receivedAt + initDuration(milliseconds = budget)))
        workerCreated = true
      of "stop":
        finalDeadline = getMonoTime() + initDuration(milliseconds = payload["cleanup_budget_ms"].getInt())
        cleanupStarted = true
        acknowledged = stopAndAcknowledge(socket, payload["decision_id"], payload["stop_id"], finalDeadline)
        break  # Evidence delivery is confirmed; this player no longer owns work.
      else: raise newException(ValueError, "unknown player frame")
  finally:
    let interrupted = interruptionRequested()
    requestNativeStop()
    joinWorker()
    if interrupted and not cleanupStarted:
      finalDeadline = getMonoTime() + initDuration(milliseconds = cleanupBudgetMs)
      discard stopAndAcknowledge(socket, decisionId, newJNull(), finalDeadline)
    closeNativeWebSocket(socket)
