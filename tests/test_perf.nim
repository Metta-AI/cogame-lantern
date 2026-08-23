## The sim has to be fast enough that the wall clock is spent on the model,
## not on the physics: a full match is three shadow-free lantern passes per
## tick over 5040 ticks, and it has to disappear next to one LLM turn.

import std/[times, unittest]
import support/helpers

suite "performance":
  test "a full 5040-tick match with three lanterns is well under the bound":
    let started = epochTime()
    let sim = testSim(seed = 42, prep = 720, hunt = 1800)
    discard runScriptedEpisode(sim, kindsFor(skWarden, skMoth))
    let elapsed = epochTime() - started
    check sim.tick == 5040
    check sim.keyframes.len == 5040 div ReplayFps
    echo "  full match in ", (elapsed * 1000).int, " ms"
    when defined(release):
      ## The design note's target is >= 4000 ticks/s native; the bound is
      ## deliberately generous so a slow shared runner does not flake it.
      check elapsed < 30.0
    else:
      ## Debug builds run the per-pixel mask code 10-50x slower.
      check elapsed < 180.0

  test "re-deriving a whole match from the control bytes is just as cheap":
    let sim = testSim(seed = 42, prep = 720, hunt = 1800)
    discard runScriptedEpisode(sim, kindsFor(skWarden, skMoth))
    var kinds: seq[string]
    for _ in 0 ..< sim.seats: kinds.add("scripted")
    let document = buildReplay(sim, kinds, sim.scriptedResults())
    let started = epochTime()
    let again = rederive(document)
    let elapsed = epochTime() - started
    check again.ok
    echo "  re-derived ", again.tickCount, " ticks in ",
      (elapsed * 1000).int, " ms"
    when defined(release):
      check elapsed < 30.0
    else:
      check elapsed < 180.0
