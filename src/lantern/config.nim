## GameConfig lifecycle: the defaults, the runtime JSON overlay, and the
## resolved config that gets pinned into every replay.
##
## Timing knobs arrive from the platform in SECONDS (they are what the
## manifest's `config_schema` declares) and are carried internally in
## MILLISECONDS as integers, so that no float ever reaches the sim path.

import std/[json, math, strutils]
import types

proc defaultGameConfig*(): GameConfig =
  GameConfig(
    numAgents: Seats,
    seed: 0,
    prepTicks: 720,           ## 30 s of lights-on fort building
    huntTicks: 1800,          ## 75 s of darkness
    turnTicks: 120,           ## one order every 5 s
    halves: 2,
    turnBudgetMs: 13_000,
    wallClockBudgetMs: 660_000,
    playerConnectTimeoutMs: 90_000,
    attempt1Ms: 8_500,
    attempt2Ms: 3_500,
    lanternRangePx: 420,
    lanternConeBrads: 18,
    visionBubblePx: 60,
    crateCount: 10,
    lockTicks: 24,
    pryTicks: 72,
    lockOnTicks: 12,
    maxLocksPerHider: 3,
    mapPath: "vault",
    showPlayerLabels: true,
    gameOverTicks: 96,
    episodeTimeoutMs: 1_200_000,
    model: "claude-sonnet-5",
    maxOutputTokens: 900
  )

proc millisOf(node: JsonNode): int =
  ## Seconds (int or float) -> whole milliseconds.
  case node.kind
  of JInt: node.getInt() * 1000
  of JFloat: int(round(node.getFloat() * 1000.0))
  of JString:
    try: int(round(parseFloat(node.getStr()) * 1000.0))
    except ValueError: 0
  else: 0

proc intField(node: JsonNode, key: string, current: int): int =
  if node.hasKey(key): node[key].getInt() else: current

proc update*(config: var GameConfig, configJson: string) =
  ## Applies the platform's runtime JSON config on top of the defaults.
  if configJson.strip().len == 0:
    return
  let node = parseJson(configJson)
  if node.kind != JObject:
    raise newException(LanternError, "config must be a JSON object")
  if node.hasKey("tokens"):
    config.tokens = @[]
    for token in node["tokens"]:
      config.tokens.add(token.getStr())
  if node.hasKey("players"):
    config.players = @[]
    for player in node["players"]:
      config.players.add(PlayerConfig(name: player{"name"}.getStr(), team: -1))
  if node.hasKey("slots"):
    ## An optional team pin. Seat -> team is fixed by slot parity in lantern
    ## (even = Moth, odd = Owl), so a pin that agrees is recorded and a pin
    ## that disagrees is refused rather than silently reinterpreted.
    for index, slot in node["slots"].getElems():
      let want = slot{"team"}.getStr().toLowerAscii()
      if want.len == 0:
        continue
      let parity = if (index and 1) == 0: "moth" else: "owl"
      if want != parity:
        raise newException(LanternError,
          "slots[" & $index & "] pins team " & want & " but lantern seats " &
          parity & " at that slot (even slots are Moth, odd are Owl)")
      if index < config.players.len:
        config.players[index].team = (if want == "moth": 0 else: 1)
  config.seed = intField(node, "seed", config.seed)
  config.numAgents = intField(node, "num_agents", config.numAgents)
  config.prepTicks = intField(node, "prepTicks", config.prepTicks)
  config.huntTicks = intField(node, "huntTicks", config.huntTicks)
  config.turnTicks = intField(node, "turnTicks", config.turnTicks)
  config.halves = intField(node, "halves", config.halves)
  config.lanternRangePx = intField(node, "lanternRangePx", config.lanternRangePx)
  config.lanternConeBrads =
    intField(node, "lanternConeBrads", config.lanternConeBrads)
  config.visionBubblePx = intField(node, "visionBubblePx", config.visionBubblePx)
  config.crateCount = intField(node, "crateCount", config.crateCount)
  config.lockTicks = intField(node, "lockTicks", config.lockTicks)
  config.pryTicks = intField(node, "pryTicks", config.pryTicks)
  config.lockOnTicks = intField(node, "lockOnTicks", config.lockOnTicks)
  config.maxLocksPerHider =
    intField(node, "maxLocksPerHider", config.maxLocksPerHider)
  config.gameOverTicks = intField(node, "gameOverTicks", config.gameOverTicks)
  config.maxOutputTokens = intField(node, "maxOutputTokens", config.maxOutputTokens)
  if node.hasKey("mapPath"):
    config.mapPath = node["mapPath"].getStr()
  if node.hasKey("model"):
    config.model = node["model"].getStr()
  if node.hasKey("showPlayerLabels"):
    config.showPlayerLabels = node["showPlayerLabels"].getBool()
  if node.hasKey("turnBudgetSeconds"):
    config.turnBudgetMs = millisOf(node["turnBudgetSeconds"])
  if node.hasKey("wallClockBudgetSeconds"):
    config.wallClockBudgetMs = millisOf(node["wallClockBudgetSeconds"])
  for key in ["playerConnectTimeoutSeconds", "player_connect_timeout_seconds"]:
    if node.hasKey(key):
      config.playerConnectTimeoutMs = millisOf(node[key])
  if node.hasKey("episodeTimeoutSeconds"):
    config.episodeTimeoutMs = millisOf(node["episodeTimeoutSeconds"])

  if config.numAgents != Seats:
    raise newException(LanternError,
      "lantern seats exactly " & $Seats & " cogs (2 teams x 3); got " &
      $config.numAgents)
  if config.halves != 2:
    raise newException(LanternError, "lantern plays exactly two halves")
  if config.turnTicks <= 0 or config.prepTicks mod config.turnTicks != 0 or
      config.huntTicks mod config.turnTicks != 0:
    raise newException(LanternError,
      "prepTicks and huntTicks must be whole multiples of turnTicks so a " &
      "decision turn never straddles an act boundary")
  if config.crateCount < 1:
    raise newException(LanternError, "crateCount must be at least 1")
  while config.players.len < config.numAgents:
    config.players.add(PlayerConfig(name: "P" & $(config.players.len + 1),
                                    team: -1))
  while config.tokens.len < config.numAgents:
    config.tokens.add("token-" & $config.tokens.len)

proc configJson*(config: GameConfig): JsonNode =
  ## The fully resolved config, tokens excluded, as pinned into the replay.
  var players = newJArray()
  for player in config.players:
    players.add(%*{"name": player.name})
  %*{
    "num_agents": config.numAgents,
    "seed": config.seed,
    "prepTicks": config.prepTicks,
    "huntTicks": config.huntTicks,
    "turnTicks": config.turnTicks,
    "halves": config.halves,
    "turnBudgetSeconds": config.turnBudgetMs.float / 1000.0,
    "wallClockBudgetSeconds": config.wallClockBudgetMs.float / 1000.0,
    "playerConnectTimeoutSeconds": config.playerConnectTimeoutMs.float / 1000.0,
    "lanternRangePx": config.lanternRangePx,
    "lanternConeBrads": config.lanternConeBrads,
    "visionBubblePx": config.visionBubblePx,
    "crateCount": config.crateCount,
    "lockTicks": config.lockTicks,
    "pryTicks": config.pryTicks,
    "lockOnTicks": config.lockOnTicks,
    "maxLocksPerHider": config.maxLocksPerHider,
    "mapPath": config.mapPath,
    "showPlayerLabels": config.showPlayerLabels,
    "gameOverTicks": config.gameOverTicks,
    "players": players
  }

proc configFromJson*(node: JsonNode): GameConfig =
  ## Rebuild a config from a replay's pinned `config` block. Used by the
  ## replay server and by the wasm viewer, which must re-derive the episode
  ## with exactly the rules that produced it.
  result = defaultGameConfig()
  result.update($node)
