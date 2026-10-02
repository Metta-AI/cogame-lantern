## Game-owned decision timing, order validation, fallback, and replay notes.
## Player policies receive private views and return ordinary orders.

import std/[json, monotimes, options, times]
import bitworld/decision_trajectory
import types, sim, orders, baselines, render, labels

type
  FallbackNote* = object
    attempt*: int
    cause*: FallbackCause
    detail*: string

  Decision* = object
    order*: Order
    source*: OrderSource
    latencyMs*: int
    notes*: seq[FallbackNote]
    observation*: JsonNode
    attempts*: seq[DecisionAttempt]
    selectedAttemptId*: Option[string]

  DecisionExchange* = proc(requests: seq[JsonNode], timeoutMs: int):
    seq[string] {.gcsafe.}

type
  ProposalKind* = enum pkAccepted, pkFallback, pkRejected
  PlayerProposal* = object
    kind*: ProposalKind
    order*: Order
    evidence*: DecisionAttempt
    cause*: FallbackCause

proc playerProposal*(raw: string, requestId, seat, half: int,
    sim: Sim): PlayerProposal =
  ## One parser boundary for hosted players and the language bridge.
  result.evidence = newDecisionAttempt($seat & "-" & $requestId,
    "external", aoUnknown)
  try:
    let reply = parseJson(raw)
    if reply.hasKey("training_attempt"):
      result.evidence = readAttemptEvidence(reply["training_attempt"])
    if reply["type"].getStr() == "attempt_timeout":
      raise newException(LanternError, "player action timed out after model request")
    if reply["type"].getStr() != "action" or
        reply["protocol"].getStr() != "lantern.player.v2" or
        reply["id"].getInt() != requestId:
      raise newException(LanternError, "player action envelope mismatch")
    if reply{"source"}.getStr() == "fallback":
      result.kind = pkFallback
      result.cause = case reply{"cause"}.getStr()
        of "no_credentials": fcNoCredentials
        of "timeout": fcTimeout
        else: fcTransportError
      result.evidence.rejectionReason = some("player policy reported fallback")
      result.order = scriptedOrder(sim, seat, half, skWarden)
      return
    if reply{"source"}.getStr() != "llm":
      raise newException(LanternError, "player action source must be llm")
    let cog = sim.cogs[seat]
    let at = Point(x: cog.px, y: cog.py)
    result.order = if reply.hasKey("response"):
      parseOrderText(reply["response"].getStr(), roleOfSlot(seat, half), at, sim.crates)
      else: parseOrder(reply["order"], roleOfSlot(seat, half), at, sim.crates)
    result.kind = pkAccepted
    result.evidence.accepted = true
    result.evidence.parsedAction = orderJson(result.order)
  except CatchableError as error:
    result.kind = pkRejected
    result.cause = fcParseError
    result.evidence.rejectionReason = some(error.msg)

proc decideAll*(sim: Sim, half: int, openSeats: seq[int],
                scripted: seq[ScriptKind], forceScripted: bool,
                exchange: DecisionExchange): seq[Decision] =
  ## All model seats see one pre-action state. Invalid or missing replies get
  ## one retry, then the game-owned warden order.
  result = newSeq[Decision](openSeats.len)
  var pending: seq[int]
  for index, seat in openSeats:
    result[index].observation = seatView(sim, seat)
    let kind = scripted[seat]
    if kind != skNone or forceScripted:
      result[index].order = scriptedOrder(sim, seat, half, kind)
      result[index].source = osScripted
      if kind == skNone:
        result[index].source = osFallback
        result[index].notes.add(FallbackNote(
          attempt: 0, cause: fcBudgetGuard, detail: "budget guard engaged"))
    else:
      pending.add(index)

  for attempt in 1 .. 2:
    if pending.len == 0:
      break
    let timeoutMs =
      if attempt == 1: sim.config.attempt1Ms
      else: sim.config.attempt2Ms
    var requests: seq[JsonNode]
    for index in pending:
      let seat = openSeats[index]
      requests.add(%*{
        "type": "decision",
        "protocol": "lantern.player.v2",
        "id": sim.tick * 10 + attempt,
        "slot": seat,
        "role": $roleOfSlot(seat, half),
        "attempt": attempt,
        "timeout_ms": timeoutMs,
        "view": seatView(sim, seat)
      })
    let started = getMonoTime()
    let replies = exchange(requests, timeoutMs)
    let latency = max(0, (getMonoTime() - started).inMilliseconds.int)
    var stillPending: seq[int]
    for position, index in pending:
      let seat = openSeats[index]
      var evidence = newDecisionAttempt($seat & "-" & $requests[position]["id"].getInt(),
        "external", aoUnknown)
      if replies[position].len == 0:
        evidence.rejectionReason = some("player action timed out")
        result[index].attempts.add(evidence)
        result[index].notes.add(FallbackNote(
          attempt: attempt, cause: fcTimeout,
          detail: "player action timed out"))
        stillPending.add(index)
        continue
      let proposal = playerProposal(replies[position],
        requests[position]["id"].getInt(), seat, half, sim)
      result[index].attempts.add(proposal.evidence)
      case proposal.kind
      of pkAccepted:
        result[index].order = proposal.order
        result[index].source = osLlm
        result[index].latencyMs = latency
        result[index].selectedAttemptId = some(proposal.evidence.attemptId)
      of pkFallback:
        result[index].order = proposal.order
        result[index].source = osFallback
        result[index].notes.add(FallbackNote(attempt: attempt,
          cause: proposal.cause, detail: "player policy reported fallback"))
      of pkRejected:
        result[index].notes.add(FallbackNote(attempt: attempt,
          cause: proposal.cause, detail: "invalid private player reply"))
        stillPending.add(index)
    pending = stillPending

  for index in pending:
    let seat = openSeats[index]
    echo "lantern: seat ", seat, " falling back to the scripted order"
    result[index].order = scriptedOrder(sim, seat, half, skWarden)
    result[index].source = osFallback
