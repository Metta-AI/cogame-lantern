## The manifest is a contract with the platform, not documentation.
##
## `num_agents` missing from ONE variant schedules zero episodes; a
## `results_schema` that has drifted from what the server emits rejects the
## upload; `game.docs` in the wrong shape empties the coworld page. All three
## are silent failures at 3 a.m., so they are asserted here.

import std/[json, sequtils, sets, strutils, unittest]
import support/helpers

let manifest = parseJson(readRepoFile("coworld_manifest_template.json"))
let game = manifest["game"]

suite "seats":
  test "num_agents is 6 in EVERY variant":
    check manifest["variants"].len >= 2
    for variant in manifest["variants"]:
      check variant["game_config"]["num_agents"].getInt() == Seats
      check variant["game_config"]["players"].len == Seats
      check variant["game_config"]["slots"].len == Seats

  test "num_agents is 6 in the certification fixture too":
    let cert = manifest["certification"]
    check cert["game_config"]["num_agents"].getInt() == Seats
    check cert["players"].len == Seats
    check cert["game_config"]["players"].len == Seats
    check cert["game_config"]["seed"].getInt() == 42
    check cert["game_config"]["prepTicks"].getInt() +
      cert["game_config"]["huntTicks"].getInt() == 720          ## 1440 ticks
    for player in cert["players"]:
      check player["player_id"].getStr() == "baseline"

  test "the slot pins agree with lantern's fixed parity":
    for variant in manifest["variants"]:
      for index, slot in variant["game_config"]["slots"].getElems():
        let want = (if index mod 2 == 0: "moth" else: "owl")
        check slot["team"].getStr() == want

  test "SMOKE_SEATS in the smoke script agrees with the fixture":
    let script = readRepoFile("tools/ci/docker_smoke.sh")
    check "SMOKE_SEATS:-" & $Seats in script
    check "${SMOKE_GAME_BIN:-/bin/${slug}}" in script

suite "the results schema":
  test "its keys are exactly the keys the server emits":
    let sim = testSim(prep = 240, hunt = 480)
    discard runScriptedEpisode(sim, allWarden())
    let emitted = sim.scriptedResults()
    var fromServer: HashSet[string]
    for key, _ in emitted:
      fromServer.incl(key)
    var fromManifest: HashSet[string]
    for key, _ in game["results_schema"]["properties"]:
      fromManifest.incl(key)
    check fromServer == fromManifest
    var required: HashSet[string]
    for key in game["results_schema"]["required"]:
      required.incl(key.getStr())
    check required == fromManifest

  test "reason and end_rule are closed enums":
    let properties = game["results_schema"]["properties"]
    var reasons: seq[string]
    for value in properties["reason"]["enum"]:
      reasons.add(value.getStr())
    check reasons == @["complete", "deadline", "fault"]
    var rules: seq[string]
    for value in properties["end_rule"]["enum"]:
      rules.add(value.getStr())
    check rules == @["full_time", "wall_clock", "sim_fault", "host_error"]

suite "the platform contract":
  test "the replay viewer is the static bundle, never a pod":
    check game["replay_viewer"]["bundle"].getStr() == "static-replay-viewer"
    ## The public replay copy is gzip; the Worker sniffs and inflates it.
    check game["replay_viewer"]["replay_compression"].getStr() == "gzip"

  test "episode_timeout_minutes is 20, and TOP-LEVEL where the schema puts it":
    ## CoworldGameManifest has additionalProperties: false, so this key under
    ## `game` is not merely ignored - it rejects the whole manifest at
    ## `coworld build`.
    check manifest["episode_timeout_minutes"].getInt() == 20
    check not game.hasKey("episode_timeout_minutes")
    let budget = 20 * 60 * 6 div 10          ## 720 s
    for variant in manifest["variants"]:
      check variant["game_config"]["wallClockBudgetSeconds"].getFloat() <=
        budget.float
    check manifest["certification"]["game_config"][
      "wallClockBudgetSeconds"].getFloat() <= budget.float

  test "protocols carry BOTH player and global, as inline text":
    let protocols = game["protocols"]
    check protocols.hasKey("player")
    check protocols.hasKey("global")
    for key in ["player", "global"]:
      check protocols[key]["type"].getStr() == "text"
      check protocols[key]["value"].getStr().len > 400

  test "docs are a readme plus two non-empty text pages":
    let docs = game["docs"]
    check docs["readme"]["type"].getStr() == "text"
    check docs["readme"]["value"].getStr().len > 500
    check docs["pages"].len == 2
    var ids: seq[string]
    for page in docs["pages"]:
      ids.add(page["id"].getStr())
      check page["title"].getStr().len > 0
      check page["content"]["type"].getStr() == "text"
      check page["content"]["value"].getStr().len > 500
    check ids == @["rules.md", "protocol.md"]

  test "the image placeholders and entrypoints line up with compose.yaml":
    ## `coworld build` derives the placeholder from the COMPOSE SERVICE NAME
    ## (`_compose_image_placeholders`: service `lantern` -> {{LANTERN_IMAGE}}),
    ## and rejects the whole build with "Coworld image placeholder does not
    ## match a Compose service" for anything else. Derive it here the same
    ## way rather than hard-coding it twice.
    let composeText = readRepoFile("compose.yaml")
    var service = ""
    for line in composeText.splitLines():
      if line.startsWith("  ") and line.strip().endsWith(":") and
          not line.startsWith("    "):
        service = line.strip().strip(chars = {':'})
        break
    check service == "lantern"
    let placeholder = "{{" & service.toUpperAscii().replace("-", "_") &
      "_IMAGE}}"
    check game["runnable"]["image"].getStr() == placeholder
    check game["runnable"]["run"][0].getStr() == "/bin/lantern"
    check manifest["player"][0]["image"].getStr() == placeholder
    check manifest["player"][0]["run"][0].getStr() == "/bin/lantern-player"
    check manifest["player"][0]["env"]["PLAYER_SCRIPTED"].getStr() == "warden"
    check "image: coworld-lantern:latest" in composeText
    check "platform: linux/amd64" in composeText
    check "network: host" in composeText
    check "coworld-lantern" in readRepoFile(".github/workflows/ci.yml")

  test "config_schema declares num_agents and every knob the server reads":
    let properties = game["config_schema"]["properties"]
    for key in ["tokens", "players", "slots", "seed", "num_agents",
                "prepTicks", "huntTicks", "turnTicks", "halves",
                "turnBudgetSeconds", "wallClockBudgetSeconds",
                "playerConnectTimeoutSeconds", "lanternRangePx",
                "lanternConeBrads", "visionBubblePx", "crateCount",
                "lockTicks", "pryTicks", "lockOnTicks", "maxLocksPerHider",
                "mapPath", "showPlayerLabels", "gameOverTicks",
                "shutdownGraceSeconds"]:
      check properties.hasKey(key)
    check properties["num_agents"]["default"].getInt() == Seats

  test "every certification and variant config actually loads":
    for node in @[manifest["certification"]["game_config"]] &
        manifest["variants"].getElems().mapIt(it["game_config"]):
      var config = defaultGameConfig()
      config.update($node)
      check config.numAgents == Seats
      check totalTicks(config) mod config.turnTicks == 0

suite "the policy set":
  let policies = parseJson(readRepoFile("tools/ci/policies.json"))

  test "two LLM champions and two scripted fillers, one image, env-switched":
    check policies.len == 4
    var names: seq[string]
    var prompts = 0
    var scripts = 0
    for policy in policies:
      names.add(policy["name"].getStr())
      check policy["run"].getStr() == "/bin/lantern-player"
      if policy["env"].hasKey("PLAYER_PROMPT"):
        inc prompts
        check policy["env"]["PLAYER_PROMPT"].getStr().len > 400
      if policy["env"].hasKey("PLAYER_SCRIPTED"):
        inc scripts
        check policy["env"]["PLAYER_SCRIPTED"].getStr() in ["warden", "moth"]
    check names == @["lantern-warren", "lantern-owlnight", "lantern-warden",
                     "lantern-moth"]
    check prompts == 2
    check scripts == 2

  test "champion #2 is uploaded as daveey-1, and the prompts differ":
    check policies[1]["player"].getStr() ==
      "ply_bac48eb1-662e-44f8-973d-f3e016dccf5d"
    check not policies[0].hasKey("player")
    ## Identical content dedupes to the same version, so the two champions
    ## MUST differ or the ladder has one player twice.
    check policies[0]["env"]["PLAYER_PROMPT"].getStr() !=
      policies[1]["env"]["PLAYER_PROMPT"].getStr()
