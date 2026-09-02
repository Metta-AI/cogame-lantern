## The viewer smoke, and the static assertions on the chrome.
##
## The wasm half needs an emsdk build, which only the wasm-viewer CI job has;
## when replay-viewer/dist is absent this file says so and runs the static
## half, which is where the regressions that actually happen live: a dropped
## chrome id, a missing readiness bridge, a scorebug that collapses to "..."
## in the 360 px featured embed.

import std/[json, os, osproc, strutils, unittest]
import support/helpers

let page = readRepoFile("client/replay_broadcast.html")
let shell = readRepoFile("replay-viewer/static_replay.js")
let worker = readRepoFile("replay-viewer/static_replay_worker.js")
let chrome = readRepoFile("client/chrome_common.js")

const InheritedIds = [
  "viewport", "stage", "board", "lightpool", "grain", "chrome", "scorebug",
  "plates-l", "plates-r", "clock", "clock-time", "clock-caption", "ffwd-mini",
  "mmwarn", "bannerlane", "killfeed",
  "transport", "btn-restart", "btn-back", "btn-play", "btn-fwd", "btn-end",
  "btn-loop", "btn-skip", "btn-spoilers", "ffwd-chip", "win-chip",
  "tick-clock", "speedchips", "scrub", "momentum", "scrub-fill", "lulls",
  "scrub-win", "scrub-head", "endcard", "ec-headline", "ec-wincond", "ec-how",
  "ec-teams", "status", "lockerroom", "lk-art", "lk-bg", "lk-sprites", "lk-cap"]

const LanternIds = ["heartbar", "hidebug", "actchip", "intermission", "burst"]

suite "the chrome":
  test "every inherited paintbot id survived the fork":
    var missing: seq[string]
    for id in InheritedIds:
      if ("id=\"" & id & "\"") notin page:
        missing.add(id)
    if missing.len > 0:
      echo "missing ids: ", missing.join(", ")
    check missing.len == 0

  test "the five lantern additions are there":
    for id in LanternIds:
      check ("id=\"" & id & "\"") in page

  test "the relayout loop and its custom properties are intact":
    for token in ["--hudscale", "--topband", "--band", "classList.toggle('tiny'",
                  "ResizeObserver", "BOARD_ASPECT"]:
      check token in page

  test "the 360 px rules the playbook gotcha table requires are present":
    check ".plate-name { flex: 1 1 auto; min-width: 3.2em;" in page
    check "@media (max-width: 640px)" in page
    check "font-size: clamp(11px, 3.4vw, 17px)" in page

  test "DOM text is set with textContent, never innerHTML, for player data":
    ## Names are player-controlled data. The only innerHTML in the page builds
    ## the fixed plate skeleton, which contains no data.
    for line in page.splitLines():
      if "innerHTML" in line:
        check "plate-chip" in line or "textContent = ''" in line

suite "the static replay shell":
  test "the coworld-replay bridge is present, INCLUDING tell('ready')":
    ## SPEC's definition of done greps the served JS for exactly this.
    check "coworld-replay" in shell
    check "tell('loading')" in shell
    check "tell('ready')" in shell
    check "tell('error'" in shell
    check "window.parent.postMessage(envelope" in shell

  test "the phase marks and the gzip sniff are in the served JS":
    ## The Worker posts `phase` marks (bundle_ready, replay_fetch_start,
    ## replay_fetch_end with bytes + compressed, replay_parsed) and the shell
    ## relays them to the embedder; the host stamps them on its own clock.
    ## The public replay copy is gzip (manifest replay_compression), so the
    ## Worker sniffs the magic bytes and inflates before the wasm loader.
    check "tell('phase'" in shell
    check "location.hash" in shell
    for token in ["bundle_ready", "replay_fetch_start", "replay_fetch_end",
                  "replay_parsed", "0x1f", "0x8b", "0x78",
                  "DecompressionStream(format)", "_lt_load_replay"]:
      check token in worker
    check worker.find("replay_fetch_end") < worker.find("await inflate(")

  test "the inherited worker-shell contract is intact":
    for token in ["createCore", "data-replay-loaded", "data-replay-mismatch-tick",
                  "showFailure", "transferControlToOffscreen", "attachMinimap",
                  "getPaceStats", "setViewportFit"]:
      check token in shell
    for token in ["_lt_load_replay", "_lt_frame", "_lt_seek", "_lt_mismatch_tick",
                  "onAbort", "importScripts"]:
      check token in worker

  test "the worker INSTANTIATES the MODULARIZE=1 glue after importing it":
    ## config.nims builds lantern_replay.js with -s MODULARIZE=1, which only
    ## defines the factory. Paintbot's bootstrap (set self.Module, wait for
    ## onRuntimeInitialized) never fires under it, and the symptom is a page
    ## that says "loading replay" forever with no error.
    check "MODULARIZE=1" in readRepoFile("replay-viewer/config.nims")
    check "EXPORT_NAME=LanternReplayModule" in readRepoFile("replay-viewer/config.nims")
    check "self.LanternReplayModule(Module)" in worker
    check worker.find("bootRuntime();") > worker.find("importScripts(")

  test "the wasm runtime is on a watchdog, not left to hang":
    ## Instantiating the runtime is the one step with no failure path of its
    ## own: nothing raises when onRuntimeInitialized simply never fires, so
    ## without a bound the page shows its spinner until the tab dies. The
    ## worker posts the ordinary error envelope; static_replay.js turns that
    ## into data-replay-error and a coworld-replay `error` to the embedder.
    check "RUNTIME_TIMEOUT_MS = 30000" in worker
    check "did not initialize" in worker
    check "clearTimeout(runtimeTimer)" in worker
    check "data-replay-error" in shell
    check "data-replay-loaded" in shell

  test "the fetch is bounded and offers a retry":
    check "AbortController" in worker
    check "FETCH_TIMEOUT_MS" in worker
    check "Retry" in shell

  test "the fleet-wide 1/2x speed is on every copy of the speeds list":
    ## The speed chips send the 1-BASED INDEX into the speeds list down the
    ## command channel, so all three copies must agree: the generated wire
    ## constants, the chrome's raw file:// fallback and the worker's own
    ## literal.
    check "speeds: [0.5, " in readRepoFile("tools/gen_wire_constants.nim")
    check "[0.5, 1, 2, 3, 4, 8, 16]" in chrome
    check "[0.5, 1, 2, 3, 4, 8, 16]" in worker
    ## The fractional pace lives in the worker's tick carry; the old
    ## max(1, round(frames * speed)) floored 0.5x straight back to 1x.
    check "play.carry" in worker
    check "Math.max(1," notin worker

  test "Space pauses playback on the shipped page, end to end":
    ## index.html is client/replay_broadcast.html spliced: its window keydown
    ## sends ' ' down the command channel, and the worker toggles pause.
    check "' ': ' '" in page
    check "if (text === ' ') play.paused = !play.paused" in worker

  test "chrome_common exposes the factory the page instantiates":
    check "window.ChromeCommon = function (ctx)" in chrome
    check "renderTransport" in chrome
    check "renderClock" in chrome
    check "renderMomentum" in chrome
    check "getSpoilers" in chrome

suite "the wasm harness":
  test "the node harness runs when the bundle has been built":
    let dist = repoRoot() / "replay-viewer" / "dist"
    if not fileExists(dist / "lantern_replay.js"):
      echo "  skipped: no replay-viewer/dist (built by the wasm-viewer CI job,",
        " which runs tools/wasm_replay_smoke.cjs itself)"
      skip()
    else:
      let (output, code) = execCmdEx("node " &
        quoteShell(repoRoot() / "tools" / "wasm_replay_smoke.cjs") & " " &
        quoteShell(dist))
      echo output
      check code == 0

  test "the fixture the harness feeds it is a real, re-derivable replay":
    let fixture = parseJson(readRepoFile("tests/fixtures/smoke_replay.json"))
    check fixture["protocol"].getStr() == "lantern.replay.v1"
    check fixture["tick_count"].getInt() > 0
    check rederive(fixture).ok

  test "the build hook is executable and named correctly":
    let hook = repoRoot() / "tools" / "build_replay_viewer.sh"
    check fileExists(hook)
    ## `coworld build` hard-requires os.X_OK on this file.
    check fpUserExec in getFilePermissions(hook)
    let text = readFile(hook)
    check "static-replay-viewer" in text
    check "coworld-replay" in text
    let smoke = repoRoot() / "tools" / "ci" / "docker_smoke.sh"
    check fpUserExec in getFilePermissions(smoke)
