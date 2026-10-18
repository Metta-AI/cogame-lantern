"""Verify teacher variants retain the runtime seed family."""

import hashlib
import json
import subprocess
import sys
import tempfile
from pathlib import Path

root = Path(__file__).resolve().parents[1]
exporter = str(Path(sys.argv[1]).resolve())
with tempfile.TemporaryDirectory() as directory:
    for variant in ("default", "sprint"):
        for wording in ("canonical", "plain", "numbered", "questions", "reordered"):
            output = Path(directory) / variant / wording
            subprocess.run(
                [
                    exporter,
                    str(output),
                    "10",
                    "1",
                    variant,
                    "source-test",
                    wording,
                    "0",
                ],
                cwd=root,
                check=True,
            )
            events = [
                json.loads(line)
                for line in (output / "trajectories.jsonl").read_text().splitlines()
            ]
            episodes = [event for event in events if event["event_type"] == "episode"]
            assert len(episodes) == 10
            assert {event["seed_family"] for event in episodes} == {
                f"lantern-{seed}" for seed in range(1, 11)
            }
            assert all(event["game"] == "lantern" for event in episodes)
            assert (
                not (output / "train.jsonl").exists()
                and not (output / "validation.jsonl").exists()
            )
            manifest = json.loads((output / "manifest.json").read_text())
            assert (
                manifest["review_required"]
                and manifest["prompt_selection"]["variant"] == wording
            )
            assert all((output / run["replay"]).is_file() for run in manifest["runs"])
            decisions = [event for event in events if event["event_type"] == "decision"]
            assert decisions and all(event["game"] == "lantern" for event in decisions)
            for decision in decisions:
                assert decision["observation"]["prompt_selection"]["variant"] == wording
                for attempt in decision["attempts"]:
                    hashes = next(
                        h["prompt_template"]
                        for h in decision["observation"]["prompt_hashes"]
                        if h["attempt_id"] == attempt["attempt_id"]
                    )
                    for role, index in (("system", 0), ("user", 1)):
                        assert (
                            hashes[role + "_sha256"]
                            == hashlib.sha256(
                                attempt["prompt"][index]["content"].encode()
                            ).hexdigest()
                        )
                    assert attempt["origin"] == "teacher"
                    for key in (
                        "model",
                        "request",
                        "raw_response",
                        "decoder",
                        "platform_call_id",
                        "response_headers",
                        "provider_request_id",
                        "response_body_b64",
                        "response_headers_b64",
                        "response_complete",
                        "response_reader_joined",
                        "http_status",
                    ):
                        assert attempt[key] is None
