## Motion: the integer step that everything else rests on.

import std/unittest
import support/helpers

suite "motion":
  test "a cog accelerates to exactly its top speed and no further":
    let sim = testSim()
    sim.parkEveryoneElse([0])
    sim.place(0, 200, 620)
    sim.driveOne(0, 100, 0, 30)
    check sim.cogs[0].vx <= MaxSpeed
    ## 200 ticks at Accel = 76 is far past the clamp, so it must be AT it.
    check sim.cogs[0].vx == MaxSpeed

  test "a seeker is faster than a hider, and a crawler is 40 percent":
    check topSpeed(roSeeker, false) == SeekerMaxSpeed
    check topSpeed(roHider, false) == MaxSpeed
    check topSpeed(roHider, true) == MaxSpeed * CrawlPercent div 100
    check topSpeed(roSeeker, true) == SeekerMaxSpeed * CrawlPercent div 100

  test "friction brings a cog to rest below StopThreshold":
    let sim = testSim()
    sim.parkEveryoneElse([0])
    sim.place(0, 200, 620)
    sim.driveOne(0, 100, 0, 40)
    check sim.cogs[0].vx > StopThreshold
    sim.driveOne(0, 0, 0, 60)
    check sim.cogs[0].vx == 0
    check sim.cogs[0].vy == 0

  test "the wall slide keeps a cog inside the arena under 2000 ticks of hammering":
    let sim = testSim(prep = 2400, hunt = 480)
    sim.parkEveryoneElse([0])
    sim.place(0, 200, 620)
    var tick = 0
    while tick < 2000:
      let direction = tick div 250
      let moveX = [100, -100, 0, 0, 100, -100, 100, -100][direction and 7]
      let moveY = [0, 0, 100, -100, 100, -100, -100, 100][direction and 7]
      sim.driveOne(0, moveX, moveY, 1)
      check sim.cogs[0].px >= PlayerHalf
      check sim.cogs[0].py >= PlayerHalf
      check sim.cogs[0].px < MapWidth - PlayerHalf
      check sim.cogs[0].py < MapHeight - PlayerHalf
      inc tick

  test "cog-cog overlap resolves symmetrically when the slots are swapped":
    proc separation(first, second: int): (int, int) =
      let sim = testSim()
      sim.parkEveryoneElse([first, second])
      sim.place(first, 200, 620)
      sim.place(second, 204, 620)
      sim.prepareTick()
      sim.applyTick(newSeq[Control](sim.seats))
      (sim.cogs[first].x - 200 * MotionScale,
       sim.cogs[second].x - 204 * MotionScale)
    let (aLow, bLow) = separation(0, 2)
    let (aHigh, bHigh) = separation(2, 0)
    ## Swapping which slot index holds which body mirrors the outcome
    ## exactly: neither index is privileged in the pair resolution.
    check aLow == aHigh
    check bLow == bHigh
    check aLow < 0
    check bLow > 0

  test "a crawling cog is capped at 40 percent and makes no footstep sound":
    let sim = testSim()
    sim.parkEveryoneElse([0])
    sim.place(0, 200, 620)
    sim.driveOne(0, 100, 0, 60, action = 0b100'u8)
    check sim.cogs[0].crawling
    check sim.cogs[0].vx == MaxSpeed * CrawlPercent div 100
    check sim.countEvents("sound") == 0

  test "a running cog does emit footstep rings, at most one per 24 ticks":
    let sim = testSim()
    sim.parkEveryoneElse([0])
    sim.place(0, 200, 620)
    sim.driveOne(0, 100, 0, 96)
    let steps = sim.countEvents("sound")
    check steps >= 3
    check steps <= 5
