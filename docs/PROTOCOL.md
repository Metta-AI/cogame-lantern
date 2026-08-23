# Lantern — wire protocol

Three surfaces: the **player** websocket (what a policy container speaks), the
**global** spectator stream, and the **replay** bytes. All JSON, all UTF-8.

## Player protocol — `lantern.player.v1`

JSON text frames over the websocket named by `COWORLD_PLAYER_WS_URL` (the
platform already appends `?slot=N&token=T`). A bad slot or token gets a **403**
and a second connection on a live slot gets a **409**.

A lantern policy is a prompt, and decisions are made in the GAME server, so the
player container has exactly one job. On connect it sends **one** frame:

```json
{"type": "register",
 "prompt": "<strategy text, or empty>",
 "scripted": "warden" | "moth" | null,
 "policy": "<free label, <= 48 runes>"}
```

`PLAYER_SCRIPTED` parsing: `warden` / `1` / `true` / `yes` → the warden
baseline, `moth` → the moth baseline, anything else → none. A seat that
registers with neither field, or never registers at all, plays `warden`.
An over-long `prompt` is truncated at 4000 runes, never rejected.

The server answers `welcome`, then one `turn` frame per decision turn, then the
final frame:

```json
{"type": "welcome", "protocol": "lantern.player.v1", "slot": 0,
 "alias": "Moth-1", "team": "Moth", "hides_in_half": 1, "turns": 42}

{"type": "turn", "turn": 17, "tick": 2040, "half": 1, "act": "hunt",
 "role": "hider", "view": { … }, "order_source": "llm"}

{"done": true, "result": { …the results document… }}
```

The `turn` frame is **informational**: the seat is not required to answer, and
nothing it sends after `register` is read. It exists so a policy author can see
exactly what its prompt was shown.

## The per-seat view

Coordinates are integers in map pixels. Two shapes, one per role.

**Hider** — sees the full static map, **all ten crate positions and states**
(it knows the fort it built: that asymmetry is what makes construction pay),
its own trio, its clock and locks left, seekers within 700 px with line of
sight, the bearing and band of any beam sweeping within 220 px, and break-ring
sounds.

```json
{"turn": 4, "of": 42, "half": 1, "act": "build",
 "clock": {"act_left_s": 10.0, "hunt_left_s": 75.0},
 "you": {"alias": "Moth-2", "pos": [612, 118], "aim": 64, "crawl": false,
         "found": false, "hidden_s": 0.0, "locks_left": 3},
 "map": {"w": 1235, "h": 659, "walls": [[0,0,1235,16], …],
         "nooks": [{"anchor": [240,329], "opening": [[196,306],[196,353]]}, …],
         "pen": [558, 545, 120, 110]},
 "crates": [{"id": "C0", "pos": [150,329], "state": "loose"}, … 10 … ],
 "team": [{"alias": "Moth-1", "pos": [150,110], "found": false, "hidden_s": 0.0}, …],
 "seekers_seen": [{"alias": "Owl-3", "pos": [700,540], "aim": 96, "dist": 430}],
 "beams": [{"bearing": 192, "band": "near"}],
 "sounds": [{"kind": "break", "pos": [742,520], "age_ticks": 8}],
 "found_count": 0,
 "your_last_order": { … or null on turn 0 … }}
```

**Seeker** — sees the full static map, its own position/aim/heartbeat, **only
what the team's three lanterns currently light**, its team-mates' positions and
bands, every sound ring within earshot (jittered), the found list and the
clock. It does **not** see unlit crates, unlit hiders, the hiders' orders,
notes or `say` text, the exact heartbeat distance, or the seed.

```json
{"turn": 19, "of": 42, "half": 1, "act": "hunt",
 "clock": {"act_left_s": 40.0},
 "you": {"alias": "Owl-1", "pos": [430,300], "aim": 32,
         "heartbeat": "warm", "prying": null},
 "map": { …identical to the hider's map block… },
 "lit": {"crates": [{"id": "C4", "pos": [450,380], "state": "locked"}],
         "hiders": [{"alias": "Moth-3", "pos": [910,215], "lit_by": "Owl-2",
                     "streak_ticks": 4}]},
 "team": [{"alias": "Owl-2", "pos": [900,240], "aim": 200, "heartbeat": "hot"}, …],
 "sounds": [{"kind": "push", "pos": [560,180], "age_ticks": 14}],
 "found": [{"alias": "Moth-1", "at_s": 21.5}],
 "found_count": 1, "hiders_left": 2,
 "your_last_order": { … }}
```

Hidden from **everyone**, both roles: the opponent's prompts, notes and `say`
strings (they exist only in the replay, for spectators), the real player names
behind the aliases, and future ticks.

## The order

One per seat per turn. The scripted baselines emit the identical shape, so the
two policy kinds are strictly comparable.

```json
{"intent": "push", "target": [196, 329], "crate": "C4",
 "aim": "target", "crawl": false,
 "note": "screening the west alcove before the lights go", "say": "west screen"}
```

| field | legal values | repair when violated |
|---|---|---|
| `intent` | hider: `push` `lock` `hide` `flee` `scout` `wait`; seeker: `sweep` `beeline` `chase` `pry` `hold` `wait` | legal-for-the-other-role → `hide` / `sweep`; unknown → a retry |
| `target` | `[int, int]`, clamped to x ∈ [8, 1227], y ∈ [8, 651] | missing → the cog's current position |
| `crate` | `"C0"`…`"C9"`, case-insensitive, ≤ 4 runes; an integer 0–9 also accepted | unknown → the nearest crate legal for the intent; none legal → the intent degrades |
| `aim` | `sweep` `hold` `track` `target` | → `target`; ignored for hiders |
| `crawl` | `true`/`false`, also `"true"`/`"false"`/`0`/`1` | → `false`; forced `false` for a seeker |
| `note` | ≤ 140 **runes** | truncated on a rune boundary |
| `say` | ≤ 32 **runes** | truncated on a rune boundary |

Three further caps on strings that reach the replay: `register.policy` ≤ 48
runes, `fallback.detail` ≤ 200 runes, `register.prompt` ≤ 4000 runes at the
transport. **Truncation is on rune boundaries, never bytes** — a byte-truncated
multi-byte character renders in a browser and then fails a strict JSON parser.

Parsing is tolerant: markdown fences are stripped, the outermost balanced
`{…}` is taken if the model prefixed prose, numeric strings are accepted for
`target`, and `crate` may be an integer. Only when no object with a usable
`intent` can be recovered does the retry fire, and only when the retry also
fails does the seat get the `warden` order plus a `fallback` event.

## Decisions and timing

All open seats' requests go out as **ONE PARALLEL BATCH** per turn
(`curly.makeRequests`) — never a sequential walk. A hunt turn batches six
requests, a build turn three. Per turn, per seat: attempt 1 gets 8.5 s, the one
retry gets 3.5 s with a "your previous reply was invalid" hint, and then the
scripted order. At the start of each turn, if two more full turn budgets would
not fit inside `wallClockBudgetSeconds`, the **budget guard** engages and every
remaining turn plays scripted, so the episode ends `complete/full_time` rather
than `deadline`.

## Spectator stream — `/global`

A whole-world snapshot on connect and every few seconds after: tick, turn,
half, act, the map block, every cog (alias, team, role, position, aim, crawl,
found, hidden ticks, heartbeat, current intent/note/say/source), every crate,
live sound rings, the policy names and the team colours. Nothing is hidden from
a spectator — that is the point of the second name space.

## Replay bytes — `lantern.replay.v1`

Strict UTF-8 JSON, self-sufficient: the viewer contacts nothing but the S3 URL
it was given.

```json
{"protocol": "lantern.replay.v1", "format_version": 1, "game_version": "1",
 "seed": 679961,
 "config": { …the resolved config, tokens excluded… },
 "map": { …data/vault.mapspec.json inlined verbatim… },
 "names": {"players": […], "aliases": […], "teams": […],
           "policy_kinds": […], "colors": {"Moth": "#f2c14e", "Owl": "#4ecdc4"}},
 "ticks_per_second": 24, "turn_ticks": 120, "tick_count": 5040,
 "phases": [{"half": 1, "act": "build", "from": 0, "to": 719}, …],
 "controls_b64": "<base64 of tick_count x 6 x 4 bytes>",
 "keyframes": [{"t": 0, "d": 2947483111, "cogs": [[150,110,64,0], …],
                "crates": [[150,329,0], …], "hb": [0,0,0], "hid": [0,0,0,0,0,0]}, …],
 "events": [ … ],
 "results": { … }}
```

Cog state codes: `0` active, `1` frozen in the pen, `2` crawling, `3` found.
Crate state codes: `0` loose, `1` locked, `2` broken. `hb` is the three
seekers' heartbeat bands (0 cold … 4 burning); `hid` the six hidden-tick
counters.

### Event vocabulary

Every record carries `t` (tick), plus `turn`, `half`, `act` where meaningful.

| `type` | fields |
|---|---|
| `match_start` | `seed`, `map`, `aliases`, `teams`, `hid_in_half` |
| `half_start` | `half`, `hiders`, `seekers` |
| `act_start` | `half`, `act` |
| `turn_start` | `turn`, `half`, `act`, `hidden_s` (per team), `hiders_left` |
| `order` | `turn`, `seat`, `alias`, `role`, `source` (`llm`/`scripted`/`fallback`), `latency_ms`, `intent`, `target`, `crate`, `aim`, `crawl`, `note`, `say` |
| `fallback` | `turn`, `seat`, `attempt`, `cause`, `detail` |
| `budget_guard` | `turn`, `remaining_s` |
| `crate_push` | `seat`, `alias`, `crate`, `from`, `to` |
| `crate_lock` | `seat`, `alias`, `crate`, `pos` |
| `crate_pry` | `seat`, `alias`, `crate`, `pct` |
| `crate_break` | `seat`, `alias`, `crate`, `pos` |
| `sound` | `kind`, `pos` (jittered), `radius` |
| `spot` | `seeker`, `hider`, `dist` |
| `found` | `half`, `hider`, `seeker`, `mode` (`beam`/`tag`), `hidden_s`, `hiders_left` |
| `act_end` | `half`, `act`, `reason` (`time`/`all_found`) |
| `half_end` | `half`, `hidden_frac`, `hidden_s`, `per_hider` |
| `end` | `reason`, `end_rule`, `scores`, `team_hidden_frac`, `winner` |

## Results document

Per-seat arrays are length 6 in slot order; `team_*` arrays are length 2, index
0 = Moth, 1 = Owl. The key set is closed and must equal the manifest's
`results_schema` — `tests/test_manifest.nim` compares the two.

```json
{"names": [...], "aliases": [...], "teams": [...], "hid_in_half": [...],
 "policy_kinds": [...], "scores": [...], "win": [...],
 "hidden_ticks": [...], "hidden_seconds": [...], "finds": [...],
 "crates_pushed": [...], "crates_locked": [...], "crates_broken": [...],
 "team_hidden_frac": [0.569, 0.813], "team_hidden_seconds": [128.0, 183.0],
 "reason": "complete", "end_rule": "full_time", "winner": 1,
 "final_tick": 5040, "final_turn": 42, "halves_played": 2,
 "hunt_ticks_played": [1800, 1800], "seed": 679961,
 "llm_turns": [...], "fallback_turns": [...], "fallback_causes": [...]}
```

## Runtime contract

`COGAME_CONFIG_URI` (required), `COGAME_RESULTS_URI`, `COGAME_SAVE_REPLAY_URI`,
`COGAME_LOAD_REPLAY_URI`, `COGAME_PLAYER_FAILURE_URI`, `COGAME_EVENTS_URI` and
`COGAME_METRICS_URI` (**file:// only** — any other scheme is refused loudly at
startup), `COGAME_HOST`, `COGAME_PORT`. At the end of an episode the server
broadcasts `done` to every seat with a bounded 3 s wait, writes the replay, and
then writes the results — in that order, because the hosted worker tears the
player pods down the moment `results.json` exists.
