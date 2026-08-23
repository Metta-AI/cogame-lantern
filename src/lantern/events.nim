## The replay event vocabulary.
##
## Events are built as JSON here and nowhere else, which is what keeps the
## sim path free of floating point: a tick count crosses this boundary as an
## integer and comes out the other side as the `hidden_s` the spectator feed
## reads. Every recorded string is truncated on RUNE boundaries (see
## `orders.clip`) before it gets here.

import std/[json, math, unicode]
import types

proc seconds*(ticks: int): float =
  ## Ticks as seconds, one decimal. Spectator-facing only.
  round(ticks.float * 10.0 / TargetFps.float) / 10.0

proc clipRunes*(text: string, limit: int): string =
  ## Truncate on a RUNE boundary, never a byte boundary. A byte-truncated
  ## multi-byte character renders in a browser and then fails a strict JSON
  ## parser, which is exactly how a replay comes back unreadable.
  result = text.strip()
  if result.runeLen <= limit:
    return
  result = result.runeSubStr(0, limit)

proc point*(p: Point): JsonNode = %[p.x, p.y]

proc matchStartEvent*(t, seed: int, mapName: string,
                      aliases, teams: seq[string],
                      hidInHalf: seq[int]): JsonNode =
  %*{"type": "match_start", "t": t, "seed": seed, "map": mapName,
     "aliases": aliases, "teams": teams, "hid_in_half": hidInHalf}

proc halfStartEvent*(t, half: int, hiders, seekers: seq[string]): JsonNode =
  %*{"type": "half_start", "t": t, "half": half,
     "hiders": hiders, "seekers": seekers}

proc actStartEvent*(t, half: int, act: Act): JsonNode =
  %*{"type": "act_start", "t": t, "half": half, "act": $act}

proc actEndEvent*(t, half: int, act: Act, reason: string): JsonNode =
  %*{"type": "act_end", "t": t, "half": half, "act": $act, "reason": reason}

proc turnStartEvent*(t, turn, half: int, act: Act, hiddenTicks: seq[int],
                     hidersLeft: int): JsonNode =
  var hidden = newJArray()
  for ticks in hiddenTicks:
    hidden.add(%seconds(ticks))
  %*{"type": "turn_start", "t": t, "turn": turn, "half": half, "act": $act,
     "hidden_s": hidden, "hiders_left": hidersLeft}

proc orderEvent*(t, turn, seat: int, alias: string, role: Role,
                 source: OrderSource, latencyMs: int,
                 order: Order, crateId: string): JsonNode =
  %*{"type": "order", "t": t, "turn": turn, "seat": seat, "alias": alias,
     "role": $role, "source": $source, "latency_ms": latencyMs,
     "intent": $order.intent, "target": point(order.target),
     "crate": (if crateId.len == 0: newJNull() else: %crateId),
     "aim": $order.aim, "crawl": order.crawl,
     "note": order.note, "say": order.say}

proc fallbackEvent*(t, turn, seat, attempt: int, cause: FallbackCause,
                    detail: string): JsonNode =
  %*{"type": "fallback", "t": t, "turn": turn, "seat": seat,
     "attempt": attempt, "cause": $cause,
     "detail": clipRunes(detail, MaxDetailRunes)}

proc budgetGuardEvent*(t, turn, remainingMs: int): JsonNode =
  %*{"type": "budget_guard", "t": t, "turn": turn,
     "remaining_s": round(remainingMs.float / 100.0) / 10.0}

proc cratePushEvent*(t, seat: int, alias, crate: string,
                     fromPos, toPos: Point): JsonNode =
  %*{"type": "crate_push", "t": t, "seat": seat, "alias": alias,
     "crate": crate, "from": point(fromPos), "to": point(toPos)}

proc crateLockEvent*(t, seat: int, alias, crate: string, pos: Point): JsonNode =
  %*{"type": "crate_lock", "t": t, "seat": seat, "alias": alias,
     "crate": crate, "pos": point(pos)}

proc cratePryEvent*(t, seat: int, alias, crate: string, pct: int): JsonNode =
  %*{"type": "crate_pry", "t": t, "seat": seat, "alias": alias,
     "crate": crate, "pct": pct}

proc crateBreakEvent*(t, seat: int, alias, crate: string,
                      pos: Point): JsonNode =
  %*{"type": "crate_break", "t": t, "seat": seat, "alias": alias,
     "crate": crate, "pos": point(pos)}

proc soundEvent*(t: int, kind: SoundKind, at: Point, radius: int): JsonNode =
  %*{"type": "sound", "t": t, "kind": $kind, "pos": point(at),
     "radius": radius}

proc spotEvent*(t: int, seeker, hider: string, dist: int): JsonNode =
  %*{"type": "spot", "t": t, "seeker": seeker, "hider": hider, "dist": dist}

proc foundEvent*(t, half: int, hider, seeker, mode: string,
                 hiddenTicks, hidersLeft: int): JsonNode =
  %*{"type": "found", "t": t, "half": half, "hider": hider,
     "seeker": seeker, "mode": mode, "hidden_s": seconds(hiddenTicks),
     "hiders_left": hidersLeft}

proc halfEndEvent*(t, half: int, hiddenTicks: seq[int],
                   huntTicks: int, perHider: seq[string]): JsonNode =
  var total = 0
  for ticks in hiddenTicks:
    total += ticks
  let denominator = max(1, TeamSize * huntTicks)
  var per = newJArray()
  for index, ticks in hiddenTicks:
    per.add(%*{"alias": perHider[index], "hidden_s": seconds(ticks)})
  %*{"type": "half_end", "t": t, "half": half,
     "hidden_frac": round(total.float * 1000.0 / denominator.float) / 1000.0,
     "hidden_s": seconds(total), "per_hider": per}

proc endEvent*(t: int, reason: EndReason, rule: EndRule,
               scoresMilli: seq[int], fracMicro: seq[int],
               winner: int): JsonNode =
  var scores = newJArray()
  for milli in scoresMilli:
    scores.add(%(milli.float / 1000.0))
  var fracs = newJArray()
  for micro in fracMicro:
    fracs.add(%(round(micro.float / 1000.0) / 1000.0))
  %*{"type": "end", "t": t, "reason": $reason, "end_rule": $rule,
     "scores": scores, "team_hidden_frac": fracs,
     "winner": (if winner < 0: newJNull() else: %winner)}
