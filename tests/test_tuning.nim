## The tuning record is live: the shipped warden parameters ARE the grid
## argmax, and the committed table still reproduces from this code.
##
## Acceptance checklist item 7 asks that the baseline's parameters were tuned
## with a grid harness rather than guessed. The harness is
## `tools/tune_baselines.nim`, its output is `tests/fixtures/tuning_grid.json`,
## and this file is what stops either of them going stale: it re-derives the
## argmax from the committed table and re-runs two of the table's cells.

import std/[json, os, unittest]
import support/helpers
import ../tools/tune_baselines

suite "the warden's parameters were tuned with a grid harness":
  let record = parseJson(readRepoFile("tests" / "fixtures" /
                                      "tuning_grid.json"))
  let cells = cellsOf(record)

  test "the record covers exactly the grid the harness sweeps":
    check cells.len == gridPoints().len
    var seen: seq[WardenParams]
    for cell in cells:
      seen.add(cell.params)
    for point in gridPoints():
      check point in seen
    check record["seeds"] == %(@Seeds)
    check record["prep_ticks"].getInt() == Prep
    check record["hunt_ticks"].getInt() == Hunt
    check record["game_version"].getStr() == GameVersion
    check paramsOf(record["reference"]) == ReferenceWardenParams
    for cell in cells:
      check cell.vsMothMilli.len == Seeds.len
      check cell.vsReferenceMilli.len == Seeds.len

  test "the shipped parameters are the recorded argmax":
    check paramsOf(record["chosen"]) == ShippedWardenParams
    check bestOf(cells).params == ShippedWardenParams
    check bestOf(cells).meanMilli == record["chosen_mean_milli"].getInt()
    ## And the sweep actually moved something: the argmax beats the
    ## hand-guessed starting point the design note pinned.
    var guessed = -1
    for cell in cells:
      if cell.params == ReferenceWardenParams:
        guessed = cell.meanMilli
    check guessed >= 0
    check bestOf(cells).meanMilli > guessed

  test "the recorded numbers still come out of this code":
    ## The staleness guard. Two cells, one seed each: a parameter edited by
    ## hand instead of through the harness fails here.
    for params in [ShippedWardenParams, ReferenceWardenParams]:
      var recorded = GridCell(meanMilli: -1)
      for cell in cells:
        if cell.params == params:
          recorded = cell
      check recorded.meanMilli >= 0
      check scoreVsMoth(Seeds[0], params) == recorded.vsMothMilli[0]
      check scoreVsReference(Seeds[0], params) == recorded.vsReferenceMilli[0]
