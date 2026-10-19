"""Exercise owned HTTP cancellation and disconnected-player private-only sealing."""

import base64
import http.server
import json
import os
import signal
import socket
import subprocess
import sys
import threading
import time
import uuid
from pathlib import Path

GAME, PLAYER, OUTPUT = (Path(value).resolve() for value in sys.argv[1:4])
ROOT = Path(__file__).resolve().parents[1]
SOURCE = (os.environ["COWORLD_TEST_SOURCE_REVISION"] if "COWORLD_TEST_SOURCE_REVISION" in os.environ
          else subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip())

for case in ("started-sigterm", "partial-sigterm", "partial-sigint", "player-sigterm", "disconnected"):
    output = OUTPUT / case
    output.mkdir(parents=True, exist_ok=False)
    entered = threading.Event()
    release = threading.Event()
    partial = b"\xffprivate-partial"
    owner_seat = []

    class Messages(http.server.BaseHTTPRequestHandler):
        def do_POST(self):
            request = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
            owner_seat.append(int(self.headers["X-Coworld-Player-Slot"]))
            assert request["messages"]
            if case != "started-sigterm":
                self.send_response(200)
                self.send_header("Content-Length", "1000")
                self.send_header("X-Fixture", "private-header")
                self.end_headers()
                self.wfile.write(partial)
                self.wfile.flush()
            entered.set()
            assert release.wait(10)

        def log_message(self, *_args):
            pass

    with socket.socket() as reserve:
        reserve.bind(("127.0.0.1", 0))
        port = reserve.getsockname()[1]
    config = {"num_agents": 6, "tokens": [f"t{seat}" for seat in range(6)],
              "players": [{"name": f"p{seat}"} for seat in range(6)],
              "seed": 7, "prepTicks": 24, "huntTicks": 48, "turnTicks": 24,
              "turnBudgetSeconds": 0.5, "wallClockBudgetSeconds": 120,
              "episodeTimeoutSeconds": 180, "shutdownGraceSeconds": 0,
              "playerConnectTimeoutSeconds": 5}
    (output / "config.json").write_text(json.dumps(config))
    env = {**os.environ, "COGAME_HOST": "127.0.0.1", "COGAME_PORT": str(port),
           "COGAME_CONFIG_URI": (output / "config.json").as_uri(),
           "COGAME_RESULTS_URI": (output / "results.json").as_uri(),
           "COGAME_SAVE_REPLAY_URI": (output / "replay.json").as_uri(),
           "COGAME_SAVE_TRAJECTORY_URI": (output / "trajectory.jsonl").as_uri(),
           "COWORLD_EPISODE_ID": str(uuid.uuid4()), "COWORLD_GAME_VERSION": "lifecycle-fixture",
           "COWORLD_SOURCE_REVISION": SOURCE}
    provider = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Messages)
    provider.daemon_threads = False
    thread = threading.Thread(target=provider.serve_forever)
    processes = []
    logs = []
    thread_started = False
    try:
        thread.start()
        thread_started = True
        game_log = (output / "game.log").open("w")
        logs.append(game_log)
        game = subprocess.Popen([str(GAME)], cwd=ROOT, env=env, stdout=game_log, stderr=game_log)
        processes.append(game)
        ready_deadline = time.monotonic() + 5
        while True:
            with socket.socket() as probe:
                ready = probe.connect_ex(("127.0.0.1", port)) == 0
            if ready:
                break
            assert game.poll() is None and time.monotonic() < ready_deadline
            time.sleep(0.02)
        # Seat zero owns the live HTTP request; other seats have no provider worker.
        for seat in range(6):
            player_env = {**env, "COWORLD_PLAYER_WS_URL": f"ws://127.0.0.1:{port}/player?slot={seat}&token=t{seat}",
                          "COWORLD_LLM_ENDPOINT": f"http://127.0.0.1:{provider.server_port}",
                          "PLAYER_SCRIPTED": "" if seat == 0 else "1"}
            player_log = (output / f"player-{seat}.log").open("w")
            logs.append(player_log)
            processes.append(subprocess.Popen([str(PLAYER)], cwd=ROOT, env=player_env,
                                              stdout=player_log, stderr=player_log))
        assert entered.wait(5), "live native request was not observed"
        assert owner_seat == [0]
        time.sleep(0.05)
        stopped_at = time.monotonic()
        if case == "disconnected":
            processes[1].kill()
        elif case == "player-sigterm":
            processes[1].send_signal(signal.SIGTERM)
        else:
            game.send_signal(signal.SIGINT if case == "partial-sigint" else signal.SIGTERM)
        assert game.wait(timeout=8) == 0
        elapsed = time.monotonic() - stopped_at
        release.set()
        for index, player in enumerate(processes[1:], start=1):
            expected_exit = -signal.SIGKILL if case == "disconnected" and index == 1 else 0
            assert player.wait(timeout=5) == expected_exit
        events = [json.loads(line) for line in (output / "trajectory.jsonl").read_text().splitlines()]
        episode = events[-1]
        assert episode["status"] == "truncated" and episode["participant_outcomes"] is None
        assert not (output / "results.json").exists() and not (output / "replay.json").exists()
        attempts = [attempt for event in events if event["event_type"] == "decision" for attempt in event["attempts"]]
        native = [attempt for attempt in attempts if attempt["origin"] == "model"]
        assert len(native) == 1
        attempt = native[0]
        assert attempt["prompt"] and attempt["request"]
        assert attempt["platform_call_id"] is None and attempt["raw_response"] is None
        assert not attempt["accepted"]
        if case == "disconnected":
            assert attempt["response_reader_joined"] is None
            assert episode["outcome"]["player_cleanup"]["0"] == "unresolved"
        else:
            assert attempt["response_reader_joined"] is True
            if case == "started-sigterm":
                assert attempt["response_body_b64"] is None and attempt["response_headers_b64"] is None
                assert attempt["http_status"] is None and attempt["response_complete"] is None
            else:
                assert base64.b64decode(attempt["response_body_b64"]) == partial
                assert b"X-Fixture: private-header" in base64.b64decode(attempt["response_headers_b64"])
                assert attempt["http_status"] == 200 and attempt["response_complete"] is False
            if case == "player-sigterm":
                assert episode["outcome"]["player_cleanup"]["0"] == "unresolved"
        assert (output / "trajectory.jsonl").stat().st_mode & 0o777 == 0o600
        (output / "proof.json").write_text(json.dumps({"case": case, "signal_to_seal_seconds": elapsed,
                                                       "source_revision": SOURCE, "scope": "fixture-only"}) + "\n")
        print(case, "private truncated", elapsed, flush=True)
    finally:
        release.set()
        for process in processes:
            if process.poll() is None:
                process.terminate()
            process.wait(timeout=5)
        for log in logs:
            log.close()
        if thread_started:
            provider.shutdown()
        provider.server_close()
        if thread_started:
            thread.join(timeout=5)
            assert not thread.is_alive()
