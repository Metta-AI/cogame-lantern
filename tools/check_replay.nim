## Re-derive complete native replays through the production integer simulator.
import std/[json, os]
import lantern/replay

doAssert paramCount() > 0, "usage: check_replay REPLAY_JSON..."
for path in commandLineParams():
  let result = rederive(parseFile(path))
  doAssert result.mismatchTick == -1, "replay diverged at tick " & $result.mismatchTick
  echo path, ": replay re-derived"
