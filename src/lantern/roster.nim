## Seat roster: slots, tokens, registration and the policy label.
##
## A player registers its policy kind; model prompts stay in the player.

import std/[json, unicode]
import types, baselines

type
  PolicyKind* = enum
    pkScripted, pkPrompt, pkExternal

  Seat* = object
    kind*: PolicyKind
    scripted*: ScriptKind
    policy*: string          ## a free label, spectator-side only
    registered*: bool
    connected*: bool
    everConnected*: bool

  Roster* = object
    seats*: seq[Seat]
    tokens*: seq[string]

proc initRoster*(config: GameConfig): Roster =
  result.tokens = config.tokens
  result.seats = newSeq[Seat](config.numAgents)
  for slot in 0 ..< config.numAgents:
    result.seats[slot].scripted = skWarden

proc authorised*(roster: Roster, slot: int, token: string): bool =
  slot >= 0 and slot < roster.tokens.len and roster.tokens[slot] == token

proc policyKind*(seat: Seat): string =
  ## What the results and the replay record about a seat: the KIND of policy,
  ## never its text.
  if seat.kind == pkScripted: "scripted" else: "llm"

proc applyRegister*(roster: var Roster, slot: int, frame: JsonNode) =
  ## `{"type":"register","kind":"scripted|prompt|external",...}`.
  if slot < 0 or slot >= roster.seats.len:
    return
  var seat = roster.seats[slot]
  seat.kind =
    case frame["kind"].getStr()
    of "scripted": pkScripted
    of "prompt": pkPrompt
    of "external": pkExternal
    else: raise newException(LanternError, "unknown player policy kind")
  seat.scripted = skNone
  if seat.kind == pkScripted:
    let script = frame{"scripted"}
    seat.scripted =
      if script.isNil or script.kind == JNull: skWarden
      else: parseScriptKind(script.getStr())
    if seat.scripted == skNone:
      raise newException(LanternError, "unknown scripted baseline")
  var label = frame{"policy"}.getStr()
  if label.runeLen > MaxPolicyRunes:
    label = label.runeSubStr(0, MaxPolicyRunes)
  seat.policy = label
  seat.registered = true
  roster.seats[slot] = seat

proc scriptKinds*(roster: Roster): seq[ScriptKind] =
  for seat in roster.seats:
    result.add(if seat.kind == pkScripted: seat.scripted else: skNone)

proc policyKinds*(roster: Roster): seq[string] =
  for seat in roster.seats:
    result.add(policyKind(seat))
