## Callback ordering regression: close cannot discard queued private HTTP facts.
include ../src/lantern/server
import std/[base64, unittest]

suite "private external owner lifecycle":
  test "close before queued stop retains facts without acknowledgement credit":
    state = GameState()
    state.roster.seats = newSeq[Seat](Seats)
    let socket = default(WebSocket)
    let id = "lantern-fixture"
    state.socketSlots[socket] = 0
    state.playerSockets[0] = socket
    state.registeredSlots.incl(0)
    state.decisionSeats[id] = 0
    state.decisionIssuedAt[id] = getMonoTime() - initDuration(seconds = 1)
    # The engine can issue a later decision while this earlier HTTP reader joins.
    state.latestDecisions[0] = "lantern-next"
    state.decisionSeats["lantern-next"] = 0
    state.decisionIssuedAt["lantern-next"] = getMonoTime()
    var started = newDecisionAttempt(id & "-model", "fixture", aoModel)
    started.prompt = %*["private fixture"]
    started.request = %*{"fixture": true}
    started.decoder = %*{"temperature": 0}
    state.pendingAttempts[id] = started.attemptEvidenceJson()
    var received = started
    received.responseBodyB64 = some(encode("\xffprivate partial bytes"))
    received.responseHeadersB64 = some(encode("HTTP/1.1 200 OK\r\n\r\n"))
    received.responseComplete = some(false)
    received.responseReaderJoined = some(true)
    received.httpStatus = some(200)
    websocketHandler(socket, CloseEvent, Message())
    check not state.playerSockets.hasKey(0)
    check state.socketSlots[socket] == 0
    let stopped = %*{"type": "stopped", "decision_id": id,
      "stop_id": newJNull(), "worker_status": "joined", "attempts": [received.attemptEvidenceJson()]}
    websocketHandler(socket, MessageEvent, Message(kind: TextMessage, data: $stopped))
    check state.completedAttempts[id] == received.attemptEvidenceJson()
    check 0 notin state.stoppedSlots
    check 0 in state.registeredSlots
    # An already-sealed episode rejects further frames, even with retained attribution.
    state.finished = true
    received.responseBodyB64 = some(encode("different bytes"))
    let late = %*{"type": "stopped", "decision_id": id,
      "stop_id": newJNull(), "worker_status": "joined", "attempts": [received.attemptEvidenceJson()]}
    websocketHandler(socket, MessageEvent, Message(kind: TextMessage, data: $late))
    check state.completedAttempts[id] == stopped["attempts"][0]

  test "acknowledgement must echo the actual issued stop identity":
    state = GameState()
    state.roster.seats = newSeq[Seat](Seats)
    let socket = default(WebSocket)
    state.socketSlots[socket] = 0
    state.registeredSlots.incl(0)
    state.stopping = true
    state.stopId = "issued-stop-identity"
    state.stopIssuedAt = getMonoTime() - initDuration(seconds = 1)
    state.acknowledgementDeadline = getMonoTime() + initDuration(seconds = 1)
    var stopped = %*{"type": "stopped", "decision_id": newJNull(),
      "stop_id": "guessed-stop-identity", "worker_status": "no_active_call", "attempts": []}
    websocketHandler(socket, MessageEvent, Message(kind: TextMessage, data: $stopped))
    check 0 notin state.stoppedSlots
    stopped["stop_id"] = %state.stopId
    websocketHandler(socket, MessageEvent, Message(kind: TextMessage, data: $stopped))
    check 0 in state.stoppedSlots

  test "nonce does not acknowledge an explicitly unjoined response reader":
    state = GameState()
    state.roster.seats = newSeq[Seat](Seats)
    let socket = default(WebSocket)
    let id = "lantern-unjoined"
    state.socketSlots[socket] = 0
    state.registeredSlots.incl(0)
    state.decisionSeats[id] = 0
    state.decisionIssuedAt[id] = getMonoTime() - initDuration(seconds = 1)
    state.latestDecisions[0] = id
    state.stopping = true
    state.stopId = "issued-stop-identity"
    state.stopIssuedAt = getMonoTime() - initDuration(seconds = 1)
    state.acknowledgementDeadline = getMonoTime() + initDuration(seconds = 1)
    var attempt = newDecisionAttempt(id & "-model", "fixture", aoModel)
    state.pendingAttempts[id] = attempt.attemptEvidenceJson()
    attempt.responseReaderJoined = some(false)
    let stopped = %*{"type": "stopped", "decision_id": id,
      "stop_id": state.stopId, "worker_status": "joined", "attempts": [attempt.attemptEvidenceJson()]}
    websocketHandler(socket, MessageEvent, Message(kind: TextMessage, data: $stopped))
    check state.completedAttempts[id] == attempt.attemptEvidenceJson()
    check 0 notin state.stoppedSlots

  test "raw header callbacks cannot be rewritten during native progress":
    var attempt = newDecisionAttempt("issued-model", "fixture", aoModel)
    attempt.responseHeadersB64 = some(encode("HTTP/1.1 200 OK\r\nX-Private: original\r\n"))
    let started = attempt.attemptEvidenceJson()
    attempt.responseHeadersB64 = some(encode("HTTP/1.1 200 OK\r\nX-Private: changed\r\n"))
    expect ValueError: validateAttemptProgress(started, attempt.attemptEvidenceJson())
    attempt.responseHeadersB64 = some(encode("HTTP/1.1 200 OK\r\nX-Private: original\r\n\r\n"))
    validateAttemptProgress(started, attempt.attemptEvidenceJson())
