## Join a validated macro order to the actual physical controls it executed.
import std/[json, options]
import bitworld/decision_trajectory
import types, sim, decision, orders, replay

type
  PendingMacro* = object
    seat*, startTick*: int
    decision*: Decision
  CompletedMacro* = object
    pending*: PendingMacro
    execution*: Option[ExecutionEvidence]
    terminal*: bool

proc collectMacros*(sim: Sim, pending: var seq[PendingMacro], terminal = false):
    seq[CompletedMacro] =
  for issued in pending:
    var controls: seq[Control]
    for tick in issued.startTick ..< sim.tick:
      controls.add(sim.controls[tick * sim.seats + issued.seat])
    result.add(CompletedMacro(pending: issued, terminal: terminal,
      execution: (if sim.tick == issued.startTick: none(ExecutionEvidence)
        else: some(ExecutionEvidence(startTick: issued.startTick, endTick: sim.tick,
          tickHz: TargetFps, seatControlsBase64: encodeControls(controls))))))
  pending.setLen(0)

proc recordMacro*(trajectory: DecisionTrajectory, completed: CompletedMacro) =
  let issued = completed.pending
  let accepted = issued.decision.selectedAttemptId.isSome
  trajectory.recordDecision($issued.startTick & "-" & $issued.seat,
    $issued.seat, issued.decision.observation, issued.decision.attempts,
    issued.decision.selectedAttemptId, orderJson(issued.decision.order),
    (if accepted: asAccepted else: asFallback), completed.terminal,
    (if accepted: none(string) else: some("engine-" & $issued.decision.source)),
    completed.execution)

proc recordMacros*(trajectory: DecisionTrajectory, sim: Sim,
    pending: var seq[PendingMacro], terminal = false) =
  for completed in collectMacros(sim, pending, terminal):
    trajectory.recordMacro(completed)
