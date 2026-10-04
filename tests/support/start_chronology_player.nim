## Send a completed response as the first request-start frame.
import std/[json, monotimes, options, os, times]
import bitworld/[decision_trajectory, native_websocket]
import lantern/llm

let mode = getEnv("ASSERTED_CHRONOLOGY", "first")
doAssert mode in ["first", "joined"]
let deadline = getMonoTime() + initDuration(seconds = 30)
let connected = connectNativeWebSocket(getEnv("COWORLD_PLAYER_WS_URL"), deadline,
  16 * 1024 * 1024)
doAssert connected.kind == wsReady
let socket = connected.socket
doAssert socket.sendNativeText($ %*{"type": "register", "kind": "prompt",
  "policy": "chronology-fixture", "scripted": newJNull()}, deadline).kind == wsReady
while true:
  let received = socket.receiveNativeText(deadline)
  if received.kind == wsClosed: break
  doAssert received.kind == wsMessage
  let packet = parseJson(received.data)
  if packet.hasKey("done") and packet["done"].getBool(): break
  case packet["type"].getStr()
  of "decision":
    let id = packet["decision_id"].getStr()
    let user = userPrompt(packet["observation"], "", packet["attempt"].getInt() > 1)
    let response = "{\"intent\":\"wait\"}"
    var attempt = newDecisionAttempt(id & "-model", "chronology-fixture", aoModel)
    attempt.prompt = %*[{"role": "system", "content": SystemPrompt},
      {"role": "user", "content": user}]
    attempt.request = %*{"model": "fixture/asserted", "system": SystemPrompt,
      "messages": [{"role": "user", "content": user}], "temperature": 0,
      "max_tokens": 900}
    attempt.decoder = %*{"temperature": 0, "max_tokens": 900}
    attempt.model = some("fixture/asserted")
    if mode == "joined":
      doAssert socket.sendNativeText($ %*{"type": "attempt_started",
        "decision_id": id, "training_attempt": attempt.attemptEvidenceJson()}, deadline).kind == wsReady
    attempt.response = %response
    attempt.rawResponse = %($ %*{"model": "fixture/asserted",
      "content": [{"type": "text", "text": response}]})
    attempt.httpStatus = some(200)
    attempt.responseComplete = some(true)
    attempt.responseReaderJoined = some(true)
    doAssert socket.sendNativeText($ %*{"type": "attempt_started",
      "decision_id": id, "training_attempt": attempt.attemptEvidenceJson()}, deadline).kind == wsReady
    if mode == "joined":
      # A joined response with genuinely null latency still freezes all facts.
      attempt.inputTokens = some(99)
      doAssert socket.sendNativeText($ %*{"type": "attempt_started",
        "decision_id": id, "training_attempt": attempt.attemptEvidenceJson()}, deadline).kind == wsReady
    doAssert socket.sendNativeText($ %*{"type": "action", "decision_id": id,
      "source": "llm", "protocol": "lantern.player.v3", "response": response,
      "training_attempt": attempt.attemptEvidenceJson()}, deadline).kind == wsReady
  of "stop":
    doAssert socket.sendNativeText($ %*{"type": "stopped",
      "decision_id": packet["decision_id"], "stop_id": packet["stop_id"],
      "worker_status": "no_active_call", "attempts": []}, deadline).kind == wsReady
  of "evidence_received": break
  else: discard
closeNativeWebSocket(socket)
