## Game-owned decision timing, order validation, fallback, and replay notes.
## Player policies receive private views and return ordinary orders.

import std/[json, monotimes, times]
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

  DecisionExchange* = proc(requests: seq[JsonNode], timeoutMs: int):
    seq[string] {.gcsafe.}

proc decideAll*(sim: Sim, half: int, openSeats: seq[int],
                scripted: seq[ScriptKind], forceScripted: bool,
                exchange: DecisionExchange): seq[Decision] =
  ## All model seats see one pre-action state. Invalid or missing replies get
  ## one retry, then the game-owned warden order.
  result = newSeq[Decision](openSeats.len)
  var pending: seq[int]
  for index, seat in openSeats:
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
      if replies[position].len == 0:
        result[index].notes.add(FallbackNote(
          attempt: attempt, cause: fcTimeout,
          detail: "player action timed out"))
        stillPending.add(index)
        continue
      try:
        let reply = parseJson(replies[position])
        if reply["type"].getStr() != "action" or
            reply["protocol"].getStr() != "lantern.player.v2" or
            reply["id"].getInt() != requests[position]["id"].getInt():
          raise newException(LanternError, "player action envelope mismatch")
        if reply{"source"}.getStr() == "fallback":
          let cause =
            case reply{"cause"}.getStr()
            of "no_credentials": fcNoCredentials
            of "timeout": fcTimeout
            else: fcTransportError
          result[index].order = scriptedOrder(sim, seat, half, skWarden)
          result[index].source = osFallback
          result[index].notes.add(FallbackNote(
            attempt: attempt, cause: cause,
            detail: "player policy reported fallback"))
          continue
        if reply{"source"}.getStr() != "llm":
          raise newException(LanternError, "player action source must be llm")
        let cog = sim.cogs[seat]
        result[index].order = parseOrder(reply["order"],
          roleOfSlot(seat, half), Point(x: cog.px, y: cog.py), sim.crates)
        result[index].source = osLlm
        result[index].latencyMs = latency
      except CatchableError as error:
        result[index].notes.add(FallbackNote(
          attempt: attempt, cause: fcParseError, detail: error.msg))
        stillPending.add(index)
    pending = stillPending

  for index in pending:
    let seat = openSeats[index]
    echo "lantern: seat ", seat, " falling back to the scripted order"
    result[index].order = scriptedOrder(sim, seat, half, skWarden)
    result[index].source = osFallback
