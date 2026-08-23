## Crates: push, lock and pry — the whole construction layer.

import std/[json, unittest]
import support/helpers

const
  CrateX = 300
  CrateY = 600

proc setup(hunt = false): Sim =
  result = testSim()
  if hunt:
    result.jumpToHunt()
  result.parkEveryoneElse([0, 1])
  ## One crate on the open floor along the south edge; the rest well away.
  for index in 0 ..< result.crates.len:
    result.crates[index].c = Point(x: 60 + 60 * index, y: 120)
    result.crates[index].state = csLoose
  result.crates[0].c = Point(x: CrateX, y: CrateY)
  result.blockDirty = true

suite "crates":
  test "a hider shoves a loose crate exactly 6 px in one contact tick":
    let sim = setup()
    sim.place(0, CrateX - CrateHalf - PlayerHalf, CrateY)
    sim.driveOne(0, 100, 0, 1)
    check sim.crates[0].c.x == CrateX + HiderPushPx
    check sim.countEvents("crate_push") == 1

  test "a seeker shoves the same crate only 4 px":
    let sim = setup(hunt = true)
    sim.place(1, CrateX - CrateHalf - PlayerHalf, CrateY)
    sim.driveOne(1, 100, 0, 1)
    check sim.crates[0].c.x == CrateX + SeekerPushPx

  test "a crawling cog cannot push at all":
    let sim = setup()
    sim.place(0, CrateX - CrateHalf - PlayerHalf, CrateY)
    sim.driveOne(0, 100, 0, 1, action = 0b100'u8)
    check sim.crates[0].c.x == CrateX

  test "a push into a wall moves nothing and reverts the pusher on that axis":
    let sim = setup()
    ## Park the crate against the west wall so it cannot go further west.
    sim.crates[0].c = Point(x: 16 + CrateHalf, y: CrateY)
    sim.blockDirty = true
    sim.place(0, 16 + CrateSize + PlayerHalf - 1, CrateY)
    let beforeX = sim.cogs[0].x
    let beforeY = sim.cogs[0].y
    sim.driveOne(0, -100, 0, 1)
    check sim.crates[0].c.x == 16 + CrateHalf
    check sim.cogs[0].x == beforeX          ## reverted along x
    check sim.cogs[0].y == beforeY          ## and only along x
    check sim.cogs[0].vx == 0

  test "a push into another crate moves nothing":
    let sim = setup()
    sim.crates[1].c = Point(x: CrateX + CrateSize, y: CrateY)
    sim.blockDirty = true
    sim.place(0, CrateX - CrateHalf - PlayerHalf, CrateY)
    sim.driveOne(0, 100, 0, 1)
    check sim.crates[0].c.x == CrateX
    check sim.crates[1].c.x == CrateX + CrateSize

  test "a lock takes exactly lockTicks and only inside the interact range":
    let sim = setup()
    sim.place(0, CrateX - CrateHalf - InteractRangePx + 4, CrateY)
    sim.driveOne(0, 0, 0, sim.config.lockTicks - 1, action = 0b1'u8)
    check sim.crates[0].state == csLoose
    sim.driveOne(0, 0, 0, 1, action = 0b1'u8)
    check sim.crates[0].state == csLocked
    check sim.cogs[0].locksUsed == 1
    check sim.countEvents("crate_lock") == 1

  test "a lock is refused once the seat has spent maxLocksPerHider":
    let sim = setup()
    sim.cogs[0].locksUsed = sim.config.maxLocksPerHider
    sim.place(0, CrateX - CrateHalf - InteractRangePx + 4, CrateY)
    sim.driveOne(0, 0, 0, sim.config.lockTicks + 10, action = 0b1'u8)
    check sim.crates[0].state == csLoose
    check sim.cogs[0].locksUsed == sim.config.maxLocksPerHider

  test "lock progress resets the moment the cog moves":
    let sim = setup()
    sim.place(0, CrateX - CrateHalf - InteractRangePx + 4, CrateY)
    sim.driveOne(0, 0, 0, sim.config.lockTicks - 4, action = 0b1'u8)
    check sim.cogs[0].lockProgress == sim.config.lockTicks - 4
    sim.driveOne(0, 0, -100, 3, action = 0b1'u8)
    check sim.cogs[0].lockProgress == 0
    check sim.crates[0].state == csLoose

  test "a locked crate is immovable by either role":
    let sim = setup(hunt = true)
    sim.crates[0].state = csLocked
    sim.blockDirty = true
    sim.place(0, CrateX - CrateHalf - PlayerHalf, CrateY)
    sim.driveOne(0, 100, 0, 4)
    check sim.crates[0].c.x == CrateX
    sim.place(1, CrateX - CrateHalf - PlayerHalf, CrateY)
    sim.driveOne(1, 100, 0, 4)
    check sim.crates[0].c.x == CrateX

  test "a pry takes exactly pryTicks, breaks the crate and rings 900 px":
    let sim = setup(hunt = true)
    sim.crates[0].state = csLocked
    sim.blockDirty = true
    sim.place(1, CrateX - CrateHalf - InteractRangePx + 4, CrateY)
    sim.driveOne(1, 0, 0, sim.config.pryTicks - 1, action = 0b10'u8)
    check sim.crates[0].state == csLocked
    check sim.countEvents("crate_pry") == 3      ## 25 / 50 / 75 per cent
    sim.driveOne(1, 0, 0, 1, action = 0b10'u8)
    check sim.crates[0].state == csBroken
    check sim.countEvents("crate_break") == 1
    var ring = 0
    for event in sim.events:
      if event{"type"}.getStr() == "sound" and
          event{"kind"}.getStr() == "break":
        ring = event{"radius"}.getInt()
    check ring == BreakSoundPx

  test "a broken crate no longer blocks a push or a body":
    let sim = setup(hunt = true)
    sim.crates[0].state = csBroken
    sim.blockDirty = true
    sim.place(1, CrateX - CrateHalf - PlayerHalf, CrateY)
    sim.driveOne(1, 100, 0, 6)
    check sim.cogs[1].px > CrateX - CrateHalf - PlayerHalf

  test "crate ids round-trip and reject nonsense":
    check parseCrateId("C4", 10) == 4
    check parseCrateId("c4", 10) == 4
    check parseCrateId("4", 10) == 4
    check parseCrateId("C42", 10) == -1
    check parseCrateId("", 10) == -1
    check parseCrateId("banana", 10) == -1
    check crateId(7) == "C7"
