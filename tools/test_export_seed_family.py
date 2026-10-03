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
        assert not (output / "train.jsonl").exists() and not (output / "validation.jsonl").exists()
        decisions = [event for event in events if event["event_type"] == "decision"]
        assert decisions and all(event["game"] == "lantern" for event in decisions)
        for decision in decisions:
            for attempt in decision["attempts"]:
                assert attempt["origin"] == "teacher"
                for key in ("model", "request", "raw_response", "decoder", "platform_call_id",
                            "response_headers", "provider_request_id", "response_body_b64",
                            "response_headers_b64", "response_complete", "response_reader_joined", "http_status"):
                    assert attempt[key] is None
