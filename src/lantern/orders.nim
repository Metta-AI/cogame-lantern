## The order schema: tolerant parsing, repair, and the rune-boundary caps.
##
## An order is what a policy (LLM or scripted) issues once every five seconds.
## The control layer (`control.nim`) turns it into 120 ticks of quantised
## control bytes. Everything a model can get wrong is repaired here rather
## than rejected, because a rejected order costs a retry and a retry costs
## wall clock; only a reply with no recoverable INTENT is a parse failure.
##
## Every string that can reach the replay is truncated on RUNE boundaries.
## A byte-truncated multi-byte character renders fine in a browser and then
## fails a strict JSON parser — that is the bug this cap exists to prevent.

import std/[json, strutils, unicode]
import types, rules, crates

const
  TargetMinX* = 8
  TargetMaxX* = MapWidth - 8
  TargetMinY* = 8
  TargetMaxY* = MapHeight - 8

proc clip*(text: string, limit: int): string =
  ## Rune-boundary truncation. `runeSubStr` walks codepoints, so the result
  ## is always valid UTF-8 even when rune `limit` is a 4-byte emoji.
  result = text.strip()
  if result.runeLen <= limit:
    return
  result = result.runeSubStr(0, limit)

proc oneLine*(text: string): string =
  text.replace("\n", " ").replace("\r", " ").replace("\t", " ")

proc clampTarget*(x, y: int): Point =
  Point(x: clampInt(x, TargetMinX, TargetMaxX),
        y: clampInt(y, TargetMinY, TargetMaxY))

proc defaultOrder*(role: Role, at: Point): Order =
  Order(intent: defaultIntent(role), target: at, crate: -1, aim: amTarget,
        crawl: false, note: "", say: "")

proc parseIntentText*(text: string): (Intent, bool) =
  for intent in Intent:
    if $intent == text:
      return (intent, true)
  (inWait, false)

proc parseAimText*(text: string): (AimMode, bool) =
  for aim in AimMode:
    if $aim == text:
      return (aim, true)
  (amTarget, false)

proc extractJsonObject*(text: string): JsonNode =
  ## Pull the outermost balanced {...} out of a model reply, tolerating
  ## markdown fences and prose on either side. Bullwhip's shape, widened to
  ## brace matching so a prefixed sentence containing a `}` cannot truncate
  ## the object.
  let start = text.find('{')
  if start < 0:
    var head = text.strip()
    if head.runeLen > 160:
      head = head.runeSubStr(0, 160) & "..."
    raise newException(LanternError,
      "no JSON object in reply: " & head.oneLine())
  var depth = 0
  var inString = false
  var escaped = false
  for index in start ..< text.len:
    let character = text[index]
    if inString:
      if escaped: escaped = false
      elif character == '\\': escaped = true
      elif character == '"': inString = false
      continue
    case character
    of '"': inString = true
    of '{': inc depth
    of '}':
      dec depth
      if depth == 0:
        return parseJson(text[start .. index])
    else: discard
  raise newException(LanternError, "unbalanced JSON object in reply")

proc asInt(node: JsonNode, found: var bool): int =
  found = false
  if node.isNil:
    return 0
  case node.kind
  of JInt:
    found = true
    node.getInt()
  of JFloat:
    found = true
    ## The only float in the parse layer: a model that answers 612.0 means
    ## 612. It never reaches the sim, which consumes the clamped integer.
    int(node.getFloat())
  of JString:
    let text = node.getStr().strip()
    var digits = ""
    for character in text:
      if character == '-' and digits.len == 0: digits.add(character)
      elif character.isDigit: digits.add(character)
      elif character == '.': break
      elif digits.len > 0: break
    if digits.len == 0 or digits == "-":
      return 0
    found = true
    try: parseInt(digits) except ValueError: (found = false; 0)
  else:
    0

proc asBool(node: JsonNode): bool =
  if node.isNil:
    return false
  case node.kind
  of JBool: node.getBool()
  of JInt: node.getInt() != 0
  of JString:
    case node.getStr().strip().toLowerAscii()
    of "true", "1", "yes": true
    else: false
  else: false

proc repairCrate*(order: var Order, role: Role, at: Point,
                  crateList: seq[Crate]) =
  ## An unknown crate id becomes the nearest crate legal for the intent; when
  ## no crate is legal the intent degrades rather than the order failing.
  if not needsCrate(order.intent):
    order.crate = -1
    return
  let want =
    case order.intent
    of inPush: {csLoose}
    of inLock: {csLoose}
    else: {csLocked}
  if order.crate >= 0 and order.crate < crateList.len and
      crateList[order.crate].state in want:
    return
  order.crate = nearestCrate(crateList, at.x, at.y, want)
  if order.crate < 0:
    order.intent =
      case order.intent
      of inPush, inLock: inHide
      else: inSweep
    discard
    if role == roHider: order.intent = inHide
    else: order.intent = inSweep

proc parseOrder*(payload: JsonNode, role: Role, at: Point,
                 crateList: seq[Crate]): Order =
  ## Tolerant parse + repair. Raises only when no usable `intent` survives —
  ## that is the single condition that costs a retry.
  result = defaultOrder(role, at)
  if payload.isNil or payload.kind != JObject:
    raise newException(LanternError, "order is not a JSON object")
  let intentNode = payload{"intent"}
  if intentNode.isNil or intentNode.kind != JString:
    raise newException(LanternError, "order carries no intent")
  let (intent, known) = parseIntentText(intentNode.getStr().strip().toLowerAscii())
  if not known:
    raise newException(LanternError,
      "unknown intent: " & clip(intentNode.getStr(), 32))
  result.intent = (if legalFor(intent, role): intent else: defaultIntent(role))

  var haveX, haveY = false
  var tx, ty = 0
  let targetNode = payload{"target"}
  if not targetNode.isNil and targetNode.kind == JArray and
      targetNode.len >= 2:
    tx = asInt(targetNode[0], haveX)
    ty = asInt(targetNode[1], haveY)
  elif not targetNode.isNil and targetNode.kind == JObject:
    tx = asInt(targetNode{"x"}, haveX)
    ty = asInt(targetNode{"y"}, haveY)
  result.target =
    if haveX and haveY: clampTarget(tx, ty)
    else: clampTarget(at.x, at.y)

  let crateNode = payload{"crate"}
  result.crate = -1
  if not crateNode.isNil:
    case crateNode.kind
    of JString:
      result.crate = parseCrateId(clip(crateNode.getStr(), MaxCrateIdRunes),
                                  crateList.len)
    of JInt:
      let value = crateNode.getInt()
      if value >= 0 and value < crateList.len:
        result.crate = value
    else: discard
  repairCrate(result, role, at, crateList)

  let (aim, aimKnown) = parseAimText(
    payload{"aim"}.getStr().strip().toLowerAscii())
  result.aim = (if aimKnown: aim else: amTarget)
  result.crawl = (if role == roSeeker: false else: asBool(payload{"crawl"}))
  result.note = clip(oneLine(payload{"note"}.getStr()), MaxNoteRunes)
  result.say = clip(oneLine(payload{"say"}.getStr()), MaxSayRunes)

proc parseOrderText*(text: string, role: Role, at: Point,
                     crateList: seq[Crate]): Order =
  parseOrder(extractJsonObject(text), role, at, crateList)

proc orderJson*(order: Order): JsonNode =
  %*{"intent": $order.intent,
     "target": [order.target.x, order.target.y],
     "crate": (if order.crate < 0: newJNull() else: %crateId(order.crate)),
     "aim": $order.aim, "crawl": order.crawl,
     "note": order.note, "say": order.say}

proc orderCrateId*(order: Order): string =
  if order.crate < 0: "" else: crateId(order.crate)
