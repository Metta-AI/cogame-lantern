## Tolerant parsing, repair, and the RUNE-boundary caps.
##
## A byte-truncated multi-byte character renders fine in a browser and then
## fails a strict JSON parser: that is the bug these caps exist to prevent, so
## the emoji case here is the point of the file, not a curiosity.

import std/[json, strutils, unicode, unittest]
import support/helpers

let crateList = block:
  var list: seq[Crate]
  for index in 0 ..< 10:
    list.add(Crate(c: Point(x: 100 + 60 * index, y: 300), state: csLoose))
  list[3].state = csLocked
  list

const Here = Point(x: 600, y: 300)

proc hider(text: string): Order =
  parseOrderText(text, roHider, Here, crateList)

proc seeker(text: string): Order =
  parseOrderText(text, roSeeker, Here, crateList)

suite "tolerant parsing":
  test "plain JSON":
    let order = hider("""{"intent":"hide","target":[200,200],"crawl":true}""")
    check order.intent == inHide
    check order.target == Point(x: 200, y: 200)
    check order.crawl

  test "prose before and after the object":
    let order = hider("""Sure! Here is my order:
      {"intent":"scout","target":[300,300]}
      Let me know if you want a different alcove.""")
    check order.intent == inScout

  test "a markdown fence":
    let order = hider("```json\n{\"intent\":\"wait\"}\n```")
    check order.intent == inWait

  test "a prefix containing a stray closing brace":
    let order = hider("""I considered } and then decided.
      {"intent":"flee","target":[10,10],"note":"beam"}""")
    check order.intent == inFlee
    check order.note == "beam"

  test "no object at all raises, which is what costs the retry":
    expect LanternError:
      discard hider("I would rather not say.")
    expect LanternError:
      discard hider("""{"target":[10,10]}""")     ## no intent
    expect LanternError:
      discard hider("""{"intent":"teleport"}""")  ## unknown intent

suite "repair":
  test "a seeker intent from a hider degrades to hide":
    check hider("""{"intent":"pry","crate":"C3"}""").intent == inHide
  test "a hider intent from a seeker degrades to sweep":
    check seeker("""{"intent":"lock","crate":"C1"}""").intent == inSweep

  test "target accepts numeric strings and objects, and is clamped":
    check hider("""{"intent":"hide","target":["612","118"]}""").target ==
      Point(x: 612, y: 118)
    check hider("""{"intent":"hide","target":{"x":50,"y":60}}""").target ==
      Point(x: 50, y: 60)
    check hider("""{"intent":"hide","target":[-9000,9000]}""").target ==
      Point(x: TargetMinX, y: TargetMaxY)
    check hider("""{"intent":"hide","target":[612.0,118.7]}""").target ==
      Point(x: 612, y: 118)

  test "a missing target becomes the cog's own position":
    check hider("""{"intent":"hide"}""").target == Here

  test "crate accepts 4, \"c4\" and \"C4\", and rejects \"C42\"":
    check hider("""{"intent":"push","crate":4,"target":[10,10]}""").crate == 4
    check hider("""{"intent":"push","crate":"c4","target":[10,10]}""").crate == 4
    check hider("""{"intent":"push","crate":"C4","target":[10,10]}""").crate == 4
    ## C42 is not a crate: the intent keeps its meaning by falling back to the
    ## nearest crate that IS legal for it, rather than the order failing.
    let repaired = hider("""{"intent":"push","crate":"C42","target":[10,10]}""")
    check repaired.intent == inPush
    check repaired.crate >= 0
    check crateList[repaired.crate].state == csLoose

  test "a pry order snaps to a LOCKED crate, a push to a loose one":
    check crateList[seeker("""{"intent":"pry","crate":"C0"}""").crate].state ==
      csLocked
    check crateList[hider("""{"intent":"push","crate":"C3"}""").crate].state ==
      csLoose

  test "an unknown aim becomes target, and a seeker never crawls":
    check hider("""{"intent":"hide","aim":"spin"}""").aim == amTarget
    check seeker("""{"intent":"sweep","crawl":true}""").crawl == false
    check hider("""{"intent":"hide","crawl":"true"}""").crawl
    check hider("""{"intent":"hide","crawl":1}""").crawl
    check hider("""{"intent":"hide","crawl":"maybe"}""").crawl == false

suite "rune-boundary truncation":
  test "a 400-character note is cut to exactly 140 runes":
    let order = hider("""{"intent":"hide","note":"""" &
      "x".repeat(400) & """"}""")
    check order.note.runeLen == MaxNoteRunes

  test "a say whose 32nd and 33rd runes are 4-byte emoji cuts on the RUNE":
    ## 31 ASCII runes, then two 4-byte emoji. Rune 32 is the first emoji, so
    ## the cut must keep it whole and drop the second entirely.
    let say = "a".repeat(31) & "\u{1F526}\u{1F50E}"
    check say.runeLen == 33
    check say.len == 31 + 8            ## bytes, not runes
    let order = hider($ %*{"intent": "hide", "say": say})
    check order.say.runeLen == MaxSayRunes
    check order.say == "a".repeat(31) & "\u{1F526}"
    check validateUtf8(order.say) == -1
    ## and it survives a strict round trip through the replay encoder
    let encoded = $orderJson(order)
    check validateUtf8(encoded) == -1
    check parseJson(encoded)["say"].getStr() == order.say

  test "the caps hold for every string that reaches the replay":
    check clip("x".repeat(500), MaxDetailRunes).runeLen == MaxDetailRunes
    check clip("\u{1F526}".repeat(500), MaxPolicyRunes).runeLen ==
      MaxPolicyRunes
    check validateUtf8(clip("\u{1F526}".repeat(500), MaxPolicyRunes)) == -1

  test "a note with newlines becomes one line":
    check hider("""{"intent":"hide","note":"a\nb\tc"}""").note == "a b c"

suite "the two-failure ladder":
  test "two unusable replies leave the seat on the warden order":
    ## `decideAll` is exercised end to end in tests/test_engine.nim; here we
    ## assert the contract this file owns: an unusable reply RAISES, which is
    ## the only thing that costs an attempt.
    var failures = 0
    for reply in ["", "no.", "{}", """{"intent":"fly"}""", "{\"intent\":"]:
      try:
        discard hider(reply)
      except CatchableError:
        inc failures
    check failures == 5
