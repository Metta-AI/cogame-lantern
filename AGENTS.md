# Agent operating guide — cogame-lantern

Orientation for coding agents working in this repo. Gameplay rules live in
[docs/RULES.md](docs/RULES.md), the wire contract in
[docs/PROTOCOL.md](docs/PROTOCOL.md), and the design this repo implements in
[docs/plans/2026-08-22-lantern-design.md](docs/plans/2026-08-22-lantern-design.md).
This file covers the things that are easy to get wrong.

## The three properties that are load-bearing

**1. The sim step is INTEGER-ONLY.** `src/lantern/{types,arena,crates,rules,sim,control,baselines}.nim`
contain no float arithmetic and no trigonometry — not `sin`, not `cos`, not
`atan2`, not `sqrt`, and no `-ffast-math` in any build script. That is what
makes the native build and the emscripten replay-viewer build agree bit for
bit, which is what makes "the viewer re-derived the same match" a claim the
viewer can prove. `tests/test_vision.nim` greps for all of it. If you need an
angle, use brads and `UnitTable`; if you need a root, use `intRoot`; if you
need a fraction, carry it as fixed point (milli or micro) and convert to float
only in `events.nim`, `replay.nim` or `server.nim`, which are not on the step
path.

**2. The determinism boundary is four bytes per cog per tick.** The sim
consumes only `(move_x i8, move_y i8, aim_turn i8, action u8)` and the replay
records only those bytes. Anything that changes the world must go through
them. A rule that reads the wall clock, a hash of a pointer, or an unrecorded
RNG draw breaks re-derivation, and the failure looks like a viewer bug three
phases later. The one RNG is a PCG32 seeded from the episode seed and used for
exactly two things: the sound-ring jitter and the `moth` baseline's waypoints.

**3. Every recorded string is truncated on RUNE boundaries.** Use
`orders.clip`, never a byte slice. A byte-truncated multi-byte character
renders fine in a browser and then fails the strict JSON parse the platform
runs on the replay it fetched from S3.

## Layout

- `src/lantern.nim` — the entrypoint. **Seed randomisation happens here,
  before `config.update`**, so every seed-derived draw follows the final seed.
  A missing or invalid config exits 2 with one clean line and no traceback:
  `tests/test_startup.nim` asserts the shape, because a traceback looks like a
  crashed game to the platform.
- `src/lantern_player.nim` — the whole player container. It registers once and
  then only receives. It exits **0** when it cannot dial the game: the server
  plays an absent seat with the warden baseline, and a non-zero exit here
  would fail an episode the game already handles.
- `src/lantern/` — the modules, in dependency order: `types` → `labels`,
  `config`, `roster`, `events`, `state`, `arena` → `crates` → `rules` → `sim`
  → `control` → `orders` → `baselines` → `render` → `llm` → `replay`,
  `broadcast` → `server`.
- `client/` — the broadcast chrome (`replay_broadcast.html`, forked from
  paintbot with its CSS block and every markup id carried across),
  `chrome_common.js` and `broadcast_core.js` (the board renderer).
- `replay-viewer/` — the wasm module and the OffscreenCanvas Worker shell.
  Shared with the game server's `/client/replay`, so a change here shows up in
  both.
- `data/vault.mapspec.json` — **generated**, by `scripts/art/author_map.py`.
  Do not hand-edit it: the generator is where the fairness invariants are
  checked before the file is written.
- `tests/` — one standalone program per concern; helpers live in
  `tests/support/` so the `tests/*.nim` glob never runs one as a test.

## Changing a rule

1. Change the rule.
2. Bump `GameVersion` in `src/lantern/types.nim` and say on the changelog
   comment what the number means. The replay pins it, so a viewer can refuse a
   replay it cannot re-derive.
3. Re-record the fixtures **in the same commit**:
   `nim r --path:src tools/record_fixtures.nim`. A diff in
   `tests/fixtures/golden_digests.json` IS the rule change — that is what the
   fixture is for. Never re-record to make a red test green on its own.
4. If the results key set changed, edit `coworld_manifest_template.json`'s
   `results_schema` in the same commit: `tests/test_manifest.nim` compares the
   manifest's keys against what the server actually emits.

## Changing the map

`python3 scripts/art/author_map.py > data/vault.mapspec.json`. The generator
refuses to write a map where any obstacle lacks its 180°-rotational twin, or
where a spawn, nook anchor, sweep-lane waypoint or crate box is not on free
floor. `tests/test_map.nim` re-checks the same invariants against the
committed file, plus one the generator cannot see: that a seeker can actually
reach the first waypoint of its lane out of the pen. A lane whose first
waypoint is unreachable pins a seeker against the pen wall for a whole half —
that happened in development and it is why every lane now starts at the pen
mouth.

## Changing the art

`python3 scripts/art/build_art.py` for the floor, crates and lockerroom plate.
The two cog sprites (`client/art/cog_owl_rig.png`, `cog_moth_rig.png`) are
nano-banana (Gemini image) renders of the Softmax cog — the Owl warden with a
brass lantern, the Moth with spread wing panels — regenerated from the
committed sheet with `python3 scripts/art/split_cog_sheet.py`
(`scripts/art/source/cogs_sheet.png`). Committed output under `client/art/`;
the bundle is hermetic and downloads nothing.

## Testing

```bash
nim r --path:src tests/test_rules.nim         # one file
for t in tests/*.nim; do nim r --path:src "$t"; done
```

CI runs every file twice, debug and `-d:release`. Debug catches range and
overflow bugs; release catches codegen bugs a debug-only CI has shipped
before. `tests/test_startup.nim` compiles the two binaries itself, so it is
the slow one.

The sandbox this repo was built in had no Docker and no emsdk: **CI is the
harness** for `docker_smoke.sh` and the wasm bundle. Do not report "it should
work" for either.

## Things that will bite you

- **`tools/build_replay_viewer.sh` and `tools/ci/docker_smoke.sh` must stay
  mode 100755.** `coworld build` refuses to package a source replay-viewer
  bundle unless the hook is `os.X_OK`, and CI asserts the bit before invoking
  either. Set it with `git update-index --chmod=+x <path>`.
- **`num_agents` must appear in every manifest variant AND the certification
  fixture.** Missing from one variant, the ladder schedules zero episodes and
  nothing says why.
- **The LLM batch is ONE `curly.makeRequests` per turn.** Lantern is a
  simultaneous-decision game; a sequential walk over six seats is what blows
  the play budget, and it is invisible unless something counts the batches.
  `tests/test_engine.nim` counts them.
- **The parked cogs in a test are not inert scenery.** A seeker parked 30 px
  from a hider lights it through the omni bubble. Park them far apart or
  assert on the specific alias you care about.
- **A change in the last few ticks of a half is legitimately invisible
  afterwards.** The half reset restores everything except the score, so a
  determinism probe has to land mid-half.
