# lantern

**3v3 hide-and-seek in the dark, played twice with the sides swapped.**

Six cogs share a walled 1235 × 659 px warehouse floor lit only by the seekers'
flashlights. In each half one trio — the **hiders** — gets a 30-second
lights-on build act to shove and bolt wooden crates into a fort. Then the
lights go out, the seekers' pen door opens, and the seekers get 75 seconds to
sweep the dark and find all three. A hider's score is the time it survives
unfound. Then the sides swap, the map resets to its exact starting layout, and
the second half is played under identical conditions. **The team that hid
longer wins.**

A **policy is just a prompt.** Every seat is an LLM policy: once every five
seconds the game server hands that seat's prompt plus that seat's view of the
world to Claude and asks for ONE order — an intent, a target, a crate, an aim
mode and a crawl flag. A deterministic control layer executes that order at
24 Hz for the next five seconds. Field your own policy by reusing the
published image and setting `PLAYER_PROMPT`:

```bash
coworld upload-policy coworld-lantern:latest --name my-lantern \
  --run /bin/lantern-player \
  --secret-env PLAYER_PROMPT="Build a warren, then vanish into it..."
```

Two scripted baselines ship in the same image and play any seat that sets
`PLAYER_SCRIPTED=warden` or `PLAYER_SCRIPTED=moth` — and every seat when no
LLM credentials are available at all, so an episode always completes.

## The shape of a match

| Segment | Ticks | Sim time | Decision turns |
|---|---|---|---|
| Half 1 — build (Moth hides) | 0 – 719 | 30 s | 6 |
| Half 1 — hunt | 720 – 2519 | 75 s | 15 |
| Half 2 — build (Owl hides) | 2520 – 3239 | 30 s | 6 |
| Half 2 — hunt | 3240 – 5039 | 75 s | 15 |
| **Total** | **5040** | **210 s** | **42** |

Seats are fixed: **even slots (0, 2, 4) are team Moth, odd slots (1, 3, 5) are
team Owl**, so the two champions always land on opposite sides. In-game a cog
is only ever `Moth-1`…`Owl-3`; the real player names appear spectator-side
only, in the scorebug, the endcard and the results.

## Scoring

```
f(team)     = sum of the team's hidden ticks / (3 * hunt ticks in its hiding half)
score(Moth) = 0.5 + 0.5 * (f(Moth) - f(Owl))
score(Owl)  = 1 - score(Moth)
```

Higher is better, `score ∈ [0, 1]`, and the two scores always sum to 1: the
game is exactly zero-sum between the sides, which is what makes cross-episode
win-trading pointless. Hiding well and seeking well are the same skill on this
scale — a team's own `f` is its hiding, and the opponent's `f` is what its
seeking held down.

Full rules: [docs/RULES.md](docs/RULES.md). Wire protocol:
[docs/PROTOCOL.md](docs/PROTOCOL.md). Design note:
[docs/plans/2026-08-22-lantern-design.md](docs/plans/2026-08-22-lantern-design.md).

## Watching a match

Replays are a **static wasm bundle**, never a pod. The bundle re-derives every
frame in the browser from `seed` + `map` + `controls_b64` with the same integer
Nim sim the server ran, and checks itself against the recorded keyframe
digests. What you see:

- flashlight cones sweeping a near-black floor, with crates throwing the
  shadows the hiders are standing in;
- unlit hiders as 30 %-alpha silhouettes — the dramatic irony the seekers do
  not get (bound to the `spoilers` toggle, default on);
- a proximity **heartbeat bar** per seeker, straight off the keyframe `hb`
  array, so it is exactly what that seeker was told;
- a spotlight **burst** on a find, with the banner and the feed line;
- the 30-second build acts run as a **4× timelapse**, then 1× the moment the
  hunt starts;
- a **side-swap intermission card** at half time so the reset is visibly real.

> **Unreleased on `main`:** the worker's 30-second wasm-runtime watchdog
> (a runtime that never initialises now reports an error instead of leaving the
> page on "loading replay") landed after 0.1.5 was published, so it is on `main`
> but not in any served bundle yet. It ships with the next release; delete this
> note then.

## Running it locally

```bash
docker build -t coworld-lantern:latest .
tools/ci/docker_smoke.sh coworld-lantern:latest    # one full episode, raw docker
tools/build_replay_viewer.sh "$PWD/dist/static-replay-viewer"
```

Tests are plain Nim programs, one file per concern:

```bash
nim r --path:src tests/test_rules.nim
```

CI runs every `tests/*.nim` twice, debug and `-d:release`.

## Layout

```
src/lantern.nim          the game server entrypoint (seed randomisation lives here)
src/lantern_player.nim   the thin player: register, then receive until done
src/lantern/             types, arena, crates, sim, rules, control, orders,
                         baselines, llm, state, config, roster, events, labels,
                         broadcast, render, replay, server
client/                  the broadcast chrome and the board renderer
replay-viewer/           the wasm module, the OffscreenCanvas worker shell
data/vault.mapspec.json  the one authored map
scripts/art/             the committed art and map generators
tools/                   the CI hooks and the fixture recorder
```

Lantern is forked from [`Metta-AI/coworld-ctf`](https://github.com/Metta-AI/coworld-ctf)
(paintbot) — its integer physics, its fog-of-war cone, its pushable props and
its broadcast chrome — with the server-side LLM client and the JSON replay
shape taken from [`Metta-AI/cogame-bullwhip`](https://github.com/Metta-AI/cogame-bullwhip).
