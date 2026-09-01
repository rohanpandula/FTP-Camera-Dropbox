"""Panel quarantine/status honesty tests: byte-verified prune and ctime-based
arrival age, run against a temporary DATA_ROOT so nothing here touches the
real library."""
import os
import sys
import shutil
import tempfile
import time
import pytest
from pathlib import Path

# app.py reads DATA_ROOT at import time (module-level constants), so it must
# be set before `import app` runs. realpath matters because /var is a symlink
# on macOS and safe_child compares resolved prefixes.
os.environ["DATA_ROOT"] = os.path.realpath(tempfile.mkdtemp())
sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import app
from fastapi.testclient import TestClient

# Built without the `with` context manager so the startup hook never runs —
# it launches background polling loops (funnel_loop, ask_loop, tg_poll_loop)
# that have no place in a synchronous test run.
client = TestClient(app.app)

DATED = "2026-01-01"
SORTED_RAW = app.SORTED / DATED / "raw"
QUAR_DATED = app.QUAR / DATED

app.INCOMING.mkdir(parents=True, exist_ok=True)
SORTED_RAW.mkdir(parents=True, exist_ok=True)
QUAR_DATED.mkdir(parents=True, exist_ok=True)
app.PANEL_DIR.mkdir(parents=True, exist_ok=True)


@pytest.fixture(autouse=True)
def _reset_data_dirs():
    # Wipe and recreate the three data trees before every test so no fixture
    # from a prior test leaks into the next one.
    for d in (app.INCOMING, SORTED_RAW, QUAR_DATED):
        shutil.rmtree(d, ignore_errors=True)
        d.mkdir(parents=True, exist_ok=True)
    # Mandatory: without this reset, the 60-second cache in
    # _library_name_sizes serves the previous test's index and the
    # byte-difference case would pass for the wrong reason.
    app._lib_index_cache["ts"] = 0.0
    app._lib_index_cache["index"] = {}
    yield


def test_prune_verified_removes_identical_bytes():
    name = "DSC00001.ARW"
    payload = b"X" * 2048
    (SORTED_RAW / name).write_bytes(payload)
    quar_file = QUAR_DATED / name
    quar_file.write_bytes(payload)

    response = client.post("/api/quarantine/action", json={"action": "prune_verified"})
    assert response.status_code == 200
    body = response.json()
    assert body["removed"] == 1
    assert body["kept"] == 0
    assert not quar_file.exists()


def test_prune_verified_keeps_same_size_different_bytes():
    name = "DSC00002.ARW"
    (SORTED_RAW / name).write_bytes(b"A" * 2048)
    quar_file = QUAR_DATED / name
    quar_file.write_bytes(b"B" * 2048)

    response = client.post("/api/quarantine/action", json={"action": "prune_verified"})
    assert response.status_code == 200
    body = response.json()
    assert body["removed"] == 0
    assert body["kept"] == 1
    assert quar_file.exists()


def test_in_library_stays_name_size_hint():
    identical_name = "DSC00003.ARW"
    identical_bytes = b"X" * 2048
    (SORTED_RAW / identical_name).write_bytes(identical_bytes)
    (QUAR_DATED / identical_name).write_bytes(identical_bytes)

    differing_name = "DSC00004.ARW"
    (SORTED_RAW / differing_name).write_bytes(b"A" * 2048)
    (QUAR_DATED / differing_name).write_bytes(b"B" * 2048)

    response = client.get("/api/quarantine")
    assert response.status_code == 200
    files = response.json()["files"]
    assert len(files) == 2
    assert all(f["in_library"] for f in files)


def test_status_age_s_is_arrival_time():
    target = app.INCOMING / "DSC09999.ARW"
    target.write_bytes(b"raw")
    three_hours_ago = time.time() - 10800
    os.utime(target, (three_hours_ago, three_hours_ago))

    response = client.get("/api/status")
    assert response.status_code == 200
    incoming = response.json()["incoming"]
    assert len(incoming) == 1
    assert incoming[0]["age_s"] < 60
