"""Exercise ordinary Jev, prompt, and scripted players on one native game."""

import json
import os
import socket
import subprocess
import sys
import tempfile
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path


def main(game_bin: str, player_bin: str) -> None:
    repo = Path(__file__).resolve().parents[2]
    manifest = json.loads((repo / "coworld_manifest_template.json").read_text())
    config = dict(manifest["certification"]["game_config"])
    config["tokens"] = [f"policy-smoke-{slot}" for slot in range(6)]
    calls: list[tuple[str, int, tuple[str, ...]]] = []

    class Handler(BaseHTTPRequestHandler):
        def do_POST(self) -> None:
            body = json.loads(self.rfile.read(int(self.headers["content-length"])))
            if self.path == "/v1/systemone":
                questions = body["questions"]
                calls.append(("jev", len(questions), tuple(questions)))
                assert self.headers["x-coworld-player-slot"] == "0"
                answers = {}
                for name, question in questions.items():
                    choices = list(question["criteria"])
                    preferred = {
                        "intent": "hide" if "hide" in choices else "sweep",
                        "target": "self",
                        "crate": "none",
                        "aim": "sweep",
                        "crawl": "no",
                        "say": "quiet",
                        "note": "quiet",
                    }[name]
                    answers[name] = {
                        "type": "choice",
                        "probabilities": {
                            key: 1.0 if key == preferred else 0.0 for key in choices
                        },
                    }
                response = {"answers": answers}
            else:
                assert self.path.endswith("/invoke")
                calls.append(("prompt", 0, ()))
                response = {
                    "content": [
                        {
                            "type": "text",
                            "text": json.dumps(
                                {
                                    "intent": "hide",
                                    "target": [240, 329],
                                    "crawl": True,
                                    "note": "prompt-stub",
                                }
                            ),
                        }
                    ],
                    "stop_reason": "end_turn",
                }
            payload = json.dumps(response).encode()
            self.send_response(200)
            self.send_header("content-type", "application/json")
            self.send_header("content-length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)

        def log_message(self, *_args: object) -> None:
            pass

    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        game_port = sock.getsockname()[1]
    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    base_env = {
        key: value
        for key, value in os.environ.items()
        if not key.startswith(("ANTHROPIC_", "TYPESAFE_", "AWS_", "METTA_CAPTURE_"))
    }
    processes: list[subprocess.Popen] = []
    logs = []
    with tempfile.TemporaryDirectory(prefix="lantern-policy-smoke-") as directory:
        out = Path(directory)
        (out / "config.json").write_text(json.dumps(config))
        game_env = base_env | {
            "COGAME_HOST": "127.0.0.1",
            "COGAME_PORT": str(game_port),
            "COGAME_CONFIG_URI": f"file://{out}/config.json",
            "COGAME_RESULTS_URI": f"file://{out}/results.json",
            "COGAME_SAVE_REPLAY_URI": f"file://{out}/replay.json",
        }
        try:
            game_log = (out / "game.log").open("w")
            logs.append(game_log)
            processes.append(
                subprocess.Popen(
                    [game_bin],
                    cwd=repo,
                    env=game_env,
                    stdout=game_log,
                    stderr=subprocess.STDOUT,
                )
            )
            by_id = {player["id"]: player for player in manifest["player"]}
            for slot, seated in enumerate(manifest["certification"]["players"]):
                player = by_id[seated["player_id"]]
                player_env = (
                    base_env
                    | player["env"]
                    | {
                        "COWORLD_PLAYER_WS_URL": (
                            f"ws://127.0.0.1:{game_port}/player?slot={slot}"
                            f"&token=policy-smoke-{slot}"
                        ),
                    }
                )
                if seated["player_id"] in ("jev", "prompt"):
                    player_env["AWS_ENDPOINT_URL_BEDROCK_RUNTIME"] = (
                        f"http://127.0.0.1:{server.server_port}"
                    )
                log = (out / f"player-{slot}.log").open("w")
                logs.append(log)
                processes.append(
                    subprocess.Popen(
                        [player_bin],
                        cwd=repo,
                        env=player_env,
                        stdout=log,
                        stderr=subprocess.STDOUT,
                    )
                )
            codes = [process.wait(timeout=180) for process in processes]
            if any(codes):
                for path in sorted(out.glob("*.log")):
                    print(path.name, path.read_text()[-3000:])
            assert codes == [0] * 7, codes
            results = json.loads((out / "results.json").read_text())
            replay = json.loads((out / "replay.json").read_text())
            assert results["reason"] == "complete"
            assert results["policy_kinds"][:2] == ["llm", "llm"]
            assert results["llm_turns"][0] > 0 and results["llm_turns"][1] > 0
            assert results["fallback_turns"] == [0] * 6
            orders = [event for event in replay["events"] if event["type"] == "order"]
            for seat in (0, 1):
                assert any(
                    event["seat"] == seat and event["source"] == "llm"
                    for event in orders
                )
            assert not any(event["type"] == "fallback" for event in replay["events"])
            jev = [call for call in calls if call[0] == "jev"]
            prompt = [call for call in calls if call[0] == "prompt"]
            assert len(jev) == results["llm_turns"][0]
            assert len(prompt) == results["llm_turns"][1]
            assert all(
                call[1:]
                == (7, ("intent", "target", "crate", "aim", "crawl", "say", "note"))
                for call in jev
            )
            print(
                f"player policy smoke OK: Jev={len(jev)}, prompt={len(prompt)}, fallback=0"
            )
        finally:
            server.shutdown()
            for process in processes:
                if process.poll() is None:
                    process.terminate()
            for process in processes:
                if process.poll() is None:
                    process.wait(timeout=5)
            for log in logs:
                log.close()


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
