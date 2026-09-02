"""HEIF thumbnails. /api/thumb refused every .HIF with 404 "no preview" even
though Fujifilm HEIF files carry JPEG previews as HEIF items. exiftool is
stubbed here so the tests run anywhere; the tag order and the source
orientation handling are what the stubs verify."""
import io
import os
import subprocess
import sys
import tempfile
from pathlib import Path

import pytest
from PIL import Image

os.environ.setdefault("DATA_ROOT", os.path.realpath(tempfile.mkdtemp()))
sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import app
from fastapi.testclient import TestClient

client = TestClient(app.app)
HEIF_DIR = app.SORTED / "2026-09-01" / "heif"


def _jpeg(width, height):
    buf = io.BytesIO()
    Image.new("RGB", (width, height), (200, 30, 30)).save(buf, "JPEG")
    return buf.getvalue()


def _stub_exiftool(monkeypatch, calls, previews, orientation):
    def fake_run(cmd, **_kwargs):
        calls.append(cmd)
        if cmd[1] == "-b":
            out = previews.get(cmd[2], b"")
        elif cmd[1] == "-Orientation#":
            out = f"{orientation}\n".encode()
        else:
            out = b""
        return subprocess.CompletedProcess(cmd, 0, stdout=out, stderr=b"")
    monkeypatch.setattr(app.subprocess, "run", fake_run)


@pytest.mark.parametrize("orientation,expected", [(1, (480, 320)), (8, (320, 480))])
def test_hif_thumb_prefers_other_image_and_rotates_like_raw(monkeypatch, orientation, expected):
    HEIF_DIR.mkdir(parents=True, exist_ok=True)
    name = f"DSCF{orientation:04d}.HIF"
    (HEIF_DIR / name).write_bytes(b"\x00" * 5000)  # exiftool is stubbed; bytes are irrelevant
    calls = []
    # Same shape as an X100VI file: 3:2 OtherImage, 4:3 PreviewImage, no
    # orientation tag on either embedded JPEG.
    _stub_exiftool(monkeypatch, calls, {"-OtherImage": _jpeg(1920, 1280), "-PreviewImage": _jpeg(640, 480)}, orientation)

    response = client.get("/api/thumb", params={"v": 3, "f": f"2026-09-01/heif/{name}"})
    assert response.status_code == 200
    assert response.headers["content-type"] == "image/jpeg"
    assert Image.open(io.BytesIO(response.content)).size == expected
    assert [c[2] for c in calls if c[1] == "-b"][0] == "-OtherImage"


def test_heic_without_jpeg_item_stays_placeholder(monkeypatch):
    HEIF_DIR.mkdir(parents=True, exist_ok=True)
    (HEIF_DIR / "IMG_0001.HEIC").write_bytes(b"\x00" * 5000)
    _stub_exiftool(monkeypatch, [], {}, 1)

    response = client.get("/api/thumb", params={"v": 3, "f": "2026-09-01/heif/IMG_0001.HEIC"})
    assert response.status_code == 404
    assert response.json()["error"] == "no embedded preview"
