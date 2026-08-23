## Lantern entrypoint. Reads the Coworld runtime contract and starts either a
## live episode server or the local replay viewer server.
##
## SEED RANDOMISATION HAPPENS HERE, BEFORE `config.update`, so every
## seed-derived draw (the sound-ring jitter, the moth baseline's waypoints)
## follows the FINAL seed. A pinned seed in the runtime config always wins;
## an unpinned one is randomised and the unpinned field is stripped so it
## cannot clobber the injected value.

import std/[json, os, strutils, sysrand]
import bitworld/runtime
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

  var runtimeConfig: RuntimeConfig
  try:
    runtimeConfig = readRuntimeConfig()
  except CatchableError as error:
    die("bad runtime configuration: " & error.msg.splitLines()[0])

  if runtimeConfig.replayMode:
    runReplayServer(runtimeConfig)
  else:
    if runtimeConfig.config.strip().len == 0:
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
      die("invalid episode config: " & error.msg.splitLines()[0])
    if randomised:
      echo "lantern: seed not pinned; randomised to ", config.seed
    echo "lantern: seats=", config.numAgents,
      " seed=", config.seed,
      " map=", config.mapPath,
      " ticks=", config.halves * (config.prepTicks + config.huntTicks),
      " turnTicks=", config.turnTicks,
      " wallClockBudget=", config.wallClockBudgetMs div 1000, "s"
    try:
      runGameServer(config, runtimeConfig)
    except LanternError as error:
      die(error.msg.splitLines()[0])
