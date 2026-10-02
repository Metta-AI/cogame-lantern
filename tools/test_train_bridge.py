"""Play both certified Lantern variants through the numeric training protocol."""

import json
import random
import subprocess
import sys
from pathlib import Path


def play(binary: Path, variant: str, teacher: bool, language: bool = False) -> None:
    manifest = Path(__file__).resolve().parent.parent / "coworld_manifest_template.json"
    process = subprocess.Popen(
        [str(binary), str(manifest), variant, *(["--language"] if language else [])],
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
            for head in ([] if language else heads):
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
            elif language:
                action = {"intent": rng.choice(["wait", "hide", "sweep"]), "target": [240, 329]}
            else:
                action = {head["name"]: rng.choice(head["choices"]) for head in heads}
            result = request(
                {"kind": "step", "decision_id": observation["decision_id"], "response": json.dumps(action)}
            )
            assert result["kind"] == "accepted"
            assert result["action"]["intent"] in [head["choices"] for head in heads if head["name"] == "intent"][0]
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
        print(variant, "language" if language else "numeric", "teacher" if teacher else "random", decisions, widths.pop(), "features")
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



def check_language_rejections(binary: Path) -> None:
    manifest = Path(__file__).resolve().parent.parent / "coworld_manifest_template.json"
    with subprocess.Popen([str(binary), str(manifest), "sprint", "--language", "private operator"],
                          stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True) as process:
        def request(payload: dict) -> dict:
            process.stdin.write(json.dumps(payload) + "\n")
            process.stdin.flush()
            return json.loads(process.stdout.readline())
        initial = request({"kind": "reset", "seed": "retry", "players": 6})
        assert initial["inference_mode"] == "text_action"
        retry = request({"kind": "step", "decision_id": initial["decision_id"], "response": "invalid"})
        assert retry["kind"] == "rejected"
        assert retry["observation"]["semantic_view"] == initial["semantic_view"]
        assert retry["observation"]["decision_id"] == initial["decision_id"]
        assert retry["observation"]["messages"][1]["content"].startswith(initial["messages"][1]["content"])
        assert "Your previous reply was invalid" in retry["observation"]["messages"][1]["content"]
        consumed = request({"kind": "step", "decision_id": initial["decision_id"], "response": "invalid"})
        assert consumed["kind"] == "consumed_rejection" and "intent" in consumed["action"]
        assert consumed["observation"]["decision_id"] == initial["decision_id"] + 1
        process.stdin.close()
        assert process.wait(timeout=5) == 0

if __name__ == "__main__":
    binary = Path(sys.argv[1]).resolve()
    check_simultaneous_views(binary)
    for variant in ("default", "sprint"):
        for teacher in (True, False):
            play(binary, variant, teacher)

    check_language_rejections(binary)
    for variant in ("default", "sprint"):
        for teacher in (True, False): play(binary, variant, teacher, language=True)
