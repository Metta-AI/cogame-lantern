"""Verify teacher variants retain the runtime seed family."""

import json
import subprocess
import sys
import tempfile
from pathlib import Path

root = Path(__file__).resolve().parents[1]
exporter = str(Path(sys.argv[1]).resolve())
with tempfile.TemporaryDirectory() as directory:
    for variant in ("default", "sprint"):
        output = Path(directory) / variant
        subprocess.run([exporter, str(output), "10", "1", variant, "source-test"], cwd=root, check=True)
        events = [json.loads(line) for line in (output / "trajectories.jsonl").read_text().splitlines()]
        episodes = [event for event in events if event["event_type"] == "episode"]
        assert len(episodes) == 10
        assert {event["seed_family"] for event in episodes} == {f"lantern-{seed}" for seed in range(1, 11)}
        assert all(event["game"] == "lantern" for event in episodes)
        for name in ("train.jsonl", "validation.jsonl"):
            rows = [json.loads(line) for line in (output / name).read_text().splitlines()]
            assert all(row["seed"] == "lantern-" + row["episode_id"].rsplit("-", 1)[1] for row in rows)
