## An END-TO-END episode that writes a replay, parsed back STRICTLY.
##
## The replay is the only artifact the platform keeps, and the one failure
## mode that renders in a browser and still breaks everything downstream is a
## string truncated on a byte boundary mid-UTF-8. So the fixture forces a
## non-ASCII `say` into the event stream and the bytes are validated as UTF-8
## BEFORE they are parsed.

import std/[base64, json, os, strutils, tables, unicode, unittest]
import support/helpers

const NonAscii = "vanish \u{1F526} \u00e9"   ## lantern emoji + an accent

proc episode(): Sim =
  result = testSim(seed = 42, prep = 240, hunt = 480)
  while result.tick < totalTicks(result.config):
    result.prepareTick()
    if isTurnStart(result.config, result.tick):
      let phase = phaseAt(result.config, result.tick)
      for slot in 0 ..< result.seats:
        if result.cogs[slot].found:
          continue
        var order = scriptedOrder(result, slot, phase.half,
          (if teamOfSlot(slot) == tmMoth: skWarden else: skMoth))
        ## Force the non-ASCII path: one seat says something with a 4-byte
        ## emoji and a combining-free accent in it, every turn.
        if slot == 0:
          order.say = clip(NonAscii, MaxSayRunes)
          order.note = clip("alcove " & NonAscii, MaxNoteRunes)
        result.cogs[slot].order = order
        result.cogs[slot].orderSource = osScripted
        result.cogs[slot].hasOrder = true
        result.emit(orderEvent(result.tick, phase.turn, slot,
          aliasOfSlot(slot), roleOfSlot(slot, phase.half), osScripted, 0,
          order, orderCrateId(order)))
    let controls = compileControls(result)
    for control in controls:
      result.controls.add(control)
    result.applyTick(controls)

suite "the replay document":
  let sim = episode()
  var kinds: seq[string]
  for _ in 0 ..< sim.seats: kinds.add("scripted")
  let results = sim.scriptedResults()
  let document = buildReplay(sim, kinds, results)
  let path = getTempDir() / "lantern-test-replay.json"
  writeFile(path, $document)
  let resultsPath = getTempDir() / "lantern-test-results.json"
  writeFile(resultsPath, $results)

  test "the bytes on disk are valid UTF-8 and then valid JSON":
    let raw = readFile(path)
    check validateUtf8(raw) == -1          ## bytes first, strictly
    let parsed = parseJson(raw)
    check parsed["protocol"].getStr() == "lantern.replay.v1"
    check validateUtf8(readFile(resultsPath)) == -1
    check parseJson(readFile(resultsPath))["reason"].getStr() == "complete"

  test "the non-ASCII say really made it into the event stream":
    var seen = false
    for event in document["events"]:
      if event{"type"}.getStr() == "order" and
          NonAscii[0 .. 5] in event{"say"}.getStr():
        seen = true
        check event["say"].getStr().runeLen <= MaxSayRunes
        check validateUtf8(event["say"].getStr()) == -1
    check seen

  test "every documented top-level key is present and non-empty":
    for key in ["protocol", "format_version", "game_version", "seed", "config",
                "map", "names", "ticks_per_second", "turn_ticks", "tick_count",
                "phases", "controls_b64", "keyframes", "events", "results"]:
      check document.hasKey(key)
    for key in ["map", "names", "config"]:
      check document[key].len > 0
    for key in ["phases", "keyframes", "events"]:
      check document[key].len > 0
    check document["results"].len > 0
    check document["game_version"].getStr() == GameVersion

  test "controls_b64 decodes to exactly tick_count x 24 bytes":
    let raw = decode(document["controls_b64"].getStr())
    check raw.len == document["tick_count"].getInt() * Seats * 4
    check document["tick_count"].getInt() == totalTicks(sim.config)

  test "results.reason is in the legal enum":
    check document["results"]["reason"].getStr() in
      ["complete", "deadline", "fault"]
    check document["results"]["end_rule"].getStr() in
      ["full_time", "wall_clock", "sim_fault", "host_error"]

  test "the event stream carries an order per active seat per turn":
    var perTurn = initCountTable[int]()
    var kindsSeen = initCountTable[string]()
    for event in document["events"]:
      kindsSeen.inc(event{"type"}.getStr())
      if event{"type"}.getStr() == "order":
        perTurn.inc(event{"turn"}.getInt())
    ## 4 build turns of 3 hiders + 8 hunt turns of up to 6.
    check perTurn.len == totalTurns(sim.config)
    for turn, count in perTurn:
      check count >= TeamSize
    check kindsSeen["crate_lock"] >= 1
    check kindsSeen["found"] >= 1
    check kindsSeen["half_end"] == 1
    check kindsSeen["match_start"] >= 0
    check kindsSeen["end"] == 0            ## the server appends `end` last

  test "re-deriving from seed + map + controls reproduces every digest":
    let again = rederive(document)
    check again.ok
    check again.mismatchTick == -1
    check again.checked == document["keyframes"].len
    check again.tickCount == document["tick_count"].getInt()

  test "a corrupted control stream is caught by the digests, not by luck":
    var broken = document.copy()
    var controls = decodeControls(document["controls_b64"].getStr())
    controls[400 * Seats + 1].moveX = int8(int(controls[400 * Seats + 1].moveX) xor 64)
    controls[400 * Seats + 1].moveY = int8(int(controls[400 * Seats + 1].moveY) xor 64)
    broken["controls_b64"] = %encodeControls(controls)
    let again = rederive(broken)
    check not again.ok
    check again.mismatchTick >= 0

  test "a replay with a foreign protocol is refused":
    var foreign = document.copy()
    foreign["protocol"] = %"bullwhip.replay.v1"
    expect LanternError:
      discard rederive(foreign)

  test "a tick_count that disagrees with the payload is refused":
    var wrong = document.copy()
    wrong["tick_count"] = %(document["tick_count"].getInt() + 3)
    expect LanternError:
      discard rederive(wrong)

  test "the committed smoke fixture still re-derives":
    ## tools/wasm_replay_smoke.cjs feeds this same file to the wasm build.
    let fixture = parseJson(readRepoFile("tests/fixtures/smoke_replay.json"))
    let again = rederive(fixture)
    check again.ok
