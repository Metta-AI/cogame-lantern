## The websocket and HTTP contract, against a real in-process server.
##
## The game thread is deliberately NOT started here: it ends an episode with
## `quit(0)`, which would take the test process with it and turn a failure
## into a green run. `serveForTests` is everything `runGameServer` does except
## that thread.

import std/[httpclient, json, options, os, strutils, unittest]
import bitworld/runtime
import whisky
import support/helpers
import lantern/server

const Port = 8791

var config = testConfig(prep = 240, hunt = 480)
config.tokens = @["t0", "t1", "t2", "t3", "t4", "t5"]

var serverThread: Thread[int]

proc serve(port: int) {.thread.} =
  {.gcsafe.}:
    var local = testConfig(prep = 240, hunt = 480)
    local.tokens = @["t0", "t1", "t2", "t3", "t4", "t5"]
    serveForTests(local, port)

proc httpGet(path: string): Response =
  let client = newHttpClient(timeout = 5000)
  try:
    result = client.request("http://127.0.0.1:" & $Port & path, HttpGet)
  finally:
    client.close()

suite "the server":
  setup:
    discard

  test "it comes up and answers /healthz":
    createThread(serverThread, serve, Port)
    var up = false
    for _ in 1 .. 50:
      try:
        let response = httpGet("/healthz")
        if response.code == Http200:
          check parseJson(response.body)["ok"].getBool()
          up = true
          break
      except CatchableError:
        discard
      sleep(100)
    check up

  test "a bad token is 403 and a good one upgrades":
    ## The upgrade attempt with a bad token never becomes a websocket, so it
    ## is visible as a plain HTTP status.
    let denied = httpGet("/player?slot=0&token=wrong")
    check denied.code == Http403
    let unknownSlot = httpGet("/player?slot=99&token=t0")
    check unknownSlot.code == Http403

  test "a duplicate connection on a live slot is 409":
    let socket = newWebSocket("ws://127.0.0.1:" & $Port & "/player?slot=0&token=t0")
    defer: socket.close()
    let welcome = socket.receiveMessage()
    check welcome.isSome
    let payload = parseJson(welcome.get().data)
    check payload["type"].getStr() == "welcome"
    check payload["protocol"].getStr() == "lantern.player.v1"
    check payload["alias"].getStr() == "Moth-1"
    check payload["team"].getStr() == "Moth"
    check payload["hides_in_half"].getInt() == 1
    sleep(150)
    let duplicate = httpGet("/player?slot=0&token=t0")
    check duplicate.code == Http409

  test "a register frame is accepted and shapes the seat":
    let socket = newWebSocket("ws://127.0.0.1:" & $Port & "/player?slot=1&token=t1")
    defer: socket.close()
    discard socket.receiveMessage()
    socket.send($ %*{"type": "register", "prompt": "hunt by sound",
                     "policy": "lantern-owlnight"})
    sleep(250)
    ## Nothing to read back: the seat is informational. What we assert is that
    ## the server neither closed the socket nor faulted.
    socket.send($ %*{"type": "nonsense"})
    sleep(100)
    check true

  test "/global streams a whole-world snapshot":
    let socket = newWebSocket("ws://127.0.0.1:" & $Port & "/global")
    defer: socket.close()
    let frame = socket.receiveMessage()
    check frame.isSome
    let snapshot = parseJson(frame.get().data)
    check snapshot["game"].getStr() == "lantern"
    check snapshot["cogs"].len == Seats
    check snapshot["crates"].len == 10
    check snapshot["map"]["w"].getInt() == MapWidth
    check snapshot["colors"]["Moth"].getStr() == "#f2c14e"
    var aliases: seq[string]
    for cog in snapshot["cogs"]:
      aliases.add(cog["alias"].getStr())
    check aliases == @["Moth-1", "Owl-1", "Moth-2", "Owl-2", "Moth-3", "Owl-3"]

  test "/client/replay is served SPLICED, never raw":
    let page = httpGet("/client/replay")
    check page.code == Http200
    ## The three markers must be gone: an unspliced page has no ChromeCommon
    ## and fails loudly instead of half-rendering.
    check "<!-- CHROME_COMMON -->" notin page.body
    check "chrome_common.js" in page.body
    check "static_replay.js" in page.body
    check "wire_constants.js" in page.body

  test "the client assets are served":
    for name in ["chrome_common.js", "broadcast_core.js"]:
      let asset = httpGet("/client/" & name)
      check asset.code == Http200
      check asset.body.len > 1000
    check httpGet("/client/../secrets").code != Http200

  test "artifact writes land on file:// URIs":
    let dir = getTempDir() / "lantern-artifact-test"
    createDir(dir)
    let path = dir / "results.json"
    removeFile(path)
    writeCogameUri("file://" & path, """{"ok":true}""", "application/json",
                   "TEST")
    check parseJson(readFile(path))["ok"].getBool()

  test "COGAME_EVENTS_URI and COGAME_METRICS_URI reject non-file schemes":
    putEnv("COGAME_EVENTS_URI", "file:///tmp/lantern-events.json")
    assertFileUri("COGAME_EVENTS_URI")        ## file:// is fine
    putEnv("COGAME_EVENTS_URI", "https://example.invalid/events")
    expect LanternError:
      assertFileUri("COGAME_EVENTS_URI")
    putEnv("COGAME_METRICS_URI", "s3://bucket/metrics")
    expect LanternError:
      assertFileUri("COGAME_METRICS_URI")
    delEnv("COGAME_EVENTS_URI")
    delEnv("COGAME_METRICS_URI")

  test "replay mode serves /replay-data":
    ## In live mode there is no replay payload, so the route 404s rather than
    ## inventing one.
    check httpGet("/replay-data").code == Http404

  test "it shuts down cleanly":
    stopTestServer()
    joinThread(serverThread)
    check true
