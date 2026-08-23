## The scoring formula and its sign.

import std/[json, math, unittest]
import support/helpers

proc scoresOf(mothTicks, owlTicks: seq[int], huntTicks: int,
              comparable = true): (int, int) =
  let moth = hiddenFracMicro(mothTicks, huntTicks)
  let owl = hiddenFracMicro(owlTicks, huntTicks)
  scoreMilli(moth, owl, comparable)

suite "scoring":
  test "the worked example from the design note gives 0.378 / 0.622":
    ## Moth's three hiders survive 75 s, 41 s and 12 s; Owl's 75, 75 and 33.
    let (moth, owl) = scoresOf(@[1800, 984, 288], @[1800, 1800, 792], 1800)
    check moth == 378
    check owl == 622
    check moth + owl == 1000

  test "the two scores sum to exactly 1 over 200 randomised tick splits":
    var seed = 1u32
    proc nextValue(limit: int): int =
      seed = seed * 1664525'u32 + 1013904223'u32
      int(seed shr 16) mod (limit + 1)
    for _ in 1 .. 200:
      let hunt = 240 + nextValue(3000)
      var mothTicks, owlTicks: seq[int]
      for _ in 1 .. TeamSize:
        mothTicks.add(nextValue(hunt))
        owlTicks.add(nextValue(hunt))
      let (moth, owl) = scoresOf(mothTicks, owlTicks, hunt)
      check moth + owl == 1000
      check moth >= 0 and moth <= 1000
      check abs(moth.float / 1000.0 + owl.float / 1000.0 - 1.0) < 1e-9

  test "a perfect hide against a perfect shutout is 1.0 / 0.0":
    let (moth, owl) = scoresOf(@[1800, 1800, 1800], @[0, 0, 0], 1800)
    check moth == 1000
    check owl == 0
    check winnerOf(moth) == 0

  test "equal fractions are a draw with winner null":
    let (moth, owl) = scoresOf(@[900, 900, 900], @[900, 900, 900], 1800)
    check moth == 500
    check owl == 500
    check winnerOf(moth) == -1

  test "a deadline cut mid-half-2 normalises by hunt_ticks_played":
    ## Owl only got 600 of its 1800 hunt ticks, and hid for all of them: its
    ## fraction is 1.0, not 1800/5400.
    let mothMicro = hiddenFracMicro(@[1800, 1800, 1800], 1800)
    let owlMicro = hiddenFracMicro(@[600, 600, 600], 600)
    let (moth, owl) = scoreMilli(mothMicro, owlMicro, true)
    check mothMicro == 1_000_000
    check owlMicro == 1_000_000
    check moth == 500
    check owl == 500

  test "a deadline before half 2's hunt gives every seat 0.5":
    let (moth, owl) = scoresOf(@[1800, 1800, 1800], @[0, 0, 0], 1800,
                               comparable = false)
    check moth == 500
    check owl == 500
    check winnerOf(moth) == -1

  test "the results document carries the score six times and sums to 3":
    let sim = testSim(prep = 240, hunt = 480)
    discard runScriptedEpisode(sim, kindsFor(skWarden, skMoth))
    let results = sim.scriptedResults()
    check results["scores"].len == Seats
    var total = 0.0
    for value in results["scores"]:
      total += value.getFloat()
    check abs(total - 3.0) < 1e-9
    check results["reason"].getStr() == "complete"
    check results["end_rule"].getStr() == "full_time"
    check results["hunt_ticks_played"] == %[480, 480]

  test "a fault scores 0.5 for everybody and names no winner":
    let sim = testSim(prep = 240, hunt = 480)
    discard runScriptedEpisode(sim, allWarden())
    let results = sim.scriptedResults(erFault, edSimFault)
    for value in results["scores"]:
      check value.getFloat() == 0.5
    check results["winner"].kind == JNull
    for value in results["win"]:
      check value.getBool() == false
