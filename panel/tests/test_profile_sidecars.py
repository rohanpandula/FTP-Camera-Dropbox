"""Profile sidecar rules: the panel stores which camera profile the sorter
names in a sidecar beside new RAWs from a body. The sorter reads config.json
directly, so the rule must land in the file, and a profile name can never
carry markup because it is written into an XMP attribute."""
import json
import os
import sys
import tempfile
from pathlib import Path

os.environ.setdefault("DATA_ROOT", os.path.realpath(tempfile.mkdtemp()))
sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import app
from fastapi.testclient import TestClient

client = TestClient(app.app)


def test_profile_rules_round_trip_to_config_file():
    app.PANEL_DIR.mkdir(parents=True, exist_ok=True)
    rules = [{"camera": "ILCE-7CR", "profile": "Cobalt Standard (S)"}]
    response = client.put("/api/config", json={"profile_sidecars": rules, "features": {"profile_sidecar": True}})
    assert response.status_code == 200, response.text
    body = client.get("/api/config").json()
    assert body["profile_sidecars"] == rules
    assert body["features"]["profile_sidecar"] is True
    assert json.load(open(app.CONFIG_PATH))["profile_sidecars"] == rules


def test_profile_name_cannot_carry_markup():
    response = client.put("/api/config", json={"profile_sidecars": [{"camera": "ILCE-7CR", "profile": 'Cobalt "S"<x>'}]})
    assert response.status_code == 400
    assert "profile" in response.json()["error"]


def test_defaults_name_cobalt_for_the_two_bodies():
    cameras = {r["camera"]: r["profile"] for r in app.DEFAULT_CONFIG["profile_sidecars"]}
    assert cameras == {"ILCE-7CR": "Cobalt Standard (S)", "GFX100 II": "Cobalt Standard (S)"}
