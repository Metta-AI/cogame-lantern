## The bounded-orders / legality assertion on the scripted baselines, and the
## ladder-spread property that makes two baselines worth shipping.

import std/[json, unicode, unittest]
import support/helpers

proc legalOrder(order: Order, role: Role, crateCount: int): bool =
  if not legalFor(order.intent, role): return false
  if order.target.x < TargetMinX or order.target.x > TargetMaxX: return false
  if order.target.y < TargetMinY or order.target.y > TargetMaxY: return false
  if order.crate < -1 or order.crate >= crateCount: return false
  if needsCrate(order.intent) and order.crate < 0: return false
  if order.note.runeLen > MaxNoteRunes: return false
  if order.say.runeLen > MaxSayRunes: return false
  if role == roSeeker and order.crawl: return false
  true

proc boundedControl(control: Control): bool =
  int(control.moveX) >= -100 and int(control.moveX) <= 100 and
    int(control.moveY) >= -100 and int(control.moveY) <= 100 and
    int(control.aimTurn) >= -AimTurnRate and
    int(control.aimTurn) <= AimTurnRate and
    (control.action and not 0b111'u8) == 0'u8

suite "the scripted baselines":
  test "500 pseudo-random world states x both baselines x both roles are legal":
    ## The states are reached by playing, not by poking: a baseline that is
    ## only legal on a pristine board is not legal.
    var checkedOrders = 0
    var checkedControls = 0
    for kind in [skWarden, skMoth]:
      for seed in [7, 42, 1009, 20260822]:
        let sim = testSim(seed = seed, prep = 240, hunt = 480)
        while sim.tick < totalTicks(sim.config) and checkedOrders < 600:
          sim.prepareTick()
          if isTurnStart(sim.config, sim.tick):
            let half = phaseAt(sim.config, sim.tick).half
            for slot in 0 ..< sim.seats:
              if sim.cogs[slot].found:
                continue
              let role = roleOfSlot(slot, half)
              let order = scriptedOrder(sim, slot, half, kind)
              check legalOrder(order, role, sim.crates.len)
              inc checkedOrders
              sim.cogs[slot].order = order
              sim.cogs[slot].hasOrder = true
          let controls = compileControls(sim)
          for control in controls:
            check boundedControl(control)
            inc checkedControls
          sim.applyTick(controls)
    check checkedOrders >= 500
    check checkedControls >= 5000

  test "no baseline ever spends a fourth lock":
    for kind in [skWarden, skMoth]:
      let sim = testSim(prep = 720, hunt = 1800)
      discard runScriptedEpisode(sim, kindsFor(kind, kind))
      for slot in 0 ..< sim.seats:
        check sim.cogs[slot].locksUsed <= sim.config.maxLocksPerHider
        check sim.cogs[slot].cratesLocked <= 2 * sim.config.maxLocksPerHider

  test "warden beats moth at seed 42 - the ladder has a spread":
    let sim = testSim(seed = 42, prep = 720, hunt = 1800)
    discard runScriptedEpisode(sim, kindsFor(skWarden, skMoth))
    let results = sim.scriptedResults()
    ## Moth the TEAM is played by the warden baseline here; the Owl seats play
    ## the moth baseline. The warden must win on both sides of the ledger:
    ## it hides longer AND it holds its opponent's hiding down.
    check results["team_hidden_frac"][0].getFloat() >
      results["team_hidden_frac"][1].getFloat()
    check results["scores"][0].getFloat() > 0.5
    check results["winner"].getInt() == 0

  test "the warden really builds: it pushes and it bolts":
    let sim = testSim(seed = 42, prep = 720, hunt = 1800)
    discard runScriptedEpisode(sim, allWarden())
    var locks = 0
    var pushes = 0
    for slot in 0 ..< sim.seats:
      locks += sim.cogs[slot].cratesLocked
      pushes += sim.cogs[slot].cratesPushed
    check locks >= 2
    check pushes > 0
    check sim.countEvents("crate_lock") == locks

  test "PLAYER_SCRIPTED parsing follows the documented spellings":
    check parseScriptKind("warden") == skWarden
    check parseScriptKind("WARDEN") == skWarden
    check parseScriptKind("1") == skWarden
    check parseScriptKind("true") == skWarden
    check parseScriptKind("yes") == skWarden
    check parseScriptKind("moth") == skMoth
    check parseScriptKind("") == skNone
    check parseScriptKind("banana") == skNone
