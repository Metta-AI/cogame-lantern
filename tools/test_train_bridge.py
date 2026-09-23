"""Play both certified Lantern variants through the numeric training protocol."""

import json
import random
import subprocess
import sys
from pathlib import Path


def play(binary: Path, variant: str, teacher: bool) -> None:
    manifest = Path(__file__).resolve().parent.parent / "coworld_manifest_template.json"
    process = subprocess.Popen(
        [str(binary), str(manifest), variant],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        text=True,
        bufsize=1,
    )
    assert process.stdin is not None and process.stdout is not None
    rng = random.Random(17)

    def request(payload: dict) -> dict:
        process.stdin.write(json.dumps(payload) + "\n")
        process.stdin.flush()
        return json.loads(process.stdout.readline())

    try:
        observation = request({"kind": "reset", "seed": f"lantern-{variant}-{teacher}", "players": 6})
        widths = set()
        first_views = {}
        decisions = 0
        while observation["kind"] == "decision":
            encoding = request({"kind": "encode"})
            assert encoding["decision_id"] == observation["decision_id"]
            widths.add(len(encoding["values"]))
            heads = encoding["action_heads"]
            assert [len(head["choices"]) for head in heads] == [11, 1220, 644, 11, 4, 2]
            for head in heads:
                assert observation["action_schema"]["properties"][head["name"]]["enum"] == head["choices"]
            view = observation["semantic_view"]
            assert "seed" not in view and "your_last_order" in view
            assert "crates" in view or "lit" in view
            turn = (view["half"], view["act"], view["turn"])
            if turn not in first_views:
                first_views[turn] = view["clock"]
            else:
                assert view["clock"] == first_views[turn]
            if teacher:
                action = json.loads(request({"kind": "teacher"})["response"])
            else:
                action = {head["name"]: rng.choice(head["choices"]) for head in heads}
            result = request(
                {"kind": "step", "decision_id": observation["decision_id"], "response": json.dumps(action)}
            )
            assert result["kind"] == "accepted" and result["action"] == action
            observation = result["observation"]
            decisions += 1
            assert decisions <= 400
        assert observation["kind"] == "terminal"
        scores = observation["scores"]
        assert set(scores) == {str(i) for i in range(6)}
        assert scores["0"] == scores["2"] == scores["4"]
        assert scores["1"] == scores["3"] == scores["5"]
        assert abs(scores["0"] + scores["1"] - 1) < 1e-6
        assert widths == {573}
        print(variant, "teacher" if teacher else "random", decisions, widths.pop(), "features")
    finally:
        process.stdin.close()
        process.stdout.close()
        assert process.wait(timeout=5) == 0


def check_simultaneous_views(binary: Path) -> None:
    manifest = Path(__file__).resolve().parent.parent / "coworld_manifest_template.json"
    next_views = []
    for intent in ("hide", "flee"):
        process = subprocess.Popen(
            [str(binary), str(manifest), "default"],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            text=True,
            bufsize=1,
        )
        assert process.stdin is not None and process.stdout is not None

        def request(payload: dict) -> dict:
            process.stdin.write(json.dumps(payload) + "\n")
            process.stdin.flush()
            return json.loads(process.stdout.readline())

        first = request({"kind": "reset", "seed": "lantern-simultaneous", "players": 6})
        view = first["semantic_view"]
        action = {"intent": intent, "target_x": view["you"]["pos"][0],
                  "target_y": view["you"]["pos"][1], "crate": -1,
                  "aim": "target", "crawl": False}
        next_views.append(request(
            {"kind": "step", "decision_id": 0, "response": json.dumps(action)}
        )["observation"]["semantic_view"])
        process.stdin.close()
        process.stdout.close()
        assert process.wait(timeout=5) == 0
    assert next_views[0] == next_views[1]


if __name__ == "__main__":
    binary = Path(sys.argv[1]).resolve()
    check_simultaneous_views(binary)
    for variant in ("default", "sprint"):
        for teacher in (True, False):
            play(binary, variant, teacher)
