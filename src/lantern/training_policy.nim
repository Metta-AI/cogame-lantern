## A local teacher over the exact private observation supplied to a player.
## No simulation reference, hidden crate list, or opponent state enters here.

import std/json

proc teacherReply*(view: JsonNode): JsonNode =
  let here = view["you"]["pos"]
  let nooks = view["map"]["nooks"]
  let nook = nooks[(view["turn"].getInt() div 4) mod nooks.len]["anchor"]
  result = %*{"intent": "wait", "target": here, "crate": newJNull(),
    "aim": "target", "crawl": false, "note": "", "say": ""}
  if view.hasKey("lit"):
    result["intent"] = %"sweep"
    result["target"] = copy(nook)
    result["aim"] = %"sweep"
    if view["lit"]["hiders"].len > 0:
      result["intent"] = %"chase"
      result["target"] = copy(view["lit"]["hiders"][0]["pos"])
      result["aim"] = %"track"
  elif view["act"].getStr() == "build":
    result["intent"] = %"hide"
    result["target"] = copy(nook)
    if view["you"]["locks_left"].getInt() > 0:
      var nearest = -1
      var distance = high(int)
      for index in 0 ..< view["crates"].len:
        let crate = view["crates"][index]
        if crate["state"].getStr() != "loose": continue
        let dx = crate["pos"][0].getInt() - here[0].getInt()
        let dy = crate["pos"][1].getInt() - here[1].getInt()
        if dx * dx + dy * dy < distance:
          nearest = index
          distance = dx * dx + dy * dy
      if nearest >= 0:
        result["intent"] = %"lock"
        result["target"] = copy(view["crates"][nearest]["pos"])
        result["crate"] = copy(view["crates"][nearest]["id"])
  else:
    result["intent"] = %(if view["beams"].len > 0: "flee" else: "hide")
    result["target"] = copy(nook)
    result["crawl"] = %true
