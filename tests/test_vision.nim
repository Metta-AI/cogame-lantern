## The lantern: range, cone, occlusion, the bubble, and the team radio.
##
## Plus the NO-TRIGONOMETRY SOURCE GUARD. The whole sim step is integer, which
## is what makes the native build and the emscripten replay-viewer build agree
## bit for bit. A single `cos()` or a single `float` on the step path breaks
## that quietly — the replay renders, the digests diverge — so it is grepped
## here rather than left as prose in a comment.

import std/[json, os, strutils, unittest]
import support/helpers

const
  LaneY = 40
  SeekerX = 200

proc lit(sim: Sim): Sim =
  ## Hunt act, one seeker and one hider on a long clear lane.
  result = sim
  result.jumpToHunt()
  result.parkEveryoneElse([0, 1])
  for index in 0 ..< result.crates.len:
    result.crates[index].c = Point(x: 60 + 60 * index, y: 560)
  result.blockDirty = true
  result.place(1, SeekerX, LaneY, aim = 0)      ## Owl-1 seeks in half 1
  result.place(0, SeekerX + 300, LaneY)

suite "the lantern":
  test "the range test is exact at lanternRangePx":
    let sim = lit(testSim())
    sim.place(0, SeekerX + sim.config.lanternRangePx - 1, LaneY)
    check sim.teamLit(sim.cogs[0].px, sim.cogs[0].py)
    sim.place(0, SeekerX + sim.config.lanternRangePx, LaneY)
    check sim.teamLit(sim.cogs[0].px, sim.cogs[0].py)
    sim.place(0, SeekerX + sim.config.lanternRangePx + 1, LaneY)
    check not sim.teamLit(sim.cogs[0].px, sim.cogs[0].py)

  test "the cone test is exact at lanternConeBrads":
    let sim = lit(testSim())
    sim.place(1, SeekerX, LaneY, aim = sim.config.lanternConeBrads)
    check sim.teamLit(sim.cogs[0].px, sim.cogs[0].py)
    sim.place(1, SeekerX, LaneY, aim = sim.config.lanternConeBrads + 1)
    check not sim.teamLit(sim.cogs[0].px, sim.cogs[0].py)
    sim.place(1, SeekerX, LaneY, aim = 256 - sim.config.lanternConeBrads)
    check sim.teamLit(sim.cogs[0].px, sim.cogs[0].py)
    sim.place(1, SeekerX, LaneY, aim = 256 - sim.config.lanternConeBrads - 1)
    check not sim.teamLit(sim.cogs[0].px, sim.cogs[0].py)

  test "a live crate occludes and a broken one does not":
    let sim = lit(testSim())
    check sim.teamLit(sim.cogs[0].px, sim.cogs[0].py)
    sim.crates[0].c = Point(x: SeekerX + 150, y: LaneY)
    sim.crates[0].state = csLoose
    sim.blockDirty = true
    sim.rebakeForTests()
    check not sim.teamLit(sim.cogs[0].px, sim.cogs[0].py)
    sim.crates[0].state = csBroken
    sim.rebakeForTests()
    check sim.teamLit(sim.cogs[0].px, sim.cogs[0].py)

  test "the omni bubble sees behind you, and only just":
    let sim = lit(testSim())
    sim.place(1, SeekerX, LaneY, aim = 0)          ## looking east
    sim.place(0, SeekerX - sim.config.visionBubblePx + 1, LaneY)
    check sim.teamLit(sim.cogs[0].px, sim.cogs[0].py)
    sim.place(0, SeekerX - sim.config.visionBubblePx - 20, LaneY)
    check not sim.teamLit(sim.cogs[0].px, sim.cogs[0].py)

  test "the three seekers share one radio":
    let sim = lit(testSim())
    ## Only Owl-1 can see the hider; Owl-2 and Owl-3 are parked far away and
    ## facing nothing. The shared lit set must still report it to all three.
    check sim.litBySeeker(1, sim.cogs[0].px, sim.cogs[0].py)
    check not sim.litBySeeker(3, sim.cogs[0].px, sim.cogs[0].py)
    check not sim.litBySeeker(5, sim.cogs[0].px, sim.cogs[0].py)
    check sim.teamLit(sim.cogs[0].px, sim.cogs[0].py)
    for seeker in [1, 3, 5]:
      let view = seekerView(sim, seeker)
      var sawMoth1 = false
      for entry in view["lit"]["hiders"]:
        if entry["alias"].getStr() == "Moth-1":
          sawMoth1 = true
          check entry["lit_by"].getStr() == "Owl-1"
      check sawMoth1

  test "a found hider is reported with who found it, how, and when":
    ## The seeker view's `found[]` entries carry the finder and the mode, as
    ## the `found` replay event does; `at_s` is on the seat's own clock, the
    ## hunt act of this half, not the match.
    let sim = testSim()
    sim.jumpToHunt()
    sim.parkEveryoneElse([0, 1])
    sim.place(0, 150, 110)
    sim.place(1, 160, 110)               ## inside TouchTagPx, with sight
    sim.prepareTick()
    sim.applyTick(newSeq[Control](sim.seats))
    check sim.cogs[0].found
    var seen = false
    for entry in seekerView(sim, 1)["found"]:
      if entry["alias"].getStr() == "Moth-1":
        seen = true
        check entry["by"].getStr() == "Owl-1"
        check entry["mode"].getStr() == "tag"
        check entry["at_s"].getFloat() >= 0.0
        check entry["at_s"].getFloat() < 1.0
    check seen

  test "lanterns are off for every build tick":
    let sim = testSim()
    sim.parkEveryoneElse([0, 1])
    sim.place(1, SeekerX, LaneY, aim = 0)
    sim.place(0, SeekerX + 100, LaneY)
    check phaseAt(sim.config, sim.tick).act == actBuild
    check not sim.lanternsOn()
    check not sim.teamLit(sim.cogs[0].px, sim.cogs[0].py)
    sim.jumpToHunt()
    sim.place(1, SeekerX, LaneY, aim = 0)
    sim.place(0, SeekerX + 100, LaneY)
    check sim.lanternsOn()
    check sim.teamLit(sim.cogs[0].px, sim.cogs[0].py)

# ---------------------------------------------------------------------------
# The source guard.
# ---------------------------------------------------------------------------

const
  StepPath = ["types.nim", "arena.nim", "crates.nim", "rules.nim", "sim.nim",
              "control.nim", "baselines.nim"]
    ## The modules the 24 Hz step runs through. These carry NO float at all.
    ## `orders.nim` (the tolerant parse layer), `events.nim`, `config.nim`,
    ## `render.nim`, `replay.nim`, `llm.nim`, `roster.nim`, `broadcast.nim`
    ## and `server.nim` legitimately format seconds and scores as floats, but
    ## none of them is on the step path and none of them may use trigonometry.
  Banned = ["sin", "cos", "tan", "atan", "arctan", "arcsin", "arccos", "exp",
            "ln", "pow", "fmod", "hypot", "sqrt", "degToRad", "radToDeg"]

proc isIdentChar(character: char): bool =
  character in {'a' .. 'z', 'A' .. 'Z', '0' .. '9', '_'}

proc callSites(text, name: string): seq[int] =
  ## Occurrences of `name` used as a CALL: preceded by a non-identifier
  ## character and followed (possibly after spaces) by '('. That is what
  ## keeps `constant`, `distance` and `cost` out of the report.
  var index = 0
  while true:
    let hit = text.find(name, index)
    if hit < 0:
      break
    index = hit + 1
    if hit > 0 and isIdentChar(text[hit - 1]):
      continue
    var after = hit + name.len
    while after < text.len and text[after] == ' ':
      inc after
    if after < text.len and text[after] == '(':
      result.add(hit)

proc lineOf(text: string, offset: int): int =
  result = 1
  for index in 0 ..< offset:
    if text[index] == '\n':
      inc result

suite "the integer-only guard":
  test "no trigonometry anywhere under src/lantern or replay-viewer":
    var offences: seq[string]
    var scanned = 0
    for path in sourcePaths("src/lantern") & sourcePaths("replay-viewer"):
      let text = readFile(path)
      inc scanned
      for name in Banned:
        for offset in callSites(text, name):
          offences.add(path.extractFilename() & ":" & $lineOf(text, offset) &
            " calls " & name & "()")
    check scanned >= len(StepPath)
    if offences.len > 0:
      echo offences.join("\n")
    check offences.len == 0

  test "no float on the step path":
    var offences: seq[string]
    for name in StepPath:
      let path = repoRoot() / "src" / "lantern" / name
      let text = readFile(path)
      var index = 0
      for line in text.splitLines():
        inc index
        let code = line.split("##")[0]
        for token in ["float", "float32", "float64", "cfloat"]:
          var at = code.find(token)
          while at >= 0:
            let before = (if at == 0: ' ' else: code[at - 1])
            let afterAt = at + token.len
            let after = (if afterAt >= code.len: ' ' else: code[afterAt])
            if not isIdentChar(before) and not isIdentChar(after):
              offences.add(name & ":" & $index & " " & code.strip())
              break
            at = code.find(token, at + 1)
    if offences.len > 0:
      echo offences.join("\n")
    check offences.len == 0

  test "no -ffast-math in any build script":
    for relative in ["Dockerfile", "Dockerfile.replay-viewer",
                     "tools/build_replay_viewer.sh",
                     "replay-viewer/config.nims", "lantern.nimble"]:
      check "-ffast-math" notin readRepoFile(relative)
