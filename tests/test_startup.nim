## Startup behaviour of the two binaries, exercised as binaries.
##
## A game container that dies with a Nim traceback on a missing config looks
## like a crashed game to the platform; a player container that exits non-zero
## because it could not dial the socket fails an episode the server already
## knows how to play. Both are cheap to get wrong and invisible until hosted.

import std/[os, osproc, strutils, times, unittest]
import support/helpers

let buildDir = getTempDir() / "lantern-startup-build"

proc build(source, name: string): string =
  result = buildDir / name
  if fileExists(result):
    return
  createDir(buildDir)
  let command = "nim c --hints:off --warnings:off -d:release --path:" &
    quoteShell(repoRoot() / "src") & " --nimcache:" &
    quoteShell(buildDir / ("cache-" & name)) & " --out:" & quoteShell(result) &
    " " & quoteShell(repoRoot() / source)
  let (output, code) = execCmdEx(command, workingDir = repoRoot())
  if code != 0:
    echo output
  doAssert code == 0, "could not build " & source

suite "the game binary":
  let game = build("src/lantern.nim", "lantern")

  test "--help works and says what it needs":
    let (output, code) = execCmdEx(quoteShell(game) & " --help")
    check code == 0
    check "COGAME_CONFIG_URI" in output
    check "/bin/lantern" in output

  test "a missing config exits 2 with one clean line and no traceback":
    let (output, code) = execCmdEx("env -u COGAME_CONFIG_URI " &
      quoteShell(game))
    check code == 2
    check output.strip().splitLines().len == 1
    check output.startsWith("lantern: ")
    check "COGAME_CONFIG_URI" in output
    check "Traceback" notin output
    check "Error: unhandled exception" notin output

  test "an invalid config exits 2 the same way":
    let path = getTempDir() / "lantern-bad-config.json"
    writeFile(path, "{ this is not json")
    let (output, code) = execCmdEx(
      "COGAME_CONFIG_URI=" & quoteShell("file://" & path) & " " &
      quoteShell(game))
    check code == 2
    check output.strip().splitLines().len == 1
    check "Traceback" notin output
    writeFile(path, """{"num_agents": 4, "players": [{"name":"a"}]}""")
    let (seatOutput, seatCode) = execCmdEx(
      "COGAME_CONFIG_URI=" & quoteShell("file://" & path) & " " &
      quoteShell(game))
    check seatCode == 2
    check "seats exactly 6" in seatOutput

suite "the player binary":
  let player = build("src/lantern_player.nim", "lantern-player")

  test "no socket URL at all is a clear exit 1":
    let (output, code) = execCmdEx("env -u COWORLD_PLAYER_WS_URL " &
      quoteShell(player))
    check code == 1
    check "COWORLD_PLAYER_WS_URL" in output

  test "an unreachable game exits 0 after a BOUNDED connect retry":
    ## The server plays a seat that never connects with the warden baseline,
    ## so a player that cannot dial must not fail the episode for it.
    let started = epochTime()
    let (output, code) = execCmdEx(
      "COWORLD_PLAYER_WS_URL=" &
      quoteShell("ws://127.0.0.1:9/player?slot=0&token=t") & " " &
      quoteShell(player))
    let elapsed = epochTime() - started
    check code == 0
    check "the server will play this seat" in output
    check elapsed < 60.0        ## bounded, not open-ended
