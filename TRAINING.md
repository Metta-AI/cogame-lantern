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
quality. Lantern's target coordinates, crate selection, aim, crawl, and text
exceed the current fixed discrete action bridge for Metta RL and PufferLib.
