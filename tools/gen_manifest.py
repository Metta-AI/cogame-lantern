"""Sync embedded source documents without replacing authoritative manifest config.

The manifest owns runnables, policies, variants and result/config schemas.
Refreshing documents preserves those fields.
"""
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
path = ROOT / "coworld_manifest_template.json"
manifest = json.loads(path.read_text())
manifest["game"]["protocols"]["player"]["value"] = (ROOT / "docs" / "PROTOCOL.md").read_text()
manifest["game"]["docs"]["readme"]["value"] = (ROOT / "README.md").read_text()
for page in manifest["game"]["docs"]["pages"]:
    filename = {"rules.md": "RULES.md", "protocol.md": "PROTOCOL.md"}[page["id"]]
    page["content"]["value"] = (ROOT / "docs" / filename).read_text()
path.write_text(json.dumps(manifest, indent=2, ensure_ascii=False) + "\n")
