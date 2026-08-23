## The two name spaces.
##
## In-game there are only aliases: `Moth-1..3` and `Owl-1..3`. Every prompt,
## every observation and every board label uses them, so a policy cannot
## meta-game a named opponent and a trio cannot be told apart by reputation.
## Real player names exist ONLY spectator-side: `results.names`,
## `replay.names.players`, and the viewer's scorebug plates.
##
## The aliases are side-NEUTRAL on purpose. A cog is not "a hider"; it is
## hiding this half and seeking the next.

import types

proc teamOfSlot*(slot: int): Team {.inline.} =
  ## Even slots are Moth, odd slots are Owl. With the platform seating
  ## champion #1 at the lowest slot and champion #2 next, the two champions
  ## land on opposite sides in every episode.
  if (slot and 1) == 0: tmMoth else: tmOwl

proc indexInTeam*(slot: int): int {.inline.} =
  slot div 2

proc aliasOfSlot*(slot: int): string =
  $teamOfSlot(slot) & "-" & $(indexInTeam(slot) + 1)

proc slotsOfTeam*(team: Team, seats: int): seq[int] =
  for slot in 0 ..< seats:
    if teamOfSlot(slot) == team:
      result.add(slot)

proc hidingTeam*(half: int): Team {.inline.} =
  ## Half 1: Moth hides, Owl seeks. Half 2: the sides swap.
  if half == 1: tmMoth else: tmOwl

proc roleOfSlot*(slot, half: int): Role {.inline.} =
  if teamOfSlot(slot) == hidingTeam(half): roHider else: roSeeker

proc hidHalfOfSlot*(slot: int): int {.inline.} =
  if teamOfSlot(slot) == tmMoth: 1 else: 2

proc teamColor*(team: Team): string =
  case team
  of tmMoth: "#f2c14e"
  of tmOwl: "#4ecdc4"
