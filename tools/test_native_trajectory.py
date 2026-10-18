"""Actual game and six player sockets against a local native HTTP fixture."""

import argparse
import base64
import contextlib
import hashlib
import http.server
import json
import os
import socket
import subprocess
import tempfile
import threading
import time
import uuid
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parents[1]
flows = (
    "accepted",
    "invalid",
    "sampled",
    "tempered",
    "temperature-mismatch",
    "greedy-null",
    "greedy-tokens",
    "provider-error",
    "malformed-json",
    "malformed-schema",
    "invalid-token-types",
    "large-metadata",
)
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("game", type=Path)
parser.add_argument("player", type=Path)
parser.add_argument("output", type=Path, nargs="?")
parser.add_argument("--flow", choices=flows)
parser.add_argument("--variant", choices=("default", "sprint"))
parser.add_argument(
    "--wording",
    default="canonical",
    choices=(
        "canonical",
        "plain",
        "numbered",
        "questions",
        "reordered",
        "heldout-briefing",
        "heldout-reference",
        "mixed",
    ),
)
parser.add_argument("--prompt-seed", type=int, default=0)
args = parser.parse_args()
GAME, PLAYER = str(args.game.resolve()), str(args.player.resolve())
for flow in (args.flow,) if args.flow else flows:
    calls = {}

    class Provider(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            assert self.path == "/config"
            encoded = json.dumps(config).encode()
            self.send_response(200)
            self.send_header("Content-Length", str(len(encoded)))
            self.end_headers()
            self.wfile.write(encoded)

        def do_POST(self):
            request = json.loads(self.rfile.read(int(self.headers["content-length"])))
            slot = int(self.headers["X-Coworld-Player-Slot"])
            assert self.path == "/v1/messages" and slot in range(6)
            assert request["temperature"] == (
                1
                if flow in {"sampled", "large-metadata"}
                else 0.4
                if flow in {"tempered", "temperature-mismatch"}
                else 0
            )
            text = (
                "private-invalid-response"
                if flow == "invalid" and slot == 0
                else '{"intent":"wait"}'
            )
            call_id = str(uuid.uuid4())
            body: dict[str, Any] = {
                "id": "msg_" + call_id,
                "model": "fixture/served",
                "stop_reason": "end_turn",
                "content": [{"type": "text", "text": text}],
                "usage": {"input_tokens": 17, "output_tokens": 5},
            }
            if flow == "greedy-null":
                body["sampling_evidence"] = None
            if flow in {
                "sampled",
                "tempered",
                "temperature-mismatch",
                "greedy-tokens",
                "large-metadata",
            }:
                body["sampling_evidence"] = {
                    "policy_revision": "a" * 64,
                    "tokenizer_revision": "b" * 64,
                    "chat_template": "fixture-template",
                    "sampling": "full_softmax_temperature_one"
                    if flow in {"sampled", "large-metadata"}
                    else "full_softmax"
                    if flow in {"tempered", "temperature-mismatch"}
                    else "greedy",
                    "enable_thinking": False,
                    "max_new_tokens": request["max_tokens"],
                    "max_sequence_length": 32768 + request["max_tokens"]
                    if flow == "large-metadata"
                    else 4096,
                    "sampling_seed": 7,
                    "eos_token_ids": [4],
                    "prompt_token_ids": list(range(32768))
                    if flow == "large-metadata"
                    else [1, 2],
                    "completion_token_ids": [3, 4],
                    "behavior_log_probs": [-0.5, -0.3]
                    if flow
                    in {"sampled", "tempered", "temperature-mismatch", "large-metadata"}
                    else None,
                    "stop_reason": "eos",
                    "response": text,
                }
                if flow in {"tempered", "temperature-mismatch"}:
                    body["sampling_evidence"]["temperature"] = (
                        0.4 if flow == "tempered" else 1
                    )
            if flow == "provider-error" and slot == 0:
                body = {"error": {"message": "private-provider-error"}}
            if flow == "malformed-schema" and slot == 0:
                body["sampling_evidence"] = {
                    "private-schema-sentinel": "must-stay-private"
                }
            if flow == "invalid-token-types" and slot == 0:
                body["sampling_evidence"] = {
                    "prompt_token_ids": ["private-token-sentinel"],
                    "completion_token_ids": [4],
                    "behavior_log_probs": ["private-probability-sentinel"],
                    "stop_reason": "eos",
                }
            calls[call_id] = (request, body)
            encoded = (
                b'{"private-json-sentinel":"must-stay-private"'
                if flow == "malformed-json" and slot == 0
                else json.dumps(body).encode()
            )
            self.send_response(429 if flow == "provider-error" and slot == 0 else 200)
            self.send_header("content-type", "application/json")
            self.send_header("content-length", str(len(encoded)))
            self.send_header("X-Softmax-Llm-Call-Id", call_id)
            if flow in {
                "sampled",
                "tempered",
                "temperature-mismatch",
                "greedy-tokens",
                "large-metadata",
            }:
                self.send_header("X-Coworld-Checkpoint-Sha256", "a" * 64)
                self.send_header("X-Coworld-Tokenizer-Sha256", "b" * 64)
                self.send_header("X-Coworld-Chat-Template-Sha256", "c" * 64)
            self.end_headers()
            self.wfile.write(encoded)

        def log_message(self, *_args):
            pass

    provider = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Provider)
    threading.Thread(target=provider.serve_forever, daemon=True).start()
    if args.output is not None:
        target = args.output.resolve() / flow
        target.mkdir(parents=True, mode=0o700, exist_ok=False)
        output_context = contextlib.nullcontext(target)
    else:
        output_context = tempfile.TemporaryDirectory()
    with output_context as directory:
        output = Path(directory)
        with socket.socket() as reserve:
            reserve.bind(("127.0.0.1", 0))
            port = reserve.getsockname()[1]
        config = {
            "num_agents": 6,
            "seed": 7,
            "halves": 2,
            "tokens": ["t" + str(i) for i in range(6)],
            "prepTicks": 24,
            "huntTicks": 48,
            "turnTicks": 24,
            "wallClockBudgetSeconds": 120,
            "episodeTimeoutSeconds": 180,
            "playerConnectTimeoutSeconds": 10,
            "shutdownGraceSeconds": 0,
        }
        if args.variant:
            manifest = json.loads((ROOT / "coworld_manifest_template.json").read_text())
            config.update(
                next(
                    v["game_config"]
                    for v in manifest["variants"]
                    if v["id"] == args.variant
                )
            )
        config.update(promptVariant=args.wording, promptSeed=args.prompt_seed)
        expected_ticks = config["halves"] * (config["prepTicks"] + config["huntTicks"])
        (output / "config.json").write_text(json.dumps(config))
        env = {
            **os.environ,
            "COGAME_HOST": "127.0.0.1",
            "COGAME_PORT": str(port),
            "COGAME_CONFIG_URI": f"http://127.0.0.1:{provider.server_port}/config",
            "COGAME_RESULTS_URI": (output / "results.json").as_uri(),
            "COGAME_SAVE_REPLAY_URI": (output / "replay.json").as_uri(),
            "COGAME_SAVE_TRAJECTORY_URI": (output / "trajectory.jsonl").as_uri(),
            "COWORLD_EPISODE_ID": str(uuid.uuid4()),
            "COWORLD_GAME_VERSION": "native-fixture-v1",
            "COWORLD_SOURCE_REVISION": (
                os.environ["COWORLD_TEST_SOURCE_REVISION"]
                if "COWORLD_TEST_SOURCE_REVISION" in os.environ
                else subprocess.check_output(
                    ["git", "rev-parse", "HEAD"], cwd=ROOT, text=True
                ).strip()
            ),
            "COWORLD_LLM_ENDPOINT": f"http://127.0.0.1:{provider.server_port}",
            "COWORLD_LLM_MODEL": "fixture/requested",
            "COWORLD_LLM_TEMPERATURE": "1"
            if flow in {"sampled", "large-metadata"}
            else ".4"
            if flow in {"tempered", "temperature-mismatch"}
            else "0",
            "PLAYER_PROMPT": "private-guidance-fixture",
            "PLAYER_SCRIPTED": "",
        }
        processes, logs = [], []
        try:
            log = (output / "game.log").open("w")
            logs.append(log)
            processes.append(
                subprocess.Popen([GAME], cwd=ROOT, env=env, stdout=log, stderr=log)
            )
            for _ in range(100):
                if processes[0].poll() is not None:
                    raise AssertionError((output / "game.log").read_text())
                with socket.socket() as check:
                    if check.connect_ex(("127.0.0.1", port)) == 0:
                        break
                time.sleep(0.05)
            else:
                raise AssertionError("game socket never opened")
            for slot in range(6):
                log = (output / f"player{slot}.log").open("w")
                logs.append(log)
                player_env = {
                    **env,
                    "COWORLD_PLAYER_WS_URL": f"ws://127.0.0.1:{port}/player?slot={slot}&token=t{slot}",
                }
                processes.append(
                    subprocess.Popen(
                        [PLAYER], cwd=ROOT, env=player_env, stdout=log, stderr=log
                    )
                )
            for process in processes:
                assert process.wait(timeout=config["episodeTimeoutSeconds"] + 30) == 0
            for log in logs:
                log.flush()
            events = [
                json.loads(line)
                for line in (output / "trajectory.jsonl").read_text().splitlines()
            ]
            decisions, episode = events[:-1], events[-1]
            assert (
                episode["status"] == "completed"
                and episode["outcome"]["final_tick"] == expected_ticks
            )
            captures = episode["outcome"]["runtime_inputs"]
            assert len(captures) == 1 and captures[0]["uri"] == env["COGAME_CONFIG_URI"]
            assert captures[0]["transport"]["response_reader_joined"] is True
            assert (
                json.loads(
                    base64.b64decode(captures[0]["transport"]["response_body_b64"])
                )
                == config
            )
            assert "runtime_inputs" not in (output / "results.json").read_text()
            assert (output / "trajectory.jsonl").stat().st_mode & 0o777 == 0o600
            replay = json.loads((output / "replay.json").read_text())
            controls = base64.b64decode(replay["controls_b64"])
            assert len(controls) == expected_ticks * 6 * 4
            seen = set()
            for decision in decisions:
                selection = decision["observation"]["prompt_selection"]
                resolved = (
                    ("canonical", "plain", "numbered", "questions", "reordered")[
                        args.prompt_seed % 5
                    ]
                    if args.wording == "mixed"
                    else args.wording
                )
                assert selection == {
                    "bank": "lantern-rules-v1",
                    "selection": args.wording,
                    "variant": resolved,
                    "seed": args.prompt_seed,
                }
                execution = decision["execution"]
                slot = int(decision["seat"])
                assert (
                    execution["tick_hz"] == 24
                    and execution["control_encoding"] == "i8-i8-i8-u8"
                )
                actual = b"".join(
                    controls[(tick * 6 + slot) * 4 : (tick * 6 + slot + 1) * 4]
                    for tick in range(execution["start_tick"], execution["end_tick"])
                )
                assert base64.b64decode(execution["seat_controls_b64"]) == actual
                for attempt in decision["attempts"]:
                    if attempt["prompt"]:
                        hashes = next(
                            h["prompt_template"]
                            for h in decision["observation"]["prompt_hashes"]
                            if h["attempt_id"] == attempt["attempt_id"]
                        )
                        assert hashes == {
                            **selection,
                            "system_sha256": hashlib.sha256(
                                attempt["prompt"][0]["content"].encode()
                            ).hexdigest(),
                            "user_sha256": hashlib.sha256(
                                attempt["prompt"][1]["content"].encode()
                            ).hexdigest(),
                        }
                    assert attempt["inference_mode"] == "text_action"
                    if attempt["platform_call_id"] is None:
                        continue
                    call_id = attempt["platform_call_id"]
                    assert call_id not in seen
                    seen.add(call_id)
                    request, body = calls[call_id]
                    assert attempt["request"] == request
                    if flow == "malformed-json" and slot == 0:
                        assert "private-json-sentinel" in attempt["raw_response"]
                    else:
                        assert json.loads(attempt["raw_response"]) == body
                    assert (
                        attempt["response_complete"] is True
                        and attempt["response_reader_joined"] is True
                    )
                    assert (
                        attempt["response_headers_b64"] and attempt["response_body_b64"]
                    )
                    assert (
                        base64.b64decode(attempt["response_body_b64"]).decode()
                        == attempt["raw_response"]
                    )
                    assert attempt["prompt"][0]["content"] == request["system"]
                    assert (
                        attempt["prompt"][1]["content"]
                        == request["messages"][0]["content"]
                    )
                    if "model" in body and not (flow == "malformed-json" and slot == 0):
                        assert attempt["model"] == "fixture/served"
                    if "usage" in body and not (flow == "malformed-json" and slot == 0):
                        assert (
                            attempt["input_tokens"] == 17
                            and attempt["output_tokens"] == 5
                        )
                    if flow == "invalid-token-types" and slot == 0:
                        assert (
                            attempt["prompt_token_ids"] is None
                            and attempt["behavior_logprobs"] is None
                        )
                    if flow == "large-metadata":
                        assert attempt["prompt_token_ids"] == list(range(32768))
                        assert attempt["sampled_token_ids"] == [3, 4] and attempt[
                            "behavior_logprobs"
                        ] == [-0.5, -0.3]
                    if flow in {"greedy-tokens", "temperature-mismatch"}:
                        assert not attempt["accepted"]
                        assert (
                            attempt["sampled_token_ids"] is None
                            and attempt["behavior_logprobs"] is None
                        )
                    if flow == "tempered":
                        assert attempt["sampled_token_ids"] == [3, 4] and attempt[
                            "behavior_logprobs"
                        ] == [-0.5, -0.3]
                        assert (
                            body["sampling_evidence"]["temperature"]
                            == attempt["request"]["temperature"]
                        )
                if decision["action_status"] == "accepted":
                    selected = next(
                        a
                        for a in decision["attempts"]
                        if a["attempt_id"] == decision["selected_attempt_id"]
                    )
                    assert (
                        selected["accepted"]
                        and selected["parsed_action"] == decision["executed_action"]
                    )
                else:
                    assert decision["selected_attempt_id"] is None
            assert seen == set(calls)
            public = (output / "replay.json").read_text() + "".join(
                (output / p).read_text()
                for p in ["game.log", *(f"player{i}.log" for i in range(6))]
            )
            for secret in (
                "private-guidance-fixture",
                "private-invalid-response",
                "private-provider-error",
                "private-json-sentinel",
                "private-schema-sentinel",
                "private-token-sentinel",
                "private-probability-sentinel",
            ):
                assert secret not in public
            if flow == "invalid":
                assert any(
                    d["action_status"] == "fallback" and len(d["attempts"]) == 2
                    for d in decisions
                )
            if flow in {
                "provider-error",
                "malformed-json",
                "malformed-schema",
                "invalid-token-types",
                "greedy-tokens",
                "temperature-mismatch",
            }:
                assert any(
                    d["action_status"] == "fallback" and len(d["attempts"]) == 1
                    for d in decisions
                )
            print(
                flow,
                len(decisions),
                "macros",
                len(calls),
                "native fixture joins",
                flush=True,
            )
        finally:
            for process in processes:
                if process.poll() is None:
                    process.terminate()
                    process.wait(timeout=5)
            for log in logs:
                log.close()
    provider.shutdown()
