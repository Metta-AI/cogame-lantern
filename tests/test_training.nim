import std/[json, unittest]
import support/helpers
import lantern/[training_policy, llm]

suite "private-view training teacher":
  test "unlit crate identities and positions cannot change prompt or target":
    let left = testSim()
    let right = testSim()
    for game in [left, right]:
      game.jumpToHunt()
      game.parkEveryoneElse([0, 1])
      game.place(1, 200, 40, aim = 0)
      game.place(0, 500, 40)
      for index in 0 ..< game.crates.len:
        game.crates[index].c = Point(x: 60 + 60 * index, y: 560)
      game.blockDirty = true
    right.crates[0].c = Point(x: 700, y: 560)
    right.crates[0].state = csLocked
    check not left.teamLit(left.crates[0].c.x, left.crates[0].c.y)
    check not right.teamLit(right.crates[0].c.x, right.crates[0].c.y)
    let first = seatView(left, 1)
    let second = seatView(right, 1)
    check first == second
    check userPrompt(first, "operator", false) == userPrompt(second, "operator", false)
    check teacherReply(first) == teacherReply(second)
    check teacherReply(first)["crate"].kind == JNull
