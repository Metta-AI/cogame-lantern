# Lantern — rules

## The floor

A walled warehouse, 1235 × 659 px, origin top-left, +x right, +y down. One
authored map, `vault`: six square pillars, four three-sided alcoves with
one-crate-wide doorways, two long racks, two baffles, and the **seeker pen** —
a 120 × 110 px room at the bottom-centre edge whose north door is solid during
a build act and open during a hunt. The obstacle set is invariant under a 180°
rotation of the floor, so neither half plays a friendlier map than the other.

Static geometry is **not secret**. The blueprint is in every seat's
observation, both roles, always. What the dark hides is *where the crates
ended up and where the bodies are*.

## Bodies

- 13 × 13 px footprint against walls and other cogs; 21 × 21 px against
  crates, so a cog stops at a crate's face. Sub-pixel integer motion
  (`MotionScale = 256`).
- Hiders top out at 704 sub-pixels/tick (≈ 66 px/s); seekers at 768 (+9 %),
  because they have ground to cover.
- **Crawling** caps a cog at 40 % of its top speed, makes no footstep sound,
  and cannot push a crate.
- Every cog carries an aim in **brads** (256 per turn, 0 = east,
  counter-clockwise), turned at most 5 brads per tick.

## Crates

Ten crates `C0`…`C9`, 48 × 48 px, solid and opaque. Three states:

| state | pushable | breaks light | notes |
|---|---|---|---|
| `loose` | yes | yes | a hider shoves 6 px a tick, a seeker 4 |
| `locked` | **no** | yes | bolted: only a pry gets through it |
| `broken` | — | no | gone from the world |

A **lock** takes 24 ticks (1 s) held still within 20 px of a loose crate, and
each hider gets **three locks per half**. A **pry** takes 72 ticks (3 s) held
still within 20 px of a locked crate and ends in a 900 px sound ring — loud
enough that everyone still hiding hears it. Any progress resets the moment the
cog moves, releases the button, or changes target.

## Light

A seeker's lit set is everything within **420 px** whose bearing is within
**±18 brads** (a 50.6° beam) of its aim **and** has line of sight through walls
and live crates, plus an omni **60 px** bubble with line of sight. The three
seekers **share one radio**: anything one of them lights is in all three
seekers' observations that turn. Lanterns are OFF for every build tick.

A hider is **FOUND** when it is held in the team's light for 12 consecutive
ticks (half a second) or when any seeker's body centre comes within 24 px of it
with line of sight. On a find it is teleported to the caught pen and is inert
for the rest of the half.

## Sound

| kind | radius | rate | jitter | who hears it |
|---|---|---|---|---|
| footstep | 260 px | once per cog per 24 ticks, only above half speed and not crawling | ±40 px | seekers |
| crate push | 420 px | once per crate per 12 ticks | ±60 px | seekers |
| crate break | 900 px | on the break | ±30 px | everyone |

Rings live 24 ticks. The jitter is deterministic (one PCG32 stream from the
episode seed) and gives a listener a *place*, not a point.

## Heartbeat

Every hunt tick each seeker is told a five-band proximity reading off the
straight-line distance to the nearest unfound hider, with no direction:

`burning ≤ 120 px`, `hot ≤ 260`, `warm ≤ 450`, `cool ≤ 750`, `cold > 750`.

It is real information, not decoration, and it is exactly what the viewer's
heartbeat bars show.

## The clock

`dt = 1/24 s`. A **decision turn** is 120 ticks (5 s). At the first tick of a
turn the server freezes the state, builds each active seat's view, collects one
order per seat, and hands them to the control layer, which drives the cogs for
all 120 ticks. During a build act only the three hiding seats are queried — the
seekers are frozen in the pen and are not asked for an order they could not act
on.

## Resolution order (every tick, no exceptions)

1. Phase clock: derive half/act/turn; run the half reset at the boundary;
   append a keyframe every 24 ticks.
2. Frozen seats: during a build act a seeker's control is forced to zero, its
   velocity is held at 0, its aim is held and its lantern is off.
3. Control compile: the control layer reads the world and the seat's order.
4. Quantise to `(move_x i8, move_y i8, aim_turn i8, action u8)`. **The sim
   consumes only these bytes and the replay records only these bytes.**
5. Aim.
6. Motion: per-axis accelerate/clamp, friction on an axis with no input, wall
   slide, then cog–cog separation with restitution.
7. Crates: push along the dominant axis of the pusher's displacement, or revert
   the pusher along that axis if the crate cannot move.
8. Lock and pry.
9. Occlusion rebake, if any crate moved, locked or broke.
10. Lanterns and sight.
11. Detection.
12. Score accrual (hunt act only).
13. Heartbeat bands and sound decay.
14. Keyframe.
15. Act / half / match end.

## Half reset (exact, at the boundary)

Every crate returns to its authored start position in state `loose`; broken
crates return; every cog's velocity, aim and lock/pry progress are zeroed;
`locks_used` is cleared; found hiders leave the caught pen; the new hiders
spawn on the north line and the new seekers in the pen. **Nothing carries
across the intermission except the score.**

## Scoring

```
huntTicksPlayed(half)  hunt ticks actually simulated in that half
hidden_ticks(seat)     hunt ticks in that seat's HIDING half while unfound
f(team)                sum(hidden_ticks over the team's 3 seats)
                       ------------------------------------------
                            3 * huntTicksPlayed(its hiding half)

score(Moth) = 0.5 + 0.5 * (f(Moth) - f(Owl))
score(Owl)  = 1 - score(Moth)
```

Higher is better. Every seat carries its team's score, so `results.scores` sums
to 3.0 across six seats. `f(Moth) == f(Owl)` is a draw: `winner: null`, every
`win` false.

## End conditions

`results.reason` is a closed enum of exactly three values; `results.end_rule`
carries the detail.

| `reason` | `end_rule` | when |
|---|---|---|
| `complete` | `full_time` | all ticks simulated. The normal ending. |
| `deadline` | `wall_clock` | the wall-clock budget elapsed first. The score uses the hunt ticks actually played; if half 2's hunt never started, everybody scores 0.5. |
| `fault` | `sim_fault` | a sim invariant tripped (a cog outside the arena, a crate in a wall, a negative hidden-tick count). All scores 0.5. |
| `fault` | `host_error` | an unexpected server-side exception. Same treatment. |

A seat that never connects does **not** end the episode: its cog plays the
`warden` baseline for the whole match, the no-show is reported once to
`COGAME_PLAYER_FAILURE_URI`, and the match plays to full time.

## Determinism

Same seed + same control bytes ⇒ the same state digest at every keyframe, in
the native build **and** in the emscripten viewer build. The whole step is
integer: no `sin`, no `cos`, no `atan2`, no float arithmetic anywhere on the
step path, and no `-ffast-math`. `tests/test_vision.nim` greps the source to
keep it that way, and `tests/test_determinism.nim` pins the digests to a
committed golden fixture.
