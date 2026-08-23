# Tuning the `warden` baseline

The `warden` baseline is the certification player, the ladder's filler and the
order every LLM seat falls back to, so its three numbers are worth more than a
guess. They were chosen by sweeping a grid, not by eye.

## The harness

`tools/tune_baselines.nim`:

```bash
nim r --path:src tools/tune_baselines.nim     # ~20 s, writes the record below
```

It sweeps the full 3x3x3 cross product of

| parameter | meaning | grid |
|---|---|---|
| `coverageGatePct` | screen this much of the nook's mouth with a crate, then bolt it | 40, 60, 80 |
| `buildLocks` | locks the hider spends during the build act | 1, 2, 3 |
| `pryHotTurns` | hot/burning turns with nothing lit before the seeker pries | 1, 2, 3 |

over the seeds `1, 7, 42, 99`. Every cell plays two **full-length** matches per
seed (720 prep + 1800 hunt ticks a half) with the candidate warden on the Moth
seats:

* against the other shipped baseline, `moth`;
* against `ReferenceWardenParams` — 60 / 2 / 2, the hand-guessed starting point
  the design note pinned before any sweep. The reference is a fixed constant
  rather than the shipped values, so the table does not chase its own tail and
  the recorded numbers stay reproducible.

The score is exactly zero-sum between the sides, so the Moth side's score in
milli is the whole result of one match; a cell's figure is the mean of both
columns over all four seeds. Ties are broken toward the reference point: a
parameter only moves when the grid shows it winning.

Match length matters. At the certification fixture's 240/480 the build act is
two turns long, every cell scores identically and the sweep sees nothing; the
parameters only have to work at full length, so that is where they are scored.

## The result

`tests/fixtures/tuning_grid.json` is the committed table. The top and bottom of
it, mean milli:

| gate | locks | hot | mean | vs `moth` | vs reference |
|---|---|---|---|---|---|
| 60 | 1 | 3 | **575** | 631, 669, 688, 823 | 448, 448, 448, 448 |
| 60 | 2 | 3 | 569 | 576, 657, 563, 657 | 495, 495, 556, 556 |
| 60 | 3 | 3 | 569 | 576, 657, 563, 657 | 495, 495, 556, 556 |
| 60 | 1 | 1 | 523 | 631, 669, 688, 823 | 344, 344, 344, 344 |
| 60 | 2 | 1 | 517 | 576, 657, 563, 657 | 392, 392, 453, 453 |
| 60 | 3 | 1 | 517 | 576, 657, 563, 657 | 392, 392, 453, 453 |
| 60 | 1 | 2 | 464 | 631, 669, 688, 823 | 226, 226, 226, 226 |
| 60 | 2 | 2 | 458 | 576, 657, 563, 657 | 273, 273, 334, 334 | ← the guess

What the sweep says:

* **`buildLocks` is a wash since GV2.** Under GV1's 13 px crate body three
  bolted crates was the one clear win (656 against 559 for the guess). With
  the 21 px crate body a hider spends longer getting a crate into place, and
  one lock now edges two and three by 6 milli (575 against 569) — inside the
  noise of four seeds, so the harness's argmax carries it, not a story.
* **`pryHotTurns` matters only against an opponent that bolts crates.** `moth`
  never locks anything, so every value scores the same against it; against the
  reference warden 3 beats 1 (448 vs 344 at `buildLocks = 1`), so the argmax
  takes it at 3.
* **`coverageGatePct` is inert.** 40, 60 and 80 score *identically* in every
  row: the "bolt on the last build turn" and "bolt if the crate is within 36 px
  of the mouth" clauses fire before the coverage test ever binds. The tie-break
  keeps the reference's 60.

`baselines.ShippedWardenParams` is the argmax of that table — 60 / 1 / 3 (it
was 60 / 3 / 3 under GV1). It supersedes the 60 / 2 / 2 the design note pinned
by hand.

## Keeping it honest

`tests/test_tuning.nim` runs in CI, in both build modes, and asserts

1. the record covers exactly the grid the harness sweeps, at the recorded seeds
   and episode length, for this `GameVersion`;
2. `ShippedWardenParams` equals the record's `chosen`, and re-deriving the
   argmax from the recorded table lands on the same point;
3. two of the table's cells, re-run against the current code, still produce the
   recorded numbers.

So editing a warden parameter by hand without re-running the harness fails the
build, and a rule change that moves the numbers shows up as a failed
reproduction rather than a stale document.
