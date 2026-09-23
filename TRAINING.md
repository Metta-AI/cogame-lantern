# Lantern training

Lantern has a local simulator and hosted text players. Export complete matches
for Metta post-training with the same per-seat view, prompt, and order parser as
the hosted player:

```bash
nimby sync nimby.lock
nim r -d:release --path:src tools/export_posttrain.nim /tmp/lantern-default 10 1 default
nim r -d:release --path:src tools/export_posttrain.nim /tmp/lantern-sprint 10 1 sprint
```

The exporter reads each certified `game_config` from
`coworld_manifest_template.json`, runs ten seeded matches per variant, and
writes `train.jsonl`, `validation.jsonl`, and `manifest.json`. Seeds divisible
by five go to validation, keeping each match entirely in one split. The
published warden and moth scripts alternate by seat. Each order passes through
the hosted parser and the production control compiler before it advances the
native simulator. The exporter refuses an existing output directory.

Train the text policy with Metta's post-training CLI:

```bash
uv run python -m metta_posttrain.train --dataset /tmp/lantern-default \
  --output /tmp/lantern-model --model Qwen/Qwen2.5-0.5B-Instruct \
  --max-steps 100 --max-length 4096
```

The dataset is imitation of scripted play; its loss does not measure policy
quality.

# Numeric training

The persistent bridge covers both certified Lantern variants. It reads each
role's exact `seatView` and exposes 573 fixed numeric features: role, clock,
map, visible crates and players, lights, sounds, and the seat's own last
order. Hider and seeker views remain separate; the bridge snapshots every
active seat's view before any order is applied. The six action heads encode
intent, target coordinates, crate, aim, and crawl. The production order
parser, control layer, and simulator execute each action. Team scores are
zero-sum between Moth and Owl.

```sh
nim c -d:release --path:src -o:/tmp/lantern-train-bridge tools/train_bridge.nim
python3 tools/test_train_bridge.py /tmp/lantern-train-bridge
```

From Metta, use `recipes.external.coworld_metta_rl.train` or
`recipes.external.coworld.train` with command
`["/tmp/lantern-train-bridge", "<source>/coworld_manifest_template.json", "default"]`
and `players=6`. Replace `default` with `sprint` for the second variant.
Set a finite timestep limit for either trainer.
