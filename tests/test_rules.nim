## Detection, the phase clock and the half reset.

import std/[json, unittest]
import support/helpers

suite "the phase clock":
  test "every boundary maps to the right half, act and turn":
    let config = testConfig(prep = 720, hunt = 1800)
    check totalTicks(config) == 5040
    check totalTurns(config) == 42
    for (tick, half, act, turn) in [
        (0, 1, actBuild, 0), (719, 1, actBuild, 5), (720, 1, actHunt, 6),
        (2519, 1, actHunt, 20), (2520, 2, actBuild, 21),
        (3239, 2, actBuild, 26), (3240, 2, actHunt, 27),
        (5039, 2, actHunt, 41)]:
      let phase = phaseAt(config, tick)
      check (tick, phase.half, phase.act, phase.turn) == (tick, half, act, turn)

  test "a decision turn never straddles an act boundary":
    let config = testConfig(prep = 720, hunt = 1800)
    check config.prepTicks mod config.turnTicks == 0
    check config.huntTicks mod config.turnTicks == 0
    check isTurnStart(config, config.prepTicks)
    check isHalfBoundary(config, halfTicks(config))

  test "the certification fixture's clock is 1440 ticks and 12 turns":
    let config = testConfig(prep = 240, hunt = 480)
    check totalTicks(config) == 1440
    check totalTurns(config) == 12

suite "detection":
  test "lockOnTicks fires at exactly 12 consecutive lit ticks":
    let sim = testSim()
    sim.jumpToHunt()
    sim.parkEveryoneElse([0, 1])
    for index in 0 ..< sim.crates.len:
      sim.crates[index].c = Point(x: 60 + 60 * index, y: 560)
    sim.rebakeForTests()
    sim.place(1, 200, 40, aim = 0)
    sim.place(0, 400, 40)
    for _ in 1 .. sim.config.lockOnTicks - 1:
      sim.prepareTick()
      sim.applyTick(newSeq[Control](sim.seats))
      sim.place(1, 200, 40, aim = 0)
      sim.place(0, 400, 40)
    check not sim.cogs[0].found
    check sim.cogs[0].litStreak == sim.config.lockOnTicks - 1
    sim.prepareTick()
    sim.applyTick(newSeq[Control](sim.seats))
    check sim.cogs[0].found
    var foundMoth1 = 0
    var spotMoth1 = 0
    for event in sim.events:
      if event{"type"}.getStr() == "found" and
          event{"hider"}.getStr() == "Moth-1": inc foundMoth1
      if event{"type"}.getStr() == "spot" and
          event{"hider"}.getStr() == "Moth-1": inc spotMoth1
    check foundMoth1 == 1
    check spotMoth1 == 1

  test "an 11-tick streak broken for one tick does not find anybody":
    let sim = testSim()
    sim.jumpToHunt()
    sim.parkEveryoneElse([0, 1])
    for index in 0 ..< sim.crates.len:
      sim.crates[index].c = Point(x: 60 + 60 * index, y: 560)
    sim.rebakeForTests()
    for round in 1 .. 3:
      for _ in 1 .. sim.config.lockOnTicks - 1:
        sim.place(1, 200, 40, aim = 0)
        sim.place(0, 400, 40)
        sim.prepareTick()
        sim.applyTick(newSeq[Control](sim.seats))
      ## one tick with the beam pointed away resets the streak
      sim.place(1, 200, 40, aim = 128)
      sim.place(0, 400, 40)
      sim.prepareTick()
      sim.applyTick(newSeq[Control](sim.seats))
      check sim.cogs[0].litStreak == 0
    check not sim.cogs[0].found

  test "a touch tag fires at 24 px and not at 25":
    proc tagged(gap: int): bool =
      let sim = testSim()
      sim.jumpToHunt()
      sim.parkEveryoneElse([0, 1])
      for index in 0 ..< sim.crates.len:
        sim.crates[index].c = Point(x: 60 + 60 * index, y: 560)
      sim.rebakeForTests()
      sim.place(1, 200, 40, aim = 128)      ## looking AWAY, so this is a tag
      sim.place(0, 200 + gap, 40)
      sim.prepareTick()
      sim.applyTick(newSeq[Control](sim.seats))
      sim.cogs[0].found
    check tagged(TouchTagPx)
    check not tagged(TouchTagPx + 40)

  test "a found hider stops accruing and is inert":
    let sim = testSim()
    sim.jumpToHunt()
    sim.parkEveryoneElse([0, 1])
    for index in 0 ..< sim.crates.len:
      sim.crates[index].c = Point(x: 60 + 60 * index, y: 560)
    sim.rebakeForTests()
    sim.place(1, 200, 40, aim = 128)
    sim.place(0, 210, 40)
    sim.prepareTick()
    sim.applyTick(newSeq[Control](sim.seats))
    check sim.cogs[0].found
    let hidden = sim.cogs[0].hiddenTicks
    let caught = sim.cogs[0].px
    sim.driveOne(0, 100, 0, 40)
    check sim.cogs[0].hiddenTicks == hidden
    check sim.cogs[0].px == caught

suite "the half reset":
  test "it restores every crate, every body, the locks and the pen door":
    let sim = testSim(prep = 240, hunt = 480)
    let start = sim.crates[0].c
    while sim.tick < halfTicks(sim.config):
      sim.prepareTick()
      sim.applyTick(newSeq[Control](sim.seats))
    sim.crates[0].c = Point(x: 300, y: 600)
    sim.crates[1].state = csLocked
    sim.crates[2].state = csBroken
    sim.cogs[0].locksUsed = 3
    sim.cogs[0].found = true
    check not sim.doorSolid                 ## the hunt act had it open
    sim.prepareTick()                       ## crosses the boundary
    check phaseAt(sim.config, sim.tick).half == 2
    check sim.crates[0].c == start
    for crate in sim.crates:
      check crate.state == csLoose
    for cog in sim.cogs:
      check cog.locksUsed == 0
      check not cog.found
      check cog.vx == 0 and cog.vy == 0
    check sim.doorSolid
    check sim.countEvents("half_end") == 1
    check sim.countEvents("half_start") == 1

  test "all_found ends the act and the denominator is unchanged":
    let sim = testSim(prep = 240, hunt = 480)
    sim.jumpToHunt()
    ## Every hider found mid-hunt: the act ends, but the score denominator is
    ## 3 * huntTicks either way, so the halves stay comparable.
    for slot in 0 ..< sim.seats:
      if roleOfSlot(slot, 1) == roHider:
        sim.cogs[slot].found = true
    sim.prepareTick()
    sim.applyTick(newSeq[Control](sim.seats))
    var reasons: seq[string]
    for event in sim.events:
      if event{"type"}.getStr() == "act_end":
        reasons.add(event{"reason"}.getStr())
    check reasons == @["time", "all_found"]
    while sim.tick < totalTicks(sim.config):
      sim.prepareTick()
      sim.applyTick(newSeq[Control](sim.seats))
    check sim.huntTicksPlayed[0] == sim.config.huntTicks
    check sim.huntTicksPlayed[1] == sim.config.huntTicks
