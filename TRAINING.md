# Lantern training

Lantern has a local simulator and hosted text players. Export complete matches
for Metta post-training with the same per-seat view, prompt, and order parser as
the hosted player:

```bash
nimby sync nimby.lock
nim r -d:release --path:src tools/export_posttrain.nim /private/lantern-default 10 1 default SOURCE_GAME_VERSION plain 0
nim r -d:release --path:src tools/export_posttrain.nim /private/lantern-sprint 10 1 sprint SOURCE_GAME_VERSION mixed 3
```

The exporter reads each certified `game_config` from
`coworld_manifest_template.json`, runs ten seeded matches per variant, and
writes private canonical trajectories, per-match replay files, and `manifest.json`.
The teacher sees only each seat's private observation. Orders pass through the
hosted parser and production controller. Every replay is independently re-derived.
The exporter requires committed, clean source and refuses an existing output directory.

Candidates require independent content review. The shared importer owns training
labels and seed-family splits; wording and game variants share `lantern-SEED`
families. Source exports do not establish deployed package parity or model quality.

Set `promptVariant` and `promptSeed` in game configuration or bridge resets.
The `lantern-rules-v1` bank has five training variants: `canonical`, `plain`,
`numbered`, `questions`, and `reordered`. `mixed` resolves once per episode using
the separate prompt seed modulo five. It requires an explicit nonnegative seed.
The shared rules now use the observation's clock: the old fixed 30/75-second
claims were false for sprint's 20/45-second acts. Apart from that correction,
canonical wording remains byte-identical. Only the setting introduction varies;
mechanics, role rules, response schema, private views, and simulation randomness remain unchanged.

`heldout-briefing` and `heldout-reference` are evaluation-only variants. Training
resets and source candidate exports reject them. Private captures retain selection
metadata and hashes of actual system/user messages, including retries and late evidence.
The native player rejects a selection change within an episode.

Compare matched seeds across training and held-out wording before making performance
claims. Local scripted and HTTP-fixture checks do not establish resistance to training collapse.

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
