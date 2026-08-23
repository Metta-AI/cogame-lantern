import json
import os
import re

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def read(name):
    with open(os.path.join(ROOT, name), encoding="utf-8") as fh:
        return fh.read()


SEATS = 6
SOURCE = "https://github.com/Metta-AI/cogame-lantern/tree/main"

CHAMPION_ONE = read("docs/prompts/lantern-warren.txt").strip()
CHAMPION_TWO = read("docs/prompts/lantern-owlnight.txt").strip()

DESCRIPTION = (
    "Lantern: 3v3 hide-and-seek in the dark on a warehouse floor, played twice "
    "with the sides swapped. Six cogs share a walled 1235x659 px floor lit only "
    "by the seekers' flashlights. In each half one trio - the hiders - gets a "
    "30-second lights-on build act to shove and bolt 48x48 wooden crates into a "
    "fort; then the lights go out, the seekers' pen door opens, and the seekers "
    "get 75 seconds to sweep the dark. A seeker's lit set is a 420 px, 50-degree "
    "beam plus a 60 px bubble, occluded by walls and by every crate that is still "
    "standing, and the three seekers share one radio. Held in a beam for half a "
    "second, or touched, and a hider is found. A locked crate cannot be shoved by "
    "anyone - only a 3-second, very loud pry breaks it - so the fort is a real "
    "asset and breaching it is a real decision. A hider scores one tick per tick "
    "it is not yet found; then the sides swap, the map resets to its exact "
    "starting layout, and the halves are compared: score(Moth) = 0.5 + 0.5 * "
    "(f(Moth) - f(Owl)), exactly zero-sum between the sides. The game is "
    "LLM-driven: every five seconds the server sends each seat's policy prompt "
    "plus that seat's view (its role, its clock, what it can actually see, the "
    "sounds it can hear and - for a seeker - its five-band proximity heartbeat) "
    "to Claude as ONE PARALLEL BATCH, and a deterministic control layer executes "
    "the returned order at 24 Hz. A POLICY IS JUST A PROMPT - build one by "
    "reusing the published player runnable and setting the PLAYER_PROMPT "
    "environment variable to your strategy. Two scripted baselines (warden and "
    "moth) play any seat that registers as scripted, and every seat when no LLM "
    "credentials are available, so episodes always complete. In-game a cog is "
    "only ever Moth-1..Owl-3; real player names appear spectator-side only."
)

CONFIG_PROPERTIES = {
    "tokens": {
        "description": "One connection token per player slot, indexed by slot.",
        "type": "array", "minItems": SEATS, "maxItems": SEATS,
        "items": {"type": "string", "minLength": 1},
    },
    "players": {
        "description": "One player display-name object per seat, indexed by slot.",
        "type": "array", "minItems": SEATS, "maxItems": SEATS,
        "items": {
            "type": "object", "additionalProperties": False,
            "required": ["name"],
            "properties": {"name": {"type": "string", "minLength": 1}},
        },
    },
    "slots": {
        "description": (
            "Optional team pin, indexed by slot. Seat to team is fixed in "
            "lantern (even slots are Moth, odd slots are Owl); a pin that "
            "disagrees is refused rather than reinterpreted."
        ),
        "type": "array", "minItems": SEATS, "maxItems": SEATS,
        "items": {
            "type": "object", "additionalProperties": False,
            "properties": {"team": {"type": "string", "enum": ["moth", "owl"]}},
        },
    },
    "num_agents": {
        "description": "Seats in the episode. Lantern is 2 teams x 3 cogs.",
        "type": "integer", "minimum": SEATS, "maximum": SEATS, "default": SEATS,
    },
    "seed": {
        "description": (
            "Episode seed. Unpinned it is randomised at startup, before the "
            "config overlay, so every seed-derived draw follows the final seed."
        ),
        "type": "integer", "minimum": 0,
    },
    "prepTicks": {
        "description": "Ticks in each half's lights-on build act (24 ticks = 1 s). Must be a whole multiple of turnTicks.",
        "type": "integer", "minimum": 120, "maximum": 2880, "default": 720,
    },
    "huntTicks": {
        "description": "Ticks in each half's hunt act. Must be a whole multiple of turnTicks.",
        "type": "integer", "minimum": 240, "maximum": 7200, "default": 1800,
    },
    "turnTicks": {
        "description": "Ticks between decision turns. 120 = one order every 5 s.",
        "type": "integer", "minimum": 24, "maximum": 600, "default": 120,
    },
    "halves": {
        "description": "Halves played. Lantern always plays exactly two, so the two sides are compared on identical geometry.",
        "type": "integer", "minimum": 2, "maximum": 2, "default": 2,
    },
    "turnBudgetSeconds": {
        "description": "Outer wall-clock budget for one decision turn, covering both LLM attempts.",
        "type": "number", "minimum": 1, "maximum": 60, "default": 13,
    },
    "wallClockBudgetSeconds": {
        "description": (
            "Hard engine stop. Must stay inside 60 percent of the platform's "
            "episode timeout; the budget guard settles the match on the "
            "scripted layer well before this fires."
        ),
        "type": "number", "minimum": 30, "maximum": 700, "default": 660,
    },
    "playerConnectTimeoutSeconds": {
        "description": "Bounded wait for the seats to connect before the match starts anyway.",
        "type": "number", "minimum": 5, "maximum": 300, "default": 90,
    },
    "lanternRangePx": {
        "description": "Flashlight range in map pixels.",
        "type": "integer", "minimum": 60, "maximum": 1200, "default": 420,
    },
    "lanternConeBrads": {
        "description": "Half-angle of the beam in brads (256 per turn). 18 is a 50.6-degree beam.",
        "type": "integer", "minimum": 2, "maximum": 128, "default": 18,
    },
    "visionBubblePx": {
        "description": "Omnidirectional sight bubble around a seeker.",
        "type": "integer", "minimum": 0, "maximum": 400, "default": 60,
    },
    "crateCount": {
        "description": "Crates placed from the map file, in order.",
        "type": "integer", "minimum": 1, "maximum": 10, "default": 10,
    },
    "lockTicks": {
        "description": "Ticks a hider must hold still to bolt a crate down.",
        "type": "integer", "minimum": 1, "maximum": 240, "default": 24,
    },
    "pryTicks": {
        "description": "Ticks a seeker must hold still to breach a locked crate.",
        "type": "integer", "minimum": 1, "maximum": 480, "default": 72,
    },
    "lockOnTicks": {
        "description": "Consecutive lit ticks that turn a spot into a find.",
        "type": "integer", "minimum": 1, "maximum": 240, "default": 12,
    },
    "maxLocksPerHider": {
        "description": "Locks each hider may spend per half.",
        "type": "integer", "minimum": 0, "maximum": 10, "default": 3,
    },
    "mapPath": {
        "description": "The authored map to load from data/. Lantern ships one: vault.",
        "type": "string", "default": "vault",
    },
    "showPlayerLabels": {
        "description": "Spectator-side only: show real player names on the scorebug plates.",
        "type": "boolean", "default": True,
    },
    "gameOverTicks": {
        "description": "Ticks the viewer holds on the endcard after the final tick.",
        "type": "integer", "minimum": 0, "maximum": 600, "default": 96,
    },
    "episodeTimeoutSeconds": {
        "description": "Assumed platform kill time when the env is silent. Lantern plays inside 60 percent of it.",
        "type": "number", "minimum": 60, "maximum": 3600, "default": 1200,
    },
    "model": {
        "description": "Anthropic model id for the direct API transport (the hosted Bedrock sidecar picks its own).",
        "type": "string", "default": "claude-sonnet-5",
    },
    "maxOutputTokens": {
        "description": "max_tokens for one order. 400 truncates the JSON; 900 does not.",
        "type": "integer", "minimum": 200, "maximum": 4000, "default": 900,
    },
}


def seat_array(description, item, minimum=SEATS):
    return {"description": description, "type": "array",
            "minItems": minimum, "maxItems": SEATS, "items": item}


NUMBER = {"type": "number"}
INTEGER = {"type": "integer"}
STRING = {"type": "string"}
BOOLEAN = {"type": "boolean"}

RESULTS_PROPERTIES = {
    "names": seat_array("Real policy display names, indexed by slot. Spectator-side only: in-game a cog is Moth-1..Owl-3.", STRING),
    "aliases": seat_array("The in-game alias of each seat.", STRING),
    "teams": seat_array("Moth or Owl, by slot. Even slots are Moth, odd are Owl.", {"type": "string", "enum": ["Moth", "Owl"]}),
    "hid_in_half": seat_array("Which half this seat spent hiding (1 for Moth, 2 for Owl).", INTEGER),
    "policy_kinds": seat_array("llm or scripted, by slot.", {"type": "string", "enum": ["llm", "scripted"]}),
    "scores": seat_array("The seat's team score in [0, 1]. Higher is better; the two team scores sum to 1.", NUMBER),
    "win": seat_array("True when this seat's team scored above 0.5. All false on a draw.", BOOLEAN),
    "hidden_ticks": seat_array("Hunt ticks in this seat's hiding half during which it was unfound.", INTEGER),
    "hidden_seconds": seat_array("The same, in seconds.", NUMBER),
    "finds": seat_array("Hiders this seat found while seeking.", INTEGER),
    "crates_pushed": seat_array(
        "Crate shoves this seat contributed, counted at most once per "
        "crate per 12 ticks.", INTEGER),
    "crates_locked": seat_array("Crates this seat bolted down.", INTEGER),
    "crates_broken": seat_array("Locked crates this seat pried open.", INTEGER),
    "team_hidden_frac": {"description": "f(team) in [0, 1], index 0 = Moth, 1 = Owl.", "type": "array", "minItems": 2, "maxItems": 2, "items": NUMBER},
    "team_hidden_seconds": {"description": "Total seconds hidden per team, index 0 = Moth, 1 = Owl.", "type": "array", "minItems": 2, "maxItems": 2, "items": NUMBER},
    "reason": {"description": "Why the episode ended.", "type": "string", "enum": ["complete", "deadline", "fault"]},
    "end_rule": {"description": "The detail behind `reason`.", "type": "string", "enum": ["full_time", "wall_clock", "sim_fault", "host_error"]},
    "winner": {"description": "0 Moth, 1 Owl, null on a draw.", "type": ["integer", "null"]},
    "final_tick": {"description": "Ticks simulated.", "type": "integer"},
    "final_turn": {"description": "Decision turns played.", "type": "integer"},
    "halves_played": {"description": "Halves whose hunt act ran at all.", "type": "integer"},
    "hunt_ticks_played": {"description": "Hunt ticks actually simulated per half - the score denominator.", "type": "array", "minItems": 2, "maxItems": 2, "items": INTEGER},
    "seed": {"description": "The episode seed the replay re-derives from.", "type": "integer"},
    "llm_turns": seat_array("Turns this seat's order came from the LLM.", INTEGER),
    "fallback_turns": seat_array("Turns this seat fell back to the scripted order.", INTEGER),
    "fallback_causes": seat_array(
        "Per-seat fallback tally by cause.",
        {"type": "object", "additionalProperties": False,
         "required": ["timeout", "parse_error", "transport_error", "no_credentials", "budget_guard"],
         "properties": {name: INTEGER for name in
                        ["timeout", "parse_error", "transport_error", "no_credentials", "budget_guard"]}}),
}

PLAYER_PROTOCOL = read("docs/PROTOCOL.md")
RULES = read("docs/RULES.md")
README = read("README.md")

PROTOCOL_PLAYER_TEXT = (
    "lantern.player.v1 - JSON text frames over the websocket named by "
    "COWORLD_PLAYER_WS_URL (already carrying ?slot=N&token=T; a bad token 403s "
    "and a duplicate connection 409s). A lantern policy is a prompt and every "
    "decision is made in the GAME server, so the player container has exactly "
    "one job: on connect it sends ONE frame, "
    '{"type":"register","prompt":"<strategy text or empty>",'
    '"scripted":"warden"|"moth"|null,"policy":"<free label, <=48 runes>"}, and '
    "thereafter only receives. PLAYER_SCRIPTED=warden|1|true|yes selects the "
    "warden baseline, moth the weaker moth baseline; a seat that registers with "
    "neither field, or never registers at all, plays warden and the match still "
    "goes to full time. An over-long prompt is truncated at 4000 runes, never "
    "rejected. The server replies {\"type\":\"welcome\",\"protocol\":"
    "\"lantern.player.v1\",\"slot\":N,\"alias\":\"Moth-1\",\"team\":\"Moth\","
    "\"hides_in_half\":1,\"turns\":42}, then one informational frame per "
    "decision turn, {\"type\":\"turn\",\"turn\":T,\"tick\":K,\"half\":H,"
    "\"act\":\"build\"|\"hunt\",\"role\":\"hider\"|\"seeker\",\"view\":{...},"
    "\"order_source\":\"llm\"|\"scripted\"|\"fallback\"} - the seat is not "
    "required to answer it - and finally {\"done\":true,\"result\":{...the "
    "results document...}} before closing. The view is role-shaped: a hider "
    "sees the full static map, all ten crate positions and states, its own "
    "trio, seekers within 700 px with line of sight, the bearing and band of "
    "any beam within 220 px, and break-ring sounds; a seeker sees the static "
    "map, its own heartbeat band, only what the team's three lanterns light "
    "right now, its team-mates' bands, audible sound rings and the found list. "
    "Neither role ever sees the opponent's prompts, notes or say strings, the "
    "real player names behind the aliases, or the seed. The order the server "
    "asks Claude for is a single JSON object: "
    '{"intent":...,"target":[x,y],"crate":"C0".."C9"|null,'
    '"aim":"sweep|hold|track|target","crawl":bool,"note":"<=140 runes",'
    '"say":"<=32 runes"} - hider intents push/lock/hide/flee/scout/wait, seeker '
    "intents sweep/beeline/chase/pry/hold/wait. Parsing is tolerant (fences "
    "stripped, outermost balanced object taken, numeric strings and integer "
    "crate ids accepted) and every field is repaired rather than rejected; only "
    "an unrecoverable intent costs the one retry, and only a failed retry falls "
    "back to the warden order plus a fallback event. Every recorded string is "
    "truncated on RUNE boundaries, never bytes."
)

PROTOCOL_GLOBAL_TEXT = (
    "The spectator surface. GET /healthz answers {\"ok\":true}. WS /global "
    "streams a whole-world snapshot on connect and every few seconds after: "
    '{"type":"state","game":"lantern","tick","turn","turns","half","act",'
    '"act_left_ticks","map":{"w","h","walls","nooks","pen"},"cogs":[{"slot",'
    '"alias","team","role","pos","aim","crawl","found","hidden_ticks",'
    '"locks_used","heartbeat","intent","note","say","source"}],"crates":'
    '[{"id","pos","state"}],"sounds":[{"kind","pos","radius","age_ticks"}],'
    '"policyNames","colors","started","done","connected"}. Nothing is hidden '
    "from a spectator - that is the point of the second name space: the board "
    "labels cogs Moth-1..Owl-3 and the scorebug maps those back to real player "
    "names. mummy hands Ping frames to the application, so /global answers them "
    "with a Pong (the certifier pings to check the game is alive). HOSTED "
    "REPLAYS ARE NEVER A POD: the manifest declares "
    '"replay_viewer": {"bundle": "static-replay-viewer"}, and the bundle built '
    "by tools/build_replay_viewer.sh re-derives every frame in the browser from "
    "seed + map + controls_b64 with the same integer Nim sim the server ran, "
    "validating itself against the recorded keyframe digests and surfacing any "
    "divergence as data-replay-mismatch-tick. The bundle fetches nothing but "
    "the replay URL it was handed and posts {src:\"coworld-replay\",type:"
    "\"loading\"|\"ready\"|\"error\"} to its embedding page. The game server "
    "also serves /client/replay off the identical dist for local viewing, and "
    "/replay-data in replay mode. The replay bytes themselves are strict UTF-8 "
    "JSON with protocol \"lantern.replay.v1\": config, the map inlined "
    "verbatim, names/aliases/teams/policy_kinds/colors, the phase table, "
    "controls_b64 (tick_count x 6 x 4 bytes), a keyframe every 24 ticks with an "
    "FNV-1a state digest, the full event stream and the results document."
)

manifest = {
    "$schema": "https://raw.githubusercontent.com/Metta-AI/coworld/main/src/coworld/coworld_manifest_schema.json",
    # episode_timeout_minutes is a TOP-LEVEL key in the coworld manifest
    # schema (game.additionalProperties is false), and it bounds hosted
    # certification runs as well as league episodes.
    "episode_timeout_minutes": 20,
    "tags": ["hide-and-seek", "asymmetric-teams", "construction", "physics",
             "real-time", "fog-of-war", "llm-driven", "six-player",
             "zero-sum", "tool-use"],
    "game": {
        "name": "lantern",
        "replay_viewer": {"bundle": "static-replay-viewer"},
        "description": DESCRIPTION,
        "owner": "daveey@softmax.com",
        "runnable": {
            "type": "game",
            "image": "{{GAME_IMAGE}}",
            "run": ["/bin/lantern"],
            "env": {"ANTHROPIC_API_KEY_URI": "secret://coworld/lantern/anthropic_api_key"},
            "source_url": SOURCE,
        },
        "config_schema": {
            "$schema": "https://json-schema.org/draft/2020-12/schema",
            "type": "object",
            "additionalProperties": False,
            "required": ["tokens", "players"],
            "properties": CONFIG_PROPERTIES,
        },
        "results_schema": {
            "$schema": "https://json-schema.org/draft/2020-12/schema",
            "type": "object",
            "additionalProperties": False,
            "required": sorted(RESULTS_PROPERTIES.keys()),
            "properties": RESULTS_PROPERTIES,
        },
        "protocols": {
            "player": {"type": "text", "value": PROTOCOL_PLAYER_TEXT},
            "global": {"type": "text", "value": PROTOCOL_GLOBAL_TEXT},
        },
        "docs": {
            "readme": {"type": "text", "value": README},
            "pages": [
                {"id": "rules.md", "title": "Rules",
                 "content": {"type": "text", "value": RULES}},
                {"id": "protocol.md", "title": "Wire protocol",
                 "content": {"type": "text", "value": PLAYER_PROTOCOL}},
            ],
        },
    },
    "player": [
        {
            "id": "baseline",
            "name": "warden",
            "type": "player",
            "description": (
                "The bundled certification player: registers as the warden "
                "scripted baseline and plays deterministically, with no LLM. "
                "Field your own policy by uploading this same image with "
                "PLAYER_PROMPT set to your strategy."
            ),
            "image": "{{PLAYER_IMAGE}}",
            "run": ["/bin/lantern-player"],
            "env": {"PLAYER_SCRIPTED": "warden"},
            "resources": {"requests": {"cpu": "100m", "memory": "64Mi"},
                          "limits": {"cpu": "1"}},
            "source_url": SOURCE,
        }
    ],
    "variants": [],
    "certification": {},
}

SLOT_PINS = [{"team": "moth" if index % 2 == 0 else "owl"} for index in range(SEATS)]


def variant(vid, name, description, prep, hunt, wall):
    return {
        "id": vid, "name": name, "description": description,
        "game_config": {
            "players": [{"name": f"P{index + 1}"} for index in range(SEATS)],
            "slots": list(SLOT_PINS),
            "num_agents": SEATS,
            "prepTicks": prep,
            "huntTicks": hunt,
            "turnTicks": 120,
            "halves": 2,
            "turnBudgetSeconds": 13,
            "wallClockBudgetSeconds": wall,
            "playerConnectTimeoutSeconds": 90,
            "mapPath": "vault",
        },
    }


manifest["variants"] = [
    variant("default", "Warehouse (2 teams x 3, two halves)",
            "The full match: a 30 s build act and a 75 s hunt in each half, "
            "5040 ticks, 42 decision turns.", 720, 1800, 660),
    variant("sprint", "Sprint (2 teams x 3, short halves)",
            "Cheap ladder rounds: a 20 s build act and a 45 s hunt in each "
            "half, 3120 ticks, 26 decision turns. Same six seats, same map, "
            "same rules - only the act lengths change.", 480, 1080, 400),
]

manifest["certification"] = {
    "game_config": {
        "players": [{"name": f"P{index + 1}"} for index in range(SEATS)],
        "slots": list(SLOT_PINS),
        "num_agents": SEATS,
        "seed": 42,
        "prepTicks": 240,
        "huntTicks": 480,
        "turnTicks": 120,
        "halves": 2,
        "turnBudgetSeconds": 13,
        "wallClockBudgetSeconds": 180,
        "playerConnectTimeoutSeconds": 60,
        "mapPath": "vault",
    },
    "players": [{"player_id": "baseline"} for _ in range(SEATS)],
}

out = os.path.join(ROOT, "coworld_manifest_template.json")
with open(out, "w", encoding="utf-8") as fh:
    json.dump(manifest, fh, indent=2, ensure_ascii=False)
    fh.write("\n")
print("wrote", out)

policies = [
    {"name": "lantern-warren", "run": "/bin/lantern-player",
     "env": {"PLAYER_PROMPT": CHAMPION_ONE}},
    {"name": "lantern-owlnight", "run": "/bin/lantern-player",
     "env": {"PLAYER_PROMPT": CHAMPION_TWO},
     "player": "ply_bac48eb1-662e-44f8-973d-f3e016dccf5d"},
    {"name": "lantern-warden", "run": "/bin/lantern-player",
     "env": {"PLAYER_SCRIPTED": "warden"}},
    {"name": "lantern-moth", "run": "/bin/lantern-player",
     "env": {"PLAYER_SCRIPTED": "moth"}},
]
out = os.path.join(ROOT, "tools", "ci", "policies.json")
with open(out, "w", encoding="utf-8") as fh:
    json.dump(policies, fh, indent=2, ensure_ascii=False)
    fh.write("\n")
print("wrote", out)
