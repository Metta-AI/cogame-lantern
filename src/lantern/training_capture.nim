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

proc privateObservation*(selection: PromptSelection, view: JsonNode,
    attempts: seq[DecisionAttempt]): JsonNode =
  result = copy(view)
  result["prompt_selection"] = selection.selectionMetadata()
  var hashes = newJArray()
  for attempt in attempts:
    if attempt.prompt.len == 2:
      hashes.add(%*{"attempt_id": attempt.attemptId,
        "prompt_template": selection.promptMetadata(attempt.prompt[0]["content"].getStr(),
          attempt.prompt[1]["content"].getStr())})
  result["prompt_hashes"] = hashes

proc recordMacro*(trajectory: DecisionTrajectory, completed: CompletedMacro) =
  let issued = completed.pending
  let accepted = issued.decision.selectedAttemptId.isSome
  let metadata = issued.decision.observation["prompt_selection"]
  let selection = promptSelection(%*{"promptVariant": metadata["selection"], "promptSeed": metadata["seed"]})
  let observation = privateObservation(selection, issued.decision.observation, issued.decision.attempts)
  trajectory.recordDecision($issued.startTick & "-" & $issued.seat,
    $issued.seat, observation, issued.decision.attempts,
    issued.decision.selectedAttemptId, orderJson(issued.decision.order),
    (if accepted: asAccepted else: asFallback), completed.terminal,
    (if accepted: none(string) else: some("engine-" & $issued.decision.source)),
    completed.execution)

proc recordMacros*(trajectory: DecisionTrajectory, sim: Sim,
    pending: var seq[PendingMacro], terminal = false) =
  for completed in collectMacros(sim, pending, terminal):
    trajectory.recordMacro(completed)
