## Episode-scoped state helpers: the PCG32 stream, the FNV-1a state digest,
## and the log line the hosted game log is read for.
##
## Integer only — this is on the sim path.

import types

# ---------------------------------------------------------------------------
# PCG32. One stream per episode, seeded from the episode seed, used for
# exactly two things: the sound-ring jitter and `moth`'s waypoint draws.
# Everything else in the sim is deterministic without it.
# ---------------------------------------------------------------------------

const
  PcgMultiplier = 6364136223846793005'u64
  PcgDefaultInc = 1442695040888963407'u64

proc initPcg32*(seed: int, stream: uint64 = 0'u64): Pcg32 =
  result.inc = ((stream shl 1) or 1'u64) + PcgDefaultInc
  result.state = 0'u64
  result.state = result.state * PcgMultiplier + result.inc
  result.state = result.state + cast[uint64](seed)
  result.state = result.state * PcgMultiplier + result.inc

proc nextUint32*(rng: var Pcg32): uint32 =
  let old = rng.state
  rng.state = old * PcgMultiplier + rng.inc
  let xorshifted = uint32(((old shr 18'u64) xor old) shr 27'u64)
  let rot = uint32(old shr 59'u64)
  (xorshifted shr rot) or (xorshifted shl ((32'u32 - rot) and 31'u32))

proc nextRange*(rng: var Pcg32, span: int): int =
  ## Uniform-ish in 0 ..< span. `span <= 0` yields 0.
  if span <= 0:
    return 0
  int(rng.nextUint32() mod uint32(span))

proc jitter*(rng: var Pcg32, amount: int): int =
  ## A symmetric offset in -amount .. amount.
  if amount <= 0:
    return 0
  rng.nextRange(2 * amount + 1) - amount

# ---------------------------------------------------------------------------
# The state digest. Paintbot's `gameHash` idea widened to the full state: it
# goes into every keyframe and is the cross-build equality check that lets the
# wasm viewer prove it re-derived the same match.
# ---------------------------------------------------------------------------

const
  FnvOffset = 2166136261'u32
  FnvPrime = 16777619'u32

proc fnvByte*(hash: var uint32, value: uint8) {.inline.} =
  hash = hash xor uint32(value)
  hash = hash * FnvPrime

proc fnvInt*(hash: var uint32, value: int) {.inline.} =
  let raw = cast[uint64](value)
  for shift in [0, 8, 16, 24, 32, 40, 48, 56]:
    fnvByte(hash, uint8((raw shr uint64(shift)) and 0xFF'u64))

proc cogStateCode*(cog: Cog, frozen: bool): int {.inline.} =
  ## 0 active, 1 frozen in the pen, 2 crawling, 3 found.
  if cog.found: 3
  elif frozen: 1
  elif cog.crawling: 2
  else: 0

proc lanternStateDigest*(sim: Sim, frozenSeekers: bool): uint32 =
  var hash = FnvOffset
  fnvInt(hash, sim.tick)
  for cog in sim.cogs:
    fnvInt(hash, cog.x)
    fnvInt(hash, cog.y)
    fnvInt(hash, cog.vx)
    fnvInt(hash, cog.vy)
    fnvInt(hash, cog.aim)
    fnvInt(hash, cogStateCode(cog, frozenSeekers))
    fnvInt(hash, cog.hiddenTicks)
    fnvInt(hash, cog.locksUsed)
  for crate in sim.crates:
    fnvInt(hash, crate.c.x)
    fnvInt(hash, crate.c.y)
    fnvInt(hash, ord(crate.state))
  fnvInt(hash, ord(sim.doorSolid))
  hash
