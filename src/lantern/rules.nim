## The rules that are not physics: the phase clock, the heartbeat bands, the
## scoring formula, and the legality tables the order parser repairs against.
##
## Integer only — this is on the sim path. Scores are carried as fixed-point
## integers (micro for the hide fraction, milli for the published score) and
## only become floats in `events.nim` / the results builder, which are not.

import types

type
  Phase* = object
    half*: int          ## 1 or 2
    act*: Act
    turn*: int          ## global decision-turn index, 0-based
    actLeft*: int       ## ticks remaining in this act
    huntLeft*: int      ## ticks remaining in this half's hunt act

proc halfTicks*(config: GameConfig): int {.inline.} =
  config.prepTicks + config.huntTicks

proc totalTicks*(config: GameConfig): int {.inline.} =
  config.halves * halfTicks(config)

proc totalTurns*(config: GameConfig): int {.inline.} =
  totalTicks(config) div config.turnTicks

proc phaseAt*(config: GameConfig, tick: int): Phase =
  ## The exact map from a tick to (half, act, turn). Act boundaries are
  ## multiples of `turnTicks` by construction, so a turn never straddles one.
  let span = halfTicks(config)
  let clamped = clampInt(tick, 0, totalTicks(config) - 1)
  result.half = clamped div span + 1
  let within = clamped mod span
  if within < config.prepTicks:
    result.act = actBuild
    result.actLeft = config.prepTicks - within
    result.huntLeft = config.huntTicks
  else:
    result.act = actHunt
    result.actLeft = span - within
    result.huntLeft = span - within
  result.turn = clamped div config.turnTicks

proc isTurnStart*(config: GameConfig, tick: int): bool {.inline.} =
  tick mod config.turnTicks == 0

proc isHalfBoundary*(config: GameConfig, tick: int): bool {.inline.} =
  tick > 0 and tick mod halfTicks(config) == 0 and tick < totalTicks(config)

proc bandFor*(distance: int): Band =
  if distance <= BandBurningPx: bdBurning
  elif distance <= BandHotPx: bdHot
  elif distance <= BandWarmPx: bdWarm
  elif distance <= BandCoolPx: bdCool
  else: bdCold

proc bandCode*(band: Band): int {.inline.} =
  ## 0 cold .. 4 burning, the encoding the keyframe `hb` array uses.
  ord(band)

# ---------------------------------------------------------------------------
# Intent legality. `intent` is the only field whose repair depends on the
# seat's role, so the tables live next to the rules rather than in the parser.
# ---------------------------------------------------------------------------

const
  HiderIntents* = {inPush, inLock, inHide, inFlee, inScout, inWait}
  SeekerIntents* = {inSweep, inBeeline, inChase, inPry, inHold, inWait}

proc legalFor*(intent: Intent, role: Role): bool {.inline.} =
  case role
  of roHider: intent in HiderIntents
  of roSeeker: intent in SeekerIntents

proc defaultIntent*(role: Role): Intent {.inline.} =
  case role
  of roHider: inHide
  of roSeeker: inSweep

proc needsCrate*(intent: Intent): bool {.inline.} =
  intent in {inPush, inLock, inPry}

# ---------------------------------------------------------------------------
# Scoring. Seconds hidden, normalised, compared across the two symmetric
# halves, exactly zero-sum between the sides.
#
#   f(team)     = sum(hidden_ticks of the team's seats) / (3 * huntTicksPlayed)
#   score(Moth) = 0.5 + 0.5 * (f(Moth) - f(Owl));  score(Owl) = 1 - score(Moth)
# ---------------------------------------------------------------------------

const
  MicroOne* = 1_000_000
  MilliOne* = 1_000

proc hiddenFracMicro*(hiddenTicks: seq[int], huntTicksPlayed: int): int =
  ## f(team) in millionths. A half whose hunt act never ran scores 0 here and
  ## is handled by `scoreMilli`, which refuses to compare an unplayed half.
  if huntTicksPlayed <= 0:
    return 0
  var total = 0
  for ticks in hiddenTicks:
    total += ticks
  let denominator = TeamSize * huntTicksPlayed
  clampInt(total * MicroOne div denominator, 0, MicroOne)

proc scoreMilli*(fMothMicro, fOwlMicro: int, comparable: bool): (int, int) =
  ## (Moth, Owl) in thousandths, summing to exactly 1000. `comparable` is
  ## false when one side never got to hide — then the episode is a 0.5 draw
  ## for everybody, which is the honest reading of a wall-clock stop.
  if not comparable:
    return (500, 500)
  let moth = (MicroOne + fMothMicro - fOwlMicro) div 2
  let mothMilli = clampInt((moth + 500) div 1000, 0, MilliOne)
  (mothMilli, MilliOne - mothMilli)

proc winnerOf*(mothMilli: int): int =
  ## 0 Moth, 1 Owl, -1 draw (rendered as `null`).
  if mothMilli > 500: 0
  elif mothMilli < 500: 1
  else: -1
