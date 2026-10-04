## Lantern entrypoint. Reads the Coworld runtime contract and starts either a
## live episode server or the local replay viewer server.
##
## SEED RANDOMISATION HAPPENS HERE, BEFORE `config.update`, so every
## seed-derived draw (the sound-ring jitter, the moth baseline's waypoints)
## follows the FINAL seed. A pinned seed in the runtime config always wins;
## an unpinned one is randomised and the unpinned field is stripped so it
## cannot clobber the injected value.

import std/[json, math, monotimes, os, strutils, sysrand, times]
import bitworld/[runtime, runtime_input, native_http, native_stop, decision_trajectory]
import lantern/[types, config, server]

const Usage = """
lantern - 3v3 hide-and-seek in the dark, for the Softmax Coworld platform.

  /bin/lantern            run a game (or replay) server
  /bin/lantern --help     this message

Configuration comes from the Coworld runtime contract:
  COGAME_CONFIG_URI        the episode config (REQUIRED)
  COGAME_RESULTS_URI       where results.json is written
  COGAME_SAVE_REPLAY_URI   where the lantern.replay.v1 JSON is written
  COGAME_LOAD_REPLAY_URI   a replay to serve instead of playing
  COGAME_PLAYER_FAILURE_URI  where a never-connecting seat is reported
  COGAME_EVENTS_URI / COGAME_METRICS_URI  file:// only, or startup fails
  COGAME_HOST / COGAME_PORT  bind address (default 0.0.0.0:8080)
"""

proc randomSeed(): int =
  var buf: array[4, byte]
  if not urandom(buf):
    raise newException(LanternError, "OS entropy source unavailable")
  (int(buf[0]) shl 24 or int(buf[1]) shl 16 or
    int(buf[2]) shl 8 or int(buf[3])) and 0x7FFF_FFFF

proc seedPinned(configJson: string): bool =
  if configJson.strip().len == 0:
    return false
  try:
    let node = parseJson(configJson)
    node.kind == JObject and node.hasKey("seed")
  except CatchableError:
    false        ## config.update reports the real parse error

proc die(message: string) =
  stderr.writeLine("lantern: " & message)
  quit(2)

when isMainModule:
  for argument in commandLineParams():
    if argument == "--help" or argument == "-h":
      echo Usage
      quit(0)

  installNativeStopHandlers()
  let processStarted = getMonoTime()
  var episodeDeadline = processStarted + initDuration(milliseconds = defaultGameConfig().episodeTimeoutMs)
  var inputControl: NativeRequestControl
  var inputCaptures: seq[RuntimeInputCapture]
  var runtimeConfig: RuntimeConfig
  try:
    let timeout = parseFloat(getEnv("COWORLD_TIMEOUT_SECONDS",
      $(defaultGameConfig().episodeTimeoutMs.float / 1000.0)))
    if classify(timeout) in {fcNan, fcInf, fcNegInf} or timeout <= 0:
      raise newException(LanternError, "episode timeout must be finite and positive")
    episodeDeadline = processStarted + initDuration(nanoseconds = int64(timeout * 1_000_000_000))
    let inputDeadline = min(episodeDeadline - initDuration(seconds = 5),
      processStarted + initDuration(seconds = 60))
    proc input(value, source: string): string =
      readRuntimeInput(value, source, inputDeadline, inputControl,
        16 * 1024 * 1024, 64 * 1024, inputCaptures)
    runtimeConfig = readRuntimeConfig(input)
  except CatchableError as error:
    let status = if interruptionRequested(): esTruncated else: esFailed
    writeInitializationCheckpoint(status, "runtime_config", $error.name, error.msg,
      episodeDeadline, runtimeInputCapturesJson(inputCaptures))
    if status == esTruncated: quit(0)
    die("bad runtime configuration (" & $error.name & ")")
  if interruptionRequested():
    writeInitializationCheckpoint(esTruncated, "runtime_config", "stop_requested",
      "process stop requested", episodeDeadline, runtimeInputCapturesJson(inputCaptures))
    quit(0)

  if runtimeConfig.replayMode:
    runReplayServer(runtimeConfig, episodeDeadline)
  else:
    if runtimeConfig.config.strip().len == 0:
      writeInitializationCheckpoint(esFailed, "game_config", "missing_config", "COGAME_CONFIG_URI is required",
        episodeDeadline, runtimeInputCapturesJson(inputCaptures))
      die("COGAME_CONFIG_URI is not set (or names an empty config); " &
        "lantern needs an episode config to know its seats. Try --help.")
    var config = defaultGameConfig()
    ## The randomised seed is injected BEFORE the overlay so a config that
    ## does not pin one still produces a fully seeded episode. The LOG LINE
    ## waits until the overlay has been accepted, so a bad config dies with
    ## exactly one line and nothing else.
    let randomised = not seedPinned(runtimeConfig.config)
    if randomised:
      config.seed = randomSeed()
    try:
      config.update(runtimeConfig.config)
    except CatchableError as error:
      writeInitializationCheckpoint(esFailed, "game_config", $error.name, error.msg,
        episodeDeadline, runtimeInputCapturesJson(inputCaptures))
      die("invalid episode config (" & $error.name & ")")
    if getEnv("COWORLD_TIMEOUT_SECONDS").len == 0:
      episodeDeadline = processStarted + initDuration(milliseconds = config.episodeTimeoutMs)
    if randomised:
      echo "lantern: seed not pinned; randomised to ", config.seed
    echo "lantern: seats=", config.numAgents,
      " seed=", config.seed,
      " map=", config.mapPath,
      " ticks=", config.halves * (config.prepTicks + config.huntTicks),
      " turnTicks=", config.turnTicks,
      " wallClockBudget=", config.wallClockBudgetMs div 1000, "s"
    try:
      runGameServer(config, runtimeConfig, episodeDeadline, runtimeInputCapturesJson(inputCaptures))
    except LanternError as error:
      writeInitializationCheckpoint(esFailed, "game_server", $error.name, error.msg,
        episodeDeadline, runtimeInputCapturesJson(inputCaptures))
      die("game server rejected (" & $error.name & ")")
