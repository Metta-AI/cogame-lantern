## Jev ranks independent fields of Lantern's ordinary order in the player.

import std/[json, os, strutils]
import curly

proc jevConfigured*(): bool =
  getEnv("AWS_ENDPOINT_URL_BEDROCK_RUNTIME").strip().len > 0 or
    (getEnv("METTA_CAPTURE_URL").strip().len > 0 and
      getEnv("METTA_CAPTURE_KEY").strip().len > 0) or
    getEnv("TYPESAFE_API_KEY").strip().len > 0

proc bestChoice(answer, criteria: JsonNode): string =
  if answer["type"].getStr() != "choice":
    raise newException(ValueError, "Jev returned a non-choice answer")
  let probabilities = answer["probabilities"]
  if probabilities.len != criteria.len:
    raise newException(ValueError, "Jev returned the wrong choice set")
  var best = -1.0
  var total = 0.0
  for choice, probability in probabilities.pairs:
    if not criteria.hasKey(choice):
      raise newException(ValueError, "Jev returned an unknown choice")
    let value = probability.getFloat()
    if value < 0 or value > 1:
      raise newException(ValueError, "Jev probability outside [0, 1]")
    total += value
    if value > best:
      best = value
      result = choice
  if abs(total - 1) > probabilities.len.float * 0.005 + 1e-6:
    raise newException(ValueError, "Jev probabilities do not sum to one")

proc chooseJevOrder*(decision: JsonNode, timeoutSeconds: int): JsonNode =
  let view = decision["view"]
  let hider = decision["role"].getStr() == "hider"
  let intents =
    if hider:
      %*{
        "push": "Shove a visible loose crate toward the target.",
        "lock": "Bolt a visible loose crate in place.",
        "hide": "Move to cover and stay still.",
        "flee": "Escape a nearby seeker or flashlight beam.",
        "scout": "Move toward the target to find cover.",
        "wait": "Hold the current position."
      }
    else:
      %*{
        "sweep": "Advance and sweep the flashlight.",
        "beeline": "Move straight toward the target.",
        "chase": "Chase a lit hider.",
        "pry": "Break a visible locked crate.",
        "hold": "Hold a position and sweep the flashlight.",
        "wait": "Hold the current position."
      }
  var points = newJObject()
  var descriptions = newJObject()
  points["self"] = view["you"]["pos"]
  descriptions["self"] = %"Current position"
  for x in 0 ..< 15:
    for y in 0 ..< 8:
      let key = "grid_" & $x & "_" & $y
      let px = 41 + x * 82
      let py = 41 + y * 82
      points[key] = %*[px, py]
      descriptions[key] = %("Map point (" & $px & ", " & $py & ")")
  for index in 0 ..< view["map"]["nooks"].len:
    let nook = view["map"]["nooks"][index]
    let key = "nook_" & $index
    points[key] = nook["anchor"]
    descriptions[key] = %("Cover alcove " & $index)
  let crates = if hider: view["crates"] else: view["lit"]["crates"]
  var crateChoices = %*{"none": "No crate for this order"}
  for index in 0 ..< crates.len:
    let crate = crates[index]
    let key = crate["id"].getStr()
    crateChoices[key] = %(key & " is " & crate["state"].getStr())
    points[key] = crate["pos"]
    descriptions[key] = %("Visible " & key & " crate")
  for index in 0 ..< view["team"].len:
    let hero = view["team"][index]
    let key = "team_" & $index
    points[key] = hero["pos"]
    descriptions[key] = %(hero["alias"].getStr() & " position")
  let targets = if hider: view["seekers_seen"] else: view["lit"]["hiders"]
  for index in 0 ..< targets.len:
    let hero = targets[index]
    let key = "opponent_" & $index
    points[key] = hero["pos"]
    descriptions[key] = %("Visible " & hero["alias"].getStr() & " position")
  for index in 0 ..< view["sounds"].len:
    let sound = view["sounds"][index]
    let key = "sound_" & $index
    points[key] = sound["pos"]
    descriptions[key] = %("Heard " & sound["kind"].getStr() & " near here")

  let aim = %*{
    "sweep": "Keep turning the flashlight while moving.",
    "hold": "Keep the current aim.",
    "track": "Track the current target.",
    "target": "Face the target point."
  }
  let crawl = %*{
    "yes": "Crawl silently at 40 percent speed.",
    "no": "Move at normal speed."
  }
  let shouts = %*{
    "quiet": "",
    "cover": "hold cover",
    "light": "light here",
    "move": "moving",
    "crate": "crate here"
  }
  let notes = %*{
    "quiet": "",
    "cover": "Use crates and walls for cover.",
    "search": "Search the most promising visible area.",
    "team": "Coordinate with nearby teammates."
  }
  let questions = %*{
    "intent": {"type": "choice", "instructions":
      "Choose one legal order intent for this role.", "criteria": intents},
    "target": {"type": "choice", "instructions":
      "Choose the map point for that order. Only visible or static points " &
      "are listed.", "criteria": descriptions},
    "crate": {"type": "choice", "instructions":
      "Choose a visible crate if the intent needs one.",
      "criteria": crateChoices},
    "aim": {"type": "choice", "instructions":
      "Choose the aim mode for the order.", "criteria": aim},
    "crawl": {"type": "choice", "instructions":
      "Choose whether to crawl if hiding; seekers cannot crawl.",
      "criteria": crawl},
    "say": {"type": "choice", "instructions":
      "Choose a short public shout.", "criteria": shouts},
    "note": {"type": "choice", "instructions":
      "Choose a private tactical note.", "criteria": notes}
  }

  let sidecar = getEnv("AWS_ENDPOINT_URL_BEDROCK_RUNTIME").strip()
  let capture = getEnv("METTA_CAPTURE_URL").strip()
  let endpoint =
    if sidecar.len > 0: sidecar
    elif capture.len > 0: capture
    else: getEnv("TYPESAFE_BASE_URL", "https://api.typesafe.ai")
  let model =
    if sidecar.len > 0: "typesafe/jev-1.13"
    elif capture.len > 0: getEnv("METTA_CAPTURE_MODEL", "jev-latest")
    else: getEnv("TYPESAFE_DEFAULT_MODEL", "jev-latest")
  let key =
    if sidecar.len > 0: ""
    elif capture.len > 0: getEnv("METTA_CAPTURE_KEY").strip()
    else: getEnv("TYPESAFE_API_KEY").strip()
  var headers: HttpHeaders
  headers["content-type"] = "application/json"
  if key.len > 0:
    headers["authorization"] = "Bearer " & key
  else:
    headers["x-coworld-player-slot"] = $decision["slot"].getInt()
  let body = %*{
    "model": model,
    "state": "You play one Lantern seat. Your role is " &
      decision["role"].getStr() & ". Choose one complete order for the next " &
      "five seconds. Use only this private observation:\n" & $view,
    "questions": questions
  }
  let response = newCurly().post(endpoint.strip(chars = {'/'},
    leading = false) & "/v1/systemone", headers, $body, timeoutSeconds)
  if response.code < 200 or response.code >= 300:
    raise newException(ValueError, "Jev HTTP " & $response.code)
  let answers = parseJson(response.body)["answers"]
  let intent = bestChoice(answers["intent"], intents)
  let target = bestChoice(answers["target"], descriptions)
  let crate = bestChoice(answers["crate"], crateChoices)
  let aimMode = bestChoice(answers["aim"], aim)
  let crawlMode = bestChoice(answers["crawl"], crawl)
  let say = bestChoice(answers["say"], shouts)
  let note = bestChoice(answers["note"], notes)
  %*{
    "intent": intent,
    "target": points[target],
    "crate": (if crate == "none": newJNull() else: %crate),
    "aim": aimMode,
    "crawl": hider and crawlMode == "yes",
    "note": notes[note],
    "say": shouts[say]
  }
