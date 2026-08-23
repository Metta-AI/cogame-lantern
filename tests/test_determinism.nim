## THE GATE. Same seed + same control bytes => the same digest at every
## keyframe. The whole sim step is integer, so this must hold exactly, in this
## process, in a fresh instance, and (by the same code path) in the emscripten
## viewer build.

import std/[json, unittest]
import support/helpers

proc digestsOf(sim: Sim): seq[uint32] =
  for frame in sim.keyframes:
    result.add(frame.digest)

proc recordEpisode(seed = 42): Sim =
  result = testSim(seed = seed, prep = 240, hunt = 480)
  discard runScriptedEpisode(result, kindsFor(skWarden, skMoth))

suite "determinism":
  test "two runs in one process agree at every keyframe":
    let first = recordEpisode()
    let second = recordEpisode()
    check first.keyframes.len == second.keyframes.len
    check digestsOf(first) == digestsOf(second)
    check first.controls == second.controls

  test "replaying the recorded control bytes reproduces every digest":
    let recorded = recordEpisode()
    let replayed = testSim(prep = 240, hunt = 480)
    var index = 0
    while replayed.tick < recorded.tick:
      replayed.prepareTick()
      let base = replayed.tick * replayed.seats
      replayed.applyTick(recorded.controls[base ..< base + replayed.seats])
      inc index
    check digestsOf(replayed) == digestsOf(recorded)

  test "a one-bit change in any control byte changes the final digest":
    let recorded = recordEpisode()
    ## Flip one bit of one mid-hunt move byte and re-derive. The bit has to
    ## be one the quantiser can see: move bytes are scaled by accel div 100,
    ## so the LOW bit of a 100 is rounded away and proves nothing.
    var controls = recorded.controls
    ## Mid-hunt in half 1, and BEFORE the half boundary erases it: nothing
    ## carries across the intermission except the score, so a nudge in the
    ## last twenty ticks of a half is legitimately invisible afterwards.
    let target = 400 * Seats + 1
    controls[target].moveX = int8(int(controls[target].moveX) xor 64)
    controls[target].moveY = int8(int(controls[target].moveY) xor 64)
    let replayed = testSim(prep = 240, hunt = 480)
    while replayed.tick < recorded.tick:
      replayed.prepareTick()
      let base = replayed.tick * replayed.seats
      replayed.applyTick(controls[base ..< base + replayed.seats])
    check digestsOf(replayed) != digestsOf(recorded)

  test "the committed golden fixture still describes this build":
    let golden = parseJson(readRepoFile("tests/fixtures/golden_digests.json"))
    check golden["game_version"].getStr() == GameVersion
    let sim = testSim(seed = golden["seed"].getInt(),
                      prep = golden["prepTicks"].getInt(),
                      hunt = golden["huntTicks"].getInt())
    discard runScriptedEpisode(sim, kindsFor(skWarden, skMoth))
    check sim.keyframes.len == golden["digests"].len
    for index, frame in sim.keyframes:
      let want = golden["digests"][index]
      check frame.t == want["t"].getInt()
      ## A diff HERE is the rule change. Re-record with
      ## `nim r --path:src tools/record_fixtures.nim`, in the same commit as
      ## the rule, never to make this test green on its own.
      check frame.digest == uint32(want["d"].getBiggestInt())

  test "the digest actually covers the state it claims to":
    let sim = testSim()
    let before = lanternStateDigest(sim, false)
    sim.cogs[3].aim = (sim.cogs[3].aim + 1) and 255
    check lanternStateDigest(sim, false) != before
    sim.cogs[3].aim = (sim.cogs[3].aim - 1) and 255
    check lanternStateDigest(sim, false) == before
    sim.crates[2].state = csLocked
    check lanternStateDigest(sim, false) != before
