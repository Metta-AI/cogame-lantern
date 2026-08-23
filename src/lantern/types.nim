## Lantern core types and constants.
##
## THE SIM PATH IS INTEGER-ONLY. This module, together with `arena.nim`,
## `crates.nim`, `rules.nim`, `sim.nim`, `control.nim` and `baselines.nim`,
## carries no float arithmetic and no trigonometry: the native build and the
## emscripten replay-viewer build have to agree bit for bit, and the cheapest
## way to guarantee that is to never let a float near the step. Angles are
## brads (256 per turn, 0 = east, counter-clockwise), positions are sub-pixel
## integers at `MotionScale` units per pixel, and `tests/test_vision.nim`
## greps these files to keep it that way.

import std/json

const
  GameVersion* = "2"
    ## GV1 (lantern v1): 3v3 hide-and-seek, two acts per half, two halves.
    ## GV2: a cog meets a crate with a 21 px body (CrateBodyHalf 10). The
    ## 13 px wall body let cogs sink a dozen pixels into a crate before
    ## it pushed back; the sprite is 36 px wide.
    ## Bump this whenever a rule changes what a recorded control byte does;
    ## the replay pins it so a viewer can refuse a replay it cannot re-derive.
  ReplayProtocol* = "lantern.replay.v1"
  ReplayFormatVersion* = 1

  # ---- clock -------------------------------------------------------------
  TargetFps* = 24
  ReplayFps* = 24
  PlaybackSpeeds* = [1, 2, 3, 4, 8, 16]

  # ---- bodies and motion (paintbot's integer physics) --------------------
  MotionScale* = 256
  Accel* = 76
  FrictionNum* = 144
  FrictionDen* = 256
  MaxSpeed* = 704           ## hider top speed, sub-pixels per tick
  SeekerMaxSpeed* = 768     ## seekers cover ground: +9 %
  CrawlPercent* = 40        ## a crawling cog is capped at 40 % of its max
  StopThreshold* = 8
  PlayerHalf* = 6           ## the wall body: what slides along walls
  CrateBodyHalf* = 10       ## the crate body: what a crate pushes back on
  PlayerBouncePct* = 40
  MovementSlideMaxScan* = 3

  # ---- floor -------------------------------------------------------------
  MapWidth* = 1235
  MapHeight* = 659
  Seats* = 6
  TeamSize* = 3
  CrateSize* = 48
  CrateHalf* = 24

  # ---- aim ---------------------------------------------------------------
  Brads* = 256
  AimTurnRate* = 5

  # ---- interaction -------------------------------------------------------
  HiderPushPx* = 6
  SeekerPushPx* = 4
  InteractRangePx* = 20     ## how close a cog stands to lock or pry
  TouchTagPx* = 24
  SeekerSeenPx* = 700       ## a hider sees seekers this close, with sight
  BeamNearPx* = 220         ## a beam this close to a hider is "reported"
  UnstickTicks* = 24
  UnstickPx* = 6

  # ---- line of sight -----------------------------------------------------
  FovCell* = 8
    ## Sight is traced over an 8 px occupancy grid rather than the raw pixel
    ## mask: a 48 px crate is six cells wide, so occlusion is exact at the
    ## scale that matters, and a full match costs a few million cell reads
    ## instead of a few hundred million.
  FovW* = (MapWidth + FovCell - 1) div FovCell
  FovH* = (MapHeight + FovCell - 1) div FovCell

  # ---- sound -------------------------------------------------------------
  StepSoundPx* = 260
  PushSoundPx* = 420
  BreakSoundPx* = 900
  StepJitterPx* = 40
  PushJitterPx* = 60
  BreakJitterPx* = 30
  SoundLifeTicks* = 24
  StepSoundEveryTicks* = 24
  PushSoundEveryTicks* = 12

  # ---- heartbeat bands, in pixels ----------------------------------------
  BandBurningPx* = 120
  BandHotPx* = 260
  BandWarmPx* = 450
  BandCoolPx* = 750

  # ---- string caps, in RUNES (never bytes) -------------------------------
  MaxNoteRunes* = 140
  MaxSayRunes* = 32
  MaxCrateIdRunes* = 4
  MaxPolicyRunes* = 48
  MaxDetailRunes* = 200
  MaxPromptRunes* = 4000

type
  LanternError* = object of CatchableError

  Team* = enum
    tmMoth = "Moth"
    tmOwl = "Owl"

  Role* = enum
    roHider = "hider"
    roSeeker = "seeker"

  Act* = enum
    actBuild = "build"
    actHunt = "hunt"

  CrateState* = enum
    csLoose = "loose"
    csLocked = "locked"
    csBroken = "broken"

  SoundKind* = enum
    sndStep = "step"
    sndPush = "push"
    sndBreak = "break"

  Band* = enum
    bdCold = "cold"
    bdCool = "cool"
    bdWarm = "warm"
    bdHot = "hot"
    bdBurning = "burning"

  Intent* = enum
    ## Hider intents first, then seeker intents; `legalFor` gates them.
    inPush = "push"
    inLock = "lock"
    inHide = "hide"
    inFlee = "flee"
    inScout = "scout"
    inWait = "wait"
    inSweep = "sweep"
    inBeeline = "beeline"
    inChase = "chase"
    inPry = "pry"
    inHold = "hold"

  AimMode* = enum
    amSweep = "sweep"
    amHold = "hold"
    amTrack = "track"
    amTarget = "target"

  OrderSource* = enum
    osLlm = "llm"
    osScripted = "scripted"
    osFallback = "fallback"

  FallbackCause* = enum
    fcTimeout = "timeout"
    fcParseError = "parse_error"
    fcTransportError = "transport_error"
    fcNoCredentials = "no_credentials"
    fcBudgetGuard = "budget_guard"

  ScriptKind* = enum
    skNone = "none"
    skWarden = "warden"
    skMoth = "moth"

  EndReason* = enum
    erComplete = "complete"
    erDeadline = "deadline"
    erFault = "fault"

  EndRule* = enum
    edFullTime = "full_time"
    edWallClock = "wall_clock"
    edSimFault = "sim_fault"
    edHostError = "host_error"

  Point* = object
    x*, y*: int

  Rect* = object
    x*, y*, w*, h*: int

  Nook* = object
    anchor*: Point
    openA*, openB*: Point

  MapSpec* = object
    name*: string
    width*, height*: int
    obstacles*: seq[Rect]
    pen*: Rect
    door*: Rect
    hiderSpawns*: seq[Point]
    seekerSpawns*: seq[Point]
    caughtPen*: Point
    crates*: seq[Point]
    nooks*: seq[Nook]
    sweepLanes*: seq[seq[Point]]
    farCorner*: Point
    raw*: JsonNode          ## the map file verbatim, pinned into the replay

  Order* = object
    intent*: Intent
    target*: Point
    crate*: int             ## crate index, or -1 for none
    aim*: AimMode
    crawl*: bool
    note*: string
    say*: string

  Control* = object
    ## The determinism boundary: the sim consumes only these four bytes per
    ## cog per tick, and the replay records only these four bytes.
    moveX*, moveY*: int8    ## -100 .. 100
    aimTurn*: int8          ## clamped to +/- AimTurnRate
    action*: uint8          ## bit0 lock, bit1 pry, bit2 crawl

  Cog* = object
    x*, y*: int             ## sub-pixel position, MotionScale per pixel
    vx*, vy*: int
    aim*: int               ## brads, 0 .. 255
    crawling*: bool
    found*: bool
    foundTick*: int
    foundBy*: int           ## the seeker's slot; only meaningful once `found`
    foundMode*: string      ## "beam" or "tag"; only meaningful once `found`
    hiddenTicks*: int
    locksUsed*: int
    lockTarget*, lockProgress*: int
    pryTarget*, pryProgress*: int
    litStreak*: int
    band*: Band
    finds*: int
    cratesPushed*, cratesLocked*, cratesBroken*: int
    lastStepSoundTick*: int
    unstickRot*: int        ## eighths of a turn added by the unstick rule
    unstickAnchorX*, unstickAnchorY*: int
    unstickTick*: int
    lastLit*: Point         ## seekers: newest lit hider position
    lastLitTick*: int
    order*: Order
    orderSource*: OrderSource
    hasOrder*: bool
    memo*: array[4, int]   ## scratch for the scripted baselines, cleared on a half reset

  Crate* = object
    c*: Point               ## CENTRE, in pixels; the box is 48 x 48 about it
    state*: CrateState
    lastPushTick*: int

  SoundRing* = object
    kind*: SoundKind
    at*: Point              ## already jittered: a place, not a point
    radius*: int
    tick*: int

  Keyframe* = object
    t*: int
    digest*: uint32
    cogs*: seq[array[4, int]]    ## x, y, aim, state code
    crates*: seq[array[3, int]]  ## x, y, state code
    hb*: seq[int]                ## the three seekers' heartbeat bands
    hid*: seq[int]               ## the six hidden-tick counters

  Pcg32* = object
    state*, inc*: uint64

  PlayerConfig* = object
    name*: string
    team*: int              ## 0 Moth, 1 Owl, -1 = derive from slot parity

  GameConfig* = object
    tokens*: seq[string]
    players*: seq[PlayerConfig]
    numAgents*: int
    seed*: int
    prepTicks*: int
    huntTicks*: int
    turnTicks*: int
    halves*: int
    turnBudgetMs*: int
    wallClockBudgetMs*: int
    playerConnectTimeoutMs*: int
    attempt1Ms*: int
    attempt2Ms*: int
    lanternRangePx*: int
    lanternConeBrads*: int
    visionBubblePx*: int
    crateCount*: int
    lockTicks*: int
    pryTicks*: int
    lockOnTicks*: int
    maxLocksPerHider*: int
    mapPath*: string
    showPlayerLabels*: bool
    gameOverTicks*: int
    episodeTimeoutMs*: int
    shutdownGraceMs*: int
    model*: string
    maxOutputTokens*: int

  Sim* = ref object
    config*: GameConfig
    map*: MapSpec
    tick*: int
    cogs*: seq[Cog]
    crates*: seq[Crate]
    sounds*: seq[SoundRing]
    rng*: Pcg32
    doorSolid*: bool
    wallMask*: seq[uint8]   ## pixel resolution: outer wall, obstacles, pen shell
    staticGrid*: seq[uint8] ## FovCell resolution: wallMask alone, baked once
    blockGrid*: seq[uint8]  ## FovCell resolution: wallMask + door + live crates
    blockDirty*: bool
    huntTicksPlayed*: array[2, int]
    actEnded*: array[2, bool]   ## the hunt act of this half stopped early
    controls*: seq[Control] ## tick-major, `numAgents` entries per tick
    keyframes*: seq[Keyframe]
    events*: seq[JsonNode]
    finished*: bool
    endReason*: EndReason
    endRule*: EndRule

# ---------------------------------------------------------------------------
# Small integer helpers used all over the step.
# ---------------------------------------------------------------------------

proc clampInt*(value, low, high: int): int {.inline.} =
  if value < low: low elif value > high: high else: value

proc absInt*(value: int): int {.inline.} =
  if value < 0: -value else: value

proc signInt*(value: int): int {.inline.} =
  if value > 0: 1 elif value < 0: -1 else: 0

proc intRoot*(value: int): int =
  ## Integer square root by Newton iteration. Named so the no-trigonometry
  ## source guard in tests/test_vision.nim does not have to special-case a
  ## legitimate `sqrt` (there is no floating-point root anywhere in the sim).
  if value <= 0:
    return 0
  var guess = value
  var next = (guess + 1) div 2
  while next < guess:
    guess = next
    next = (guess + value div guess) div 2
  guess

proc dist2*(ax, ay, bx, by: int): int {.inline.} =
  let dx = ax - bx
  let dy = ay - by
  dx * dx + dy * dy

proc distPx*(ax, ay, bx, by: int): int {.inline.} =
  intRoot(dist2(ax, ay, bx, by))

const
  UnitScale* = 1024
  UnitTable*: array[256, Point] = [
    Point(x: 1024, y: 0), Point(x: 1024, y: 25), Point(x: 1023, y: 50), Point(x: 1021, y: 75),
    Point(x: 1019, y: 100), Point(x: 1016, y: 125), Point(x: 1013, y: 150), Point(x: 1009, y: 175),
    Point(x: 1004, y: 200), Point(x: 999, y: 224), Point(x: 993, y: 249), Point(x: 987, y: 273),
    Point(x: 980, y: 297), Point(x: 972, y: 321), Point(x: 964, y: 345), Point(x: 955, y: 369),
    Point(x: 946, y: 392), Point(x: 936, y: 415), Point(x: 926, y: 438), Point(x: 915, y: 460),
    Point(x: 903, y: 483), Point(x: 891, y: 505), Point(x: 878, y: 526), Point(x: 865, y: 548),
    Point(x: 851, y: 569), Point(x: 837, y: 590), Point(x: 822, y: 610), Point(x: 807, y: 630),
    Point(x: 792, y: 650), Point(x: 775, y: 669), Point(x: 759, y: 688), Point(x: 742, y: 706),
    Point(x: 724, y: 724), Point(x: 706, y: 742), Point(x: 688, y: 759), Point(x: 669, y: 775),
    Point(x: 650, y: 792), Point(x: 630, y: 807), Point(x: 610, y: 822), Point(x: 590, y: 837),
    Point(x: 569, y: 851), Point(x: 548, y: 865), Point(x: 526, y: 878), Point(x: 505, y: 891),
    Point(x: 483, y: 903), Point(x: 460, y: 915), Point(x: 438, y: 926), Point(x: 415, y: 936),
    Point(x: 392, y: 946), Point(x: 369, y: 955), Point(x: 345, y: 964), Point(x: 321, y: 972),
    Point(x: 297, y: 980), Point(x: 273, y: 987), Point(x: 249, y: 993), Point(x: 224, y: 999),
    Point(x: 200, y: 1004), Point(x: 175, y: 1009), Point(x: 150, y: 1013), Point(x: 125, y: 1016),
    Point(x: 100, y: 1019), Point(x: 75, y: 1021), Point(x: 50, y: 1023), Point(x: 25, y: 1024),
    Point(x: 0, y: 1024), Point(x: -25, y: 1024), Point(x: -50, y: 1023), Point(x: -75, y: 1021),
    Point(x: -100, y: 1019), Point(x: -125, y: 1016), Point(x: -150, y: 1013), Point(x: -175, y: 1009),
    Point(x: -200, y: 1004), Point(x: -224, y: 999), Point(x: -249, y: 993), Point(x: -273, y: 987),
    Point(x: -297, y: 980), Point(x: -321, y: 972), Point(x: -345, y: 964), Point(x: -369, y: 955),
    Point(x: -392, y: 946), Point(x: -415, y: 936), Point(x: -438, y: 926), Point(x: -460, y: 915),
    Point(x: -483, y: 903), Point(x: -505, y: 891), Point(x: -526, y: 878), Point(x: -548, y: 865),
    Point(x: -569, y: 851), Point(x: -590, y: 837), Point(x: -610, y: 822), Point(x: -630, y: 807),
    Point(x: -650, y: 792), Point(x: -669, y: 775), Point(x: -688, y: 759), Point(x: -706, y: 742),
    Point(x: -724, y: 724), Point(x: -742, y: 706), Point(x: -759, y: 688), Point(x: -775, y: 669),
    Point(x: -792, y: 650), Point(x: -807, y: 630), Point(x: -822, y: 610), Point(x: -837, y: 590),
    Point(x: -851, y: 569), Point(x: -865, y: 548), Point(x: -878, y: 526), Point(x: -891, y: 505),
    Point(x: -903, y: 483), Point(x: -915, y: 460), Point(x: -926, y: 438), Point(x: -936, y: 415),
    Point(x: -946, y: 392), Point(x: -955, y: 369), Point(x: -964, y: 345), Point(x: -972, y: 321),
    Point(x: -980, y: 297), Point(x: -987, y: 273), Point(x: -993, y: 249), Point(x: -999, y: 224),
    Point(x: -1004, y: 200), Point(x: -1009, y: 175), Point(x: -1013, y: 150), Point(x: -1016, y: 125),
    Point(x: -1019, y: 100), Point(x: -1021, y: 75), Point(x: -1023, y: 50), Point(x: -1024, y: 25),
    Point(x: -1024, y: 0), Point(x: -1024, y: -25), Point(x: -1023, y: -50), Point(x: -1021, y: -75),
    Point(x: -1019, y: -100), Point(x: -1016, y: -125), Point(x: -1013, y: -150), Point(x: -1009, y: -175),
    Point(x: -1004, y: -200), Point(x: -999, y: -224), Point(x: -993, y: -249), Point(x: -987, y: -273),
    Point(x: -980, y: -297), Point(x: -972, y: -321), Point(x: -964, y: -345), Point(x: -955, y: -369),
    Point(x: -946, y: -392), Point(x: -936, y: -415), Point(x: -926, y: -438), Point(x: -915, y: -460),
    Point(x: -903, y: -483), Point(x: -891, y: -505), Point(x: -878, y: -526), Point(x: -865, y: -548),
    Point(x: -851, y: -569), Point(x: -837, y: -590), Point(x: -822, y: -610), Point(x: -807, y: -630),
    Point(x: -792, y: -650), Point(x: -775, y: -669), Point(x: -759, y: -688), Point(x: -742, y: -706),
    Point(x: -724, y: -724), Point(x: -706, y: -742), Point(x: -688, y: -759), Point(x: -669, y: -775),
    Point(x: -650, y: -792), Point(x: -630, y: -807), Point(x: -610, y: -822), Point(x: -590, y: -837),
    Point(x: -569, y: -851), Point(x: -548, y: -865), Point(x: -526, y: -878), Point(x: -505, y: -891),
    Point(x: -483, y: -903), Point(x: -460, y: -915), Point(x: -438, y: -926), Point(x: -415, y: -936),
    Point(x: -392, y: -946), Point(x: -369, y: -955), Point(x: -345, y: -964), Point(x: -321, y: -972),
    Point(x: -297, y: -980), Point(x: -273, y: -987), Point(x: -249, y: -993), Point(x: -224, y: -999),
    Point(x: -200, y: -1004), Point(x: -175, y: -1009), Point(x: -150, y: -1013), Point(x: -125, y: -1016),
    Point(x: -100, y: -1019), Point(x: -75, y: -1021), Point(x: -50, y: -1023), Point(x: -25, y: -1024),
    Point(x: 0, y: -1024), Point(x: 25, y: -1024), Point(x: 50, y: -1023), Point(x: 75, y: -1021),
    Point(x: 100, y: -1019), Point(x: 125, y: -1016), Point(x: 150, y: -1013), Point(x: 175, y: -1009),
    Point(x: 200, y: -1004), Point(x: 224, y: -999), Point(x: 249, y: -993), Point(x: 273, y: -987),
    Point(x: 297, y: -980), Point(x: 321, y: -972), Point(x: 345, y: -964), Point(x: 369, y: -955),
    Point(x: 392, y: -946), Point(x: 415, y: -936), Point(x: 438, y: -926), Point(x: 460, y: -915),
    Point(x: 483, y: -903), Point(x: 505, y: -891), Point(x: 526, y: -878), Point(x: 548, y: -865),
    Point(x: 569, y: -851), Point(x: 590, y: -837), Point(x: 610, y: -822), Point(x: 630, y: -807),
    Point(x: 650, y: -792), Point(x: 669, y: -775), Point(x: 688, y: -759), Point(x: 706, y: -742),
    Point(x: 724, y: -724), Point(x: 742, y: -706), Point(x: 759, y: -688), Point(x: 775, y: -669),
    Point(x: 792, y: -650), Point(x: 807, y: -630), Point(x: 822, y: -610), Point(x: 837, y: -590),
    Point(x: 851, y: -569), Point(x: 865, y: -548), Point(x: 878, y: -526), Point(x: 891, y: -505),
    Point(x: 903, y: -483), Point(x: 915, y: -460), Point(x: 926, y: -438), Point(x: 936, y: -415),
    Point(x: 946, y: -392), Point(x: 955, y: -369), Point(x: 964, y: -345), Point(x: 972, y: -321),
    Point(x: 980, y: -297), Point(x: 987, y: -273), Point(x: 993, y: -249), Point(x: 999, y: -224),
    Point(x: 1004, y: -200), Point(x: 1009, y: -175), Point(x: 1013, y: -150), Point(x: 1016, y: -125),
    Point(x: 1019, y: -100), Point(x: 1021, y: -75), Point(x: 1023, y: -50), Point(x: 1024, y: -25)
  ]
    ## Unit vectors at 1/1024, MATHS orientation (x east, y NORTH), one per
    ## brad. Generated once by scripts/art/gen_unit_table.py and committed, so
    ## the sim needs no sine or cosine at run time or at compile time.

proc unitBrad*(brad: int): Point {.inline.} =
  UnitTable[brad and 255]

proc aimVector*(brad: int): Point {.inline.} =
  ## The aim direction in SCREEN orientation (+y down), at 1/1024.
  let u = UnitTable[brad and 255]
  Point(x: u.x, y: -u.y)

proc bearingBrads*(dx, dy: int): int =
  ## The brad heading of the screen-space vector (dx, dy), counted
  ## counter-clockwise from east. Integer bisection against `UnitTable`;
  ## there is no atan2 in this repository.
  if dx == 0 and dy == 0:
    return 0
  let vx = dx
  let vy = -dy                     ## screen down -> maths up
  var low, high: int
  if vy >= 0:
    if vx >= 0: (low, high) = (0, 64)
    else: (low, high) = (64, 128)
  else:
    if vx < 0: (low, high) = (128, 192)
    else: (low, high) = (192, 256)
  while high - low > 1:
    let mid = (low + high) div 2
    let s = UnitTable[mid and 255]
    if s.x * vy - s.y * vx > 0:
      low = mid
    else:
      high = mid
  let sl = UnitTable[low and 255]
  let sh = UnitTable[high and 255]
  let cl = absInt(sl.x * vy - sl.y * vx)
  let ch = absInt(sh.x * vy - sh.y * vx)
  (if cl <= ch: low else: high) and 255

proc bradDelta*(a, b: int): int {.inline.} =
  ## The signed shortest turn from `b` to `a`, in -128 .. 127.
  ((a - b + 128) and 255) - 128

proc scaleTo*(dx, dy, length: int): Point =
  ## `u(v) * length` in integers: the design note's unit-vector operator.
  ## A zero vector stays zero rather than exploding.
  let len = intRoot(dx * dx + dy * dy)
  if len == 0:
    return Point(x: 0, y: 0)
  Point(x: dx * length div len, y: dy * length div len)
