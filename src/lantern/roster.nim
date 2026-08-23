## Seat roster: slots, tokens, registration and the policy label.
##
## A lantern player container does exactly one thing on connect: it sends a
## single `register` frame carrying its prompt (or its baseline name). All
## decisions are made in the game server, so a seat that never registers is
## not a failure — it is a `warden` seat, reported once and played to full
## time.

import std/[json, unicode]
import types, baselines

type
  Seat* = object
    prompt*: string
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
    result.seats[slot].scripted = skNone

proc authorised*(roster: Roster, slot: int, token: string): bool =
  slot >= 0 and slot < roster.tokens.len and roster.tokens[slot] == token

proc policyKind*(seat: Seat): string =
  ## What the results and the replay record about a seat: the KIND of policy,
  ## never its text.
  if seat.scripted != skNone: "scripted"
  elif seat.prompt.strip().len > 0: "llm"
  else: "scripted"

proc applyRegister*(roster: var Roster, slot: int, frame: JsonNode) =
  ## `{"type":"register","prompt":...,"scripted":...,"policy":...}`.
  ## A frame with neither field registers the warden baseline, which is also
  ## what a seat that never registers at all gets.
  if slot < 0 or slot >= roster.seats.len:
    return
  var prompt = frame{"prompt"}.getStr()
  if prompt.runeLen > MaxPromptRunes:
    prompt = prompt.runeSubStr(0, MaxPromptRunes)
  roster.seats[slot].prompt = prompt
  let node = frame{"scripted"}
  roster.seats[slot].scripted =
    if node.isNil: skNone
    elif node.kind == JBool: (if node.getBool(): skWarden else: skNone)
    else: parseScriptKind(node.getStr())
  var label = frame{"policy"}.getStr()
  if label.runeLen > MaxPolicyRunes:
    label = label.runeSubStr(0, MaxPolicyRunes)
  roster.seats[slot].policy = label
  roster.seats[slot].registered = true

proc prompts*(roster: Roster): seq[string] =
  for seat in roster.seats:
    result.add(seat.prompt)

proc scriptKinds*(roster: Roster): seq[ScriptKind] =
  for seat in roster.seats:
    result.add(seat.scripted)

proc policyKinds*(roster: Roster): seq[string] =
  for seat in roster.seats:
    result.add(policyKind(seat))
