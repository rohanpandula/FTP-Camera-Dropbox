#!/usr/bin/env python3
"""dropbox-panel — LAN control panel for the FTP camera dropbox.

One process, no database. The filesystem is the source of truth for status;
/data/.panel/config.json is the runtime contract with sort.sh (which reads it
per event via jq and falls back to built-in behavior when it is absent or
corrupt — the pipeline never depends on this panel running).

Runs as 99:100 with /data mounted rw and the host healthcheck state file
mounted ro. No docker socket, no shell-outs with user input (exiftool gets
validated paths via argv only).
"""
from __future__ import annotations

import asyncio
import hashlib
import io
import json
import logging
import os
import re
import shutil
import subprocess
import tempfile
import threading
import time
from datetime import datetime
from pathlib import Path
from urllib.parse import urlsplit

from fastapi import FastAPI, Request
from fastapi.responses import FileResponse, JSONResponse, Response
from starlette.middleware.trustedhost import TrustedHostMiddleware
from PIL import Image, ImageOps

log = logging.getLogger("panel")
logging.basicConfig(level=logging.INFO, format="%(asctime)s [%(levelname)s] panel: %(message)s")

DATA = Path(os.environ.get("DATA_ROOT", "/data")).resolve()
INCOMING = DATA / "incoming"
SORTED = DATA / "sorted"
QUAR = DATA / "quarantine"
QUEUE = Path(os.environ.get("NEF_QUEUE_DIR") or str(DATA / "nef-queue")).resolve()
PANEL_DIR = DATA / ".panel"
CONFIG_PATH = PANEL_DIR / "config.json"
THUMBS = PANEL_DIR / "thumbs"
PENDING = PANEL_DIR / "pending"      # sorter drops unknown-lens questions here
RESOLVED = PANEL_DIR / "resolved"
TG_OFFSET = PANEL_DIR / "tg-offset"
HEALTH_FILE = Path(os.environ.get("HEALTH_FILE", "/health/state"))
TG_CONFIG = Path(os.environ.get("TG_CONFIG", "/etc/telegram.json"))

RESERVED = {INCOMING, SORTED, QUAR, QUEUE, PANEL_DIR}
DATE_RE = re.compile(r"^\d{4}-\d{2}-\d{2}$")
SIDECARS = {".xmp", ".acr"}
RAW_EXTS = {".nef", ".arw", ".raf", ".dng", ".nrw", ".cr2", ".cr3"}
IMG_EXTS = {".jpg", ".jpeg", ".tif", ".tiff"}
FEATURES = ("lens_massage", "nef_render_queue", "telegram_notifications", "watch_funnel",
            "ask_on_unknown")

# Matches the validation sort.sh re-applies before writing tags.
MODEL_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9 ./-]{0,62}$")
INFO_RE = re.compile(r"^[0-9][0-9. ]{0,30}$")
FOCAL_RE = re.compile(r"^[0-9]{1,4}(\.[0-9])?$")

DEFAULT_CONFIG = {
    "features": {k: True for k in FEATURES},
    "lens_rules": [
        {"match_lens": ["35mm f/1.4"],
         "lens_model": "FE 35mm F1.4 GM", "lens_info": "35 35 1.4 1.4"},
        {"match_lens": ["50mm f/1.2", "50mm f/1.3"],
         "lens_model": "FE 50mm F1.2 GM", "lens_info": "50 50 1.2 1.2"},
        {"match_lens": ["0mm f/0"], "match_lens_id_regex": "Leica.*35|Summicron.*35",
         "set_focal_length": "35"},
    ],
    "watched_folders": [],
    # Buttons offered when the sorter meets glass no rule matches — over
    # Telegram and on the Decisions tab. Unanswered questions auto-close
    # after ask_timeout_hours with no EXIF change.
    "ask_timeout_hours": 12,
    "lens_presets": [
        {"label": "Sony FE 35mm F1.4 GM",
         "lens_model": "FE 35mm F1.4 GM", "lens_info": "35 35 1.4 1.4"},
        {"label": "Sony FE 50mm F1.2 GM",
         "lens_model": "FE 50mm F1.2 GM", "lens_info": "50 50 1.2 1.2"},
        {"label": "Leica APO-Summicron-M 35 (set 35mm)",
         "set_focal_length": "35"},
    ],
}

_config_lock = threading.Lock()
_thumb_gate = threading.Semaphore(2)  # bound concurrent decoders, not just file size
app = FastAPI(openapi_url=None, docs_url=None, redoc_url=None)

# DNS-rebinding defense: a hostile page's own hostname can resolve to this
# LAN IP, making Origin==Host self-consistent — only a Host allowlist stops
# that. Set PANEL_ALLOWED_HOSTS (comma-separated) in the deployment.
_hosts = [h.strip() for h in os.environ.get("PANEL_ALLOWED_HOSTS", "").split(",") if h.strip()]
if _hosts and _hosts != ["*"]:
    app.add_middleware(TrustedHostMiddleware, allowed_hosts=_hosts)
else:
    log.warning("PANEL_ALLOWED_HOSTS unset — DNS-rebinding protection disabled")


@app.middleware("http")
async def csrf_guard(request: Request, call_next):
    # No-auth is a deliberate LAN-trust decision, but a hostile page in the
    # user's own browser can still fire cross-origin writes at a LAN IP.
    # Browsers always attach Origin (or Sec-Fetch-Site) to those — curl and
    # same-origin fetches pass untouched.
    if request.method in ("POST", "PUT", "DELETE"):
        origin = request.headers.get("origin")
        if origin is not None:
            if urlsplit(origin).netloc != request.headers.get("host", ""):
                return JSONResponse({"error": "cross-origin write rejected"}, status_code=403)
        else:
            sfs = request.headers.get("sec-fetch-site")
            if sfs and sfs not in ("same-origin", "none"):
                return JSONResponse({"error": "cross-site write rejected"}, status_code=403)
    return await call_next(request)


def noclobber_move(src: Path, dest_dir: Path, name: str, tag: str) -> Path:
    """Move src into dest_dir without ever replacing an existing file.

    os.rename silently clobbers; the sorter's whole design forbids that. A
    hard link fails atomically with EEXIST on collision (same filesystem —
    everything here lives under /data), so link-then-unlink gives the same
    no-clobber guarantee as sort.sh's move_with_suffix.
    """
    dest_dir.mkdir(parents=True, exist_ok=True)
    stem, suffix = os.path.splitext(name)
    candidate = name
    for n in range(1, 1000):
        dest = dest_dir / candidate
        try:
            os.link(src, dest, follow_symlinks=False)
        except FileExistsError:
            candidate = f"{stem}_{tag}{n}{suffix}"
            continue
        os.unlink(src)
        return dest
    raise OSError(f"no free name for {name} in {dest_dir}")


# ---------------------------------------------------------------- config ----

def load_config() -> dict:
    try:
        with open(CONFIG_PATH) as f:
            cfg = json.load(f)
        validate_config(cfg)
    except Exception:
        return json.loads(json.dumps(DEFAULT_CONFIG))
    # Forward-fill: configs written by an older panel lack newer keys
    # (lens_presets, ask_timeout_hours). Defaults apply until the next save
    # persists them.
    for k, v in DEFAULT_CONFIG.items():
        cfg.setdefault(k, json.loads(json.dumps(v)))
    return cfg


def save_config(cfg: dict) -> None:
    with _config_lock:
        PANEL_DIR.mkdir(mode=0o775, exist_ok=True)
        fd, tmp = tempfile.mkstemp(dir=PANEL_DIR, prefix=".config.")
        try:
            with os.fdopen(fd, "w") as f:
                json.dump(cfg, f, indent=2)
                f.flush()
                os.fsync(f.fileno())
            os.chmod(tmp, 0o664)
            os.replace(tmp, CONFIG_PATH)  # atomic: sort.sh's jq never sees a partial file
        except BaseException:
            try:
                os.unlink(tmp)
            except OSError:
                pass
            raise


def validate_config(cfg: dict) -> None:
    if not isinstance(cfg, dict):
        raise ValueError("config must be an object")
    feats = cfg.get("features", {})
    if not isinstance(feats, dict) or set(feats) - set(FEATURES):
        raise ValueError(f"features must be a subset of {FEATURES}")
    if not all(isinstance(v, bool) for v in feats.values()):
        raise ValueError("feature values must be booleans")

    rules = cfg.get("lens_rules", [])
    if not isinstance(rules, list) or len(rules) > 32:
        raise ValueError("lens_rules must be a list of at most 32 rules")
    for i, r in enumerate(rules):
        where = f"rule {i + 1}"
        if not isinstance(r, dict):
            raise ValueError(f"{where}: must be an object")
        ml = r.get("match_lens")
        if (not isinstance(ml, list) or not 1 <= len(ml) <= 8
                or not all(isinstance(s, str) and 1 <= len(s) <= 64 and s.isprintable() for s in ml)):
            raise ValueError(f"{where}: match_lens needs 1-8 printable strings")
        if "match_lens_id_regex" in r:
            rx = r["match_lens_id_regex"]
            if not isinstance(rx, str) or not 1 <= len(rx) <= 128:
                raise ValueError(f"{where}: lens-ID regex must be 1-128 chars")
            try:
                re.compile(rx)
            except re.error as exc:
                raise ValueError(f"{where}: bad regex ({exc})")
        actions = 0
        if "lens_model" in r:
            if not isinstance(r["lens_model"], str) or not MODEL_RE.match(r["lens_model"]):
                raise ValueError(f"{where}: lens model must be letters/digits/space/./-, max 63")
            actions += 1
        if "lens_info" in r:
            if not isinstance(r["lens_info"], str) or not INFO_RE.match(r["lens_info"]):
                raise ValueError(f"{where}: lens info must look like '50 50 1.2 1.2'")
            actions += 1
        if "set_focal_length" in r:
            v = str(r["set_focal_length"])
            if not FOCAL_RE.match(v):
                raise ValueError(f"{where}: focal length must be a number like 35")
            r["set_focal_length"] = v
            actions += 1
        if not actions:
            raise ValueError(f"{where}: needs at least one of lens_model / lens_info / set_focal_length")
        for key in ("match_camera", "exclude_camera"):
            if key in r:
                v = r[key]
                if (not isinstance(v, list) or not 1 <= len(v) <= 8
                        or not all(isinstance(s, str) and 1 <= len(s) <= 64 and s.isprintable() for s in v)):
                    raise ValueError(f"{where}: {key} needs 1-8 printable strings (substring match on the body name)")
        extra = set(r) - {"match_lens", "match_lens_id_regex", "lens_model", "lens_info",
                          "set_focal_length", "match_camera", "exclude_camera"}
        if extra:
            raise ValueError(f"{where}: unknown fields {sorted(extra)}")

    wf = cfg.get("watched_folders", [])
    if not isinstance(wf, list) or len(wf) > 8:
        raise ValueError("watched_folders must be a list of at most 8 paths")
    for p in wf:
        validate_watch_folder(p)

    hours = cfg.get("ask_timeout_hours", 12)
    if not isinstance(hours, (int, float)) or isinstance(hours, bool) or not 1 <= hours <= 168:
        raise ValueError("ask_timeout_hours must be 1-168")

    presets = cfg.get("lens_presets", [])
    if not isinstance(presets, list) or len(presets) > 10:
        raise ValueError("lens_presets must be a list of at most 10 entries")
    for i, p in enumerate(presets):
        where = f"preset {i + 1}"
        if not isinstance(p, dict):
            raise ValueError(f"{where}: must be an object")
        lbl = p.get("label")
        if not isinstance(lbl, str) or not 1 <= len(lbl) <= 48 or not lbl.isprintable():
            raise ValueError(f"{where}: label must be 1-48 printable chars")
        actions = 0
        if "lens_model" in p:
            if not isinstance(p["lens_model"], str) or not MODEL_RE.match(p["lens_model"]):
                raise ValueError(f"{where}: bad lens_model")
            actions += 1
        if "lens_info" in p:
            if not isinstance(p["lens_info"], str) or not INFO_RE.match(p["lens_info"]):
                raise ValueError(f"{where}: bad lens_info")
            actions += 1
        if "set_focal_length" in p:
            v = str(p["set_focal_length"])
            if not FOCAL_RE.match(v):
                raise ValueError(f"{where}: bad set_focal_length")
            p["set_focal_length"] = v
            actions += 1
        if not actions:
            raise ValueError(f"{where}: needs at least one tag action")
        extra = set(p) - {"label", "lens_model", "lens_info", "set_focal_length"}
        if extra:
            raise ValueError(f"{where}: unknown fields {sorted(extra)}")

    extra = set(cfg) - {"features", "lens_rules", "watched_folders",
                        "ask_timeout_hours", "lens_presets"}
    if extra:
        raise ValueError(f"unknown config fields {sorted(extra)}")


def validate_watch_folder(p: str) -> Path:
    if not isinstance(p, str) or not p.startswith("/"):
        raise ValueError("watched folder must be an absolute path under /data")
    resolved = Path(p).resolve()
    if not str(resolved).startswith(str(DATA) + os.sep):
        raise ValueError(f"{p}: must live under {DATA}")
    for res in RESERVED:
        if resolved == res or str(resolved).startswith(str(res) + os.sep) \
                or str(res).startswith(str(resolved) + os.sep):
            raise ValueError(f"{p}: overlaps the pipeline directory {res.name}/")
    if not resolved.is_dir():
        raise ValueError(f"{p}: folder does not exist yet — create it first")
    return resolved


# ------------------------------------------------------------ path safety ----

def safe_child(root: Path, rel: str) -> Path:
    """Resolve rel under root; reject traversal, absolute paths, symlink escapes."""
    if not rel or rel.startswith(("/", "~")) or "\x00" in rel or len(rel) > 1024:
        raise ValueError("bad path")
    p = (root / rel).resolve()
    if not str(p).startswith(str(root) + os.sep):
        raise ValueError("path escapes root")
    return p


def err(msg: str, code: int = 400) -> JSONResponse:
    return JSONResponse({"error": msg}, status_code=code)


# ----------------------------------------------------------------- status ----

def walk_files(root: Path, skip_hidden_dirs: bool = True):
    if not root.is_dir():
        return
    for dirpath, dirnames, filenames in os.walk(root):
        if skip_hidden_dirs:
            dirnames[:] = [d for d in dirnames if not d.startswith(("_", "."))]
        for name in filenames:
            yield Path(dirpath) / name


@app.get("/api/status")
def api_status():
    now = time.time()
    incoming, receiving = [], 0
    if INCOMING.is_dir():
        for f in sorted(INCOMING.rglob("*")):
            try:
                if not f.is_file() or f.is_symlink():
                    continue
                if f.name.startswith(".pureftpd-upload."):
                    receiving += 1
                    continue
                if f.name.startswith("."):
                    continue
                st = f.stat()
                incoming.append({"name": f.name, "size": st.st_size,
                                 "age_s": int(now - st.st_mtime)})
            except OSError:
                continue
            if len(incoming) >= 50:
                break

    today = datetime.now().strftime("%Y-%m-%d")
    quar_total = quar_today = 0
    for f in walk_files(QUAR):
        quar_total += 1
        if f.parent.name == today:
            quar_today += 1
    queue_depth = sum(1 for _ in walk_files(QUEUE))
    pending_decisions = len(list(PENDING.glob("*.json"))) if PENDING.is_dir() else 0
    sorted_today = sum(1 for f in walk_files(SORTED / today)
                       if f.suffix.lower() not in SIDECARS) if (SORTED / today).is_dir() else 0

    # Health lamp. Preferred source: the root cron's state file (fail lines,
    # empty/absent = healthy). On boxes where that dir is root-only (0700),
    # fall back to what the panel can see itself: uploads stuck in incoming
    # far beyond the sorter's own STUCK threshold mean the pipeline stalled.
    health = {"state": "unknown", "detail": ""}
    try:
        text = HEALTH_FILE.read_text().strip()
        health = {"state": "ok", "detail": "healthcheck clean"} if not text else \
                 {"state": "fail", "detail": text[:500]}
    except FileNotFoundError:
        if HEALTH_FILE.parent.is_dir():
            health = {"state": "ok", "detail": "no failures recorded"}
    except OSError:
        pass
    if health["state"] == "unknown":
        stuck = [f for f in incoming if f["age_s"] > 5400]
        health = {"state": "fail", "detail": f"{len(stuck)} upload(s) stuck >90min in incoming/"} \
            if stuck else {"state": "ok", "detail": "derived: incoming draining normally"}

    du = shutil.disk_usage(DATA)
    return no_store({
        "health": health,
        "incoming": incoming,
        "receiving": receiving,
        "counts": {"quarantine_total": quar_total, "quarantine_today": quar_today,
                   "queue_depth": queue_depth, "sorted_today": sorted_today,
                   "pending_decisions": pending_decisions},
        "disk": {"total": du.total, "free": du.free},
        "now": int(now),
    })


@app.get("/api/recent")
def api_recent(limit: int = 18):
    limit = max(1, min(60, limit))
    dates = sorted((d.name for d in SORTED.iterdir()
                    if d.is_dir() and DATE_RE.match(d.name)), reverse=True)[:5] \
        if SORTED.is_dir() else []
    files = []
    for date in dates:
        for f in walk_files(SORTED / date):
            if f.suffix.lower() in SIDECARS or f.name.startswith("."):
                continue
            try:
                st = f.stat()
            except OSError:
                continue
            files.append({
                "rel": str(f.relative_to(SORTED)),
                "name": f.name,
                "type": f.parent.name,
                "date": date,
                "size": st.st_size,
                "mtime": int(st.st_mtime),
            })
    files.sort(key=lambda x: x["mtime"], reverse=True)
    return no_store({"files": files[:limit]})


# ---------------------------------------------------------------- library ----

@app.get("/api/library")
def api_library():
    days = []
    if SORTED.is_dir():
        for d in sorted(SORTED.iterdir(), reverse=True):
            if not d.is_dir() or not DATE_RE.match(d.name):
                continue
            types = {}
            for t in d.iterdir():
                if t.is_dir():
                    types[t.name] = sum(1 for f in t.iterdir()
                                        if f.is_file() and f.suffix.lower() not in SIDECARS
                                        and not f.name.startswith("."))
            days.append({"date": d.name, "types": types, "total": sum(types.values())})
            if len(days) >= 366:
                break
    return no_store({"days": days})


@app.get("/api/library/{date}")
def api_library_day(date: str):
    if not DATE_RE.match(date):
        return err("bad date")
    day = SORTED / date
    if not day.is_dir():
        return err("no such day", 404)
    files = []
    for f in walk_files(day):
        if f.suffix.lower() in SIDECARS or f.name.startswith("."):
            continue
        try:
            st = f.stat()
        except OSError:
            continue
        files.append({"rel": str(f.relative_to(SORTED)), "name": f.name,
                      "type": f.parent.name, "size": st.st_size, "mtime": int(st.st_mtime)})
    files.sort(key=lambda x: (x["type"], x["name"]))
    return no_store({"date": date, "files": files})


# ----------------------------------------------------------------- thumbs ----

# EXIF orientation 1-8 -> PIL transpose. Embedded raw previews are usually
# stored unrotated with NO orientation tag of their own (verified on A7CR
# ARWs: 1616x1080 landscape preview, orientation only on the outer file), so
# exif_transpose alone silently no-ops — the source file's tag is authoritative.
_TRANSPOSE = {2: Image.Transpose.FLIP_LEFT_RIGHT, 3: Image.Transpose.ROTATE_180,
              4: Image.Transpose.FLIP_TOP_BOTTOM, 5: Image.Transpose.TRANSPOSE,
              6: Image.Transpose.ROTATE_270, 7: Image.Transpose.TRANSVERSE,
              8: Image.Transpose.ROTATE_90}


def source_orientation(path: Path) -> int:
    try:
        out = subprocess.run(["exiftool", "-Orientation#", "-s3", str(path)],
                             capture_output=True, timeout=15).stdout.decode().strip()
        return int(out or "1")
    except (subprocess.TimeoutExpired, OSError, ValueError):
        return 1


def extract_preview(path: Path) -> bytes | None:
    for tag in ("-PreviewImage", "-JpgFromRaw", "-OtherImage", "-ThumbnailImage"):
        try:
            out = subprocess.run(
                ["exiftool", "-b", tag, "-api", "largefilesupport=1", str(path)],
                capture_output=True, timeout=20).stdout
        except (subprocess.TimeoutExpired, OSError):
            return None
        if out and len(out) > 4000:
            return out
    return None


@app.get("/api/thumb")
def api_thumb(f: str):
    try:
        path = safe_child(SORTED, f)
    except ValueError:
        return err("bad path")
    ext = path.suffix.lower()
    if not path.is_file() or ext not in RAW_EXTS | IMG_EXTS:
        return err("no preview", 404)
    try:
        st = path.stat()
    except OSError:
        return err("no preview", 404)

    key = hashlib.sha1(f"o2:{f}:{st.st_mtime_ns}:{st.st_size}".encode()).hexdigest() + ".jpg"
    cached = THUMBS / key
    if cached.is_file():
        return FileResponse(cached, media_type="image/jpeg",
                            headers={"Cache-Control": "max-age=86400, immutable"})
    if st.st_size > 200_000_000:  # bound the read; RAW path is preview-only anyway
        return err("file too large to preview", 404)

    with _thumb_gate:
        raw = extract_preview(path) if ext in RAW_EXTS else None
        if raw is None and ext in IMG_EXTS:
            try:
                raw = path.read_bytes()
            except OSError:
                return err("unreadable", 404)
        if not raw:
            return err("no embedded preview", 404)
        try:
            img = Image.open(io.BytesIO(raw))
            own = 1
            try:
                own = int(img.getexif().get(0x0112) or 1)
            except Exception:
                pass
            if own != 1:
                img = ImageOps.exif_transpose(img)
            elif ext in RAW_EXTS:
                o = source_orientation(path)
                if o in _TRANSPOSE:
                    img = img.transpose(_TRANSPOSE[o])
            img.thumbnail((480, 480))
            buf = io.BytesIO()
            img.convert("RGB").save(buf, "JPEG", quality=82)
        except Exception:
            return err("preview decode failed", 404)

    THUMBS.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=THUMBS, prefix=".t.")
    with os.fdopen(fd, "wb") as out:
        out.write(buf.getvalue())
    os.chmod(tmp, 0o664)
    os.replace(tmp, cached)
    return Response(buf.getvalue(), media_type="image/jpeg",
                    headers={"Cache-Control": "max-age=86400, immutable"})


# ------------------------------------------------------------------ config ----

@app.get("/api/config")
def api_config_get():
    cfg, invalid = load_config(), False
    if CONFIG_PATH.exists():
        try:
            with open(CONFIG_PATH) as f:
                validate_config(json.load(f))
        except Exception:
            invalid = True  # UI warns: showing defaults, next save rewrites the file
    return no_store({**cfg, "_invalid": invalid})


@app.put("/api/config")
async def api_config_put(request: Request):
    try:
        body = await request.json()
    except Exception:
        return err("invalid JSON")
    merged = load_config()
    # Features merge per-key so two quick toggles can't revert each other;
    # rules and folders are whole-list edits by design.
    if isinstance(body.get("features"), dict):
        merged["features"] = {**merged.get("features", {}), **body["features"]}
    for k in ("lens_rules", "watched_folders", "ask_timeout_hours", "lens_presets"):
        if k in body:
            merged[k] = body[k]
    try:
        validate_config(merged)
    except ValueError as exc:
        return err(str(exc))
    save_config(merged)
    log.info("config saved: features=%s rules=%d watched=%d",
             merged["features"], len(merged["lens_rules"]), len(merged["watched_folders"]))
    return no_store(merged)


# -------------------------------------------------------------- quarantine ----

_lib_index_lock = threading.Lock()
_lib_index_cache = {"ts": 0.0, "index": {}}


def _library_name_sizes() -> dict:
    # name -> set of sizes across sorted/, used to recognise a held file whose
    # identical copy already lives in the library. Cached briefly: the walk is
    # cheap relative to exiftool work but not free on very large libraries.
    with _lib_index_lock:
        now = time.time()
        if now - _lib_index_cache["ts"] < 60:
            return _lib_index_cache["index"]
        index = {}
        if SORTED.is_dir():
            for f in walk_files(SORTED):
                try:
                    index.setdefault(f.name, set()).add(f.stat().st_size)
                except OSError:
                    continue
        _lib_index_cache["ts"] = now
        _lib_index_cache["index"] = index
        return index


@app.get("/api/quarantine")
def api_quarantine():
    index = _library_name_sizes()
    files = []
    for f in walk_files(QUAR):
        try:
            st = f.stat()
        except OSError:
            continue
        files.append({"rel": str(f.relative_to(QUAR)), "name": f.name,
                      "date": f.parent.name, "size": st.st_size,
                      "mtime": int(st.st_mtime),
                      "in_library": st.st_size in index.get(f.name, set())})
    files.sort(key=lambda x: x["mtime"], reverse=True)
    return no_store({"files": files[:500]})


@app.post("/api/quarantine/action")
async def api_quarantine_action(request: Request):
    try:
        body = await request.json()
        action = str(body["action"])
        rel = str(body.get("rel", ""))
    except Exception:
        return err("invalid request")
    if action not in ("retry", "trash", "prune_verified"):
        return err("unknown action")

    if action == "prune_verified":
        # Bulk cleanup: delete only held files whose name+size exactly matches a
        # copy already in sorted/. Everything else stays for a human decision.
        index = _library_name_sizes()
        removed = 0
        for f in list(walk_files(QUAR)):
            try:
                if f.is_symlink() or f.stat().st_size not in index.get(f.name, set()):
                    continue
                f.unlink()
                removed += 1
            except OSError:
                continue
        for child in list(QUAR.iterdir()):
            if child.is_dir() and not child.name.startswith("_") and not any(child.iterdir()):
                child.rmdir()
        log.info("quarantine prune_verified: removed %d verified duplicates", removed)
        return no_store({"ok": True, "removed": removed})

    try:
        src = safe_child(QUAR, rel)
    except ValueError:
        return err("bad path")
    if not src.is_file() or src.is_symlink() or "_trash" in src.relative_to(QUAR).parts:
        return err("not an active quarantine file", 404)

    if action == "retry":
        dest = noclobber_move(src, INCOMING, src.name, "r")
        log.info("quarantine retry: %s -> incoming/%s", rel, dest.name)
        return no_store({"ok": True, "moved_to": f"incoming/{dest.name}"})

    dest = noclobber_move(src, (QUAR / "_trash" / rel).parent, src.name, "t")
    log.info("quarantine trash: %s", rel)
    return no_store({"ok": True, "moved_to": f"_trash/{dest.name}"})


# ---------------------------------------------------------- camera registry ----
# Distinct camera bodies seen in the library, so rule scoping offers a
# consistent taxonomy instead of free-typed variants. Labels are composed
# EXACTLY like sort.sh's get_camera (that's the string rules match against).
# Scanning is incremental: one exiftool batch per date-dir, re-run only when
# that day's directory signature changes; results cached per-dir.

CAMERAS_CACHE = PANEL_DIR / "cameras.json"
CAM_SCAN_EXTS = ("nef", "nrw", "arw", "raf", "dng", "cr2", "cr3",
                 "jpg", "jpeg", "heic", "heif", "mp4", "mov", "m4v")
_camera_scan_lock = threading.Lock()
_camera_kick = {"ts": 0.0}


def _camera_label(make: str, model: str) -> str:
    make, model = " ".join(make.split())[:100], " ".join(model.split())[:100]
    head = make.split(" ", 1)[0] if make else ""
    if make and model and model.startswith(head):
        return model
    if make and model:
        return f"{make} {model}"
    return model or "Unknown"


def _dir_sig(day: Path) -> int:
    sig = int(day.stat().st_mtime)
    for t in day.iterdir():
        try:
            if t.is_dir():
                sig = max(sig, int(t.stat().st_mtime))
        except OSError:
            continue
    return sig


def scan_cameras_pass():
    if not _camera_scan_lock.acquire(blocking=False):
        return
    try:
        try:
            cache = json.load(open(CAMERAS_CACHE))
        except Exception:
            cache = {}
        dirs = cache.get("dirs", {}) if isinstance(cache.get("dirs"), dict) else {}
        changed = False
        if SORTED.is_dir():
            for day in SORTED.iterdir():
                if not day.is_dir() or not DATE_RE.match(day.name):
                    continue
                try:
                    sig = _dir_sig(day)
                except OSError:
                    continue
                if dirs.get(day.name, {}).get("sig") == sig:
                    continue
                ext_args = [a for e in CAM_SCAN_EXTS for a in ("-ext", e)]
                try:
                    out = subprocess.run(
                        ["exiftool", "-q", "-fast2", "-T", "-Make", "-Model", "-r",
                         *ext_args, str(day)],
                        capture_output=True, timeout=600).stdout.decode(errors="replace")
                except (subprocess.TimeoutExpired, OSError):
                    continue
                counts: dict[str, int] = {}
                for line in out.splitlines():
                    parts = line.split("\t")
                    make = parts[0] if parts and parts[0] != "-" else ""
                    model = parts[1] if len(parts) > 1 and parts[1] != "-" else ""
                    label = _camera_label(make, model)
                    counts[label] = counts.get(label, 0) + 1
                dirs[day.name] = {"sig": sig, "cameras": counts}
                changed = True
        if changed:
            fd, tmp = tempfile.mkstemp(dir=PANEL_DIR, prefix=".cams.")
            with os.fdopen(fd, "w") as f:
                json.dump({"dirs": dirs, "scanned_at": int(time.time())}, f)
            os.chmod(tmp, 0o664)
            os.replace(tmp, CAMERAS_CACHE)
            log.info("camera registry updated: %d date dirs", len(dirs))
    finally:
        _camera_scan_lock.release()


@app.get("/api/cameras")
def api_cameras():
    # Serve the cache immediately; kick an incremental rescan in the
    # background (single-flight, throttled) so new bodies appear soon after
    # their first upload.
    now = time.time()
    if now - _camera_kick["ts"] > 30:
        _camera_kick["ts"] = now
        threading.Thread(target=scan_cameras_pass, daemon=True).start()
    totals: dict[str, int] = {}
    scanned_at = None
    try:
        cache = json.load(open(CAMERAS_CACHE))
        scanned_at = cache.get("scanned_at")
        for d in cache.get("dirs", {}).values():
            for name, n in d.get("cameras", {}).items():
                if isinstance(n, int):
                    totals[name] = totals.get(name, 0) + n
    except Exception:
        pass
    cams = [{"name": k, "count": v} for k, v in
            sorted(totals.items(), key=lambda kv: -kv[1])][:30]
    return no_store({"cameras": cams, "scanning": _camera_scan_lock.locked(),
                     "scanned_at": scanned_at})


# --------------------------------------------------- lens decisions (ask) ----
# The sorter drops a JSON question into .panel/pending/ when it meets glass no
# rule matches (dumb M-mount adapters, unrecognized smart-adapter strings).
# The panel asks over Telegram with an inline lens menu and mirrors the same
# buttons on the Decisions tab; either answer applies the tags. Unanswered
# questions close after ask_timeout_hours with the file left untouched.

_decision_lock = threading.Lock()


def load_tg() -> dict | None:
    try:
        d = json.load(open(TG_CONFIG))
        token, chat = d.get("bot_token"), str(d.get("chat_id", ""))
        if isinstance(token, str) and token and chat:
            return {"token": token, "chat_id": chat}
    except Exception:
        pass
    return None


def tg_call(tg: dict, method: str, payload: dict, timeout: float = 20) -> dict | None:
    import urllib.request
    req = urllib.request.Request(
        f"https://api.telegram.org/bot{tg['token']}/{method}",
        data=json.dumps(payload).encode(),
        headers={"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            body = json.load(resp)
        return body if body.get("ok") else None
    except Exception:
        return None


def _decision_keyboard(qid: str, presets: list) -> dict:
    rows = [[{"text": p["label"], "callback_data": f"d:{qid}:{i}"}]
            for i, p in enumerate(presets[:10])]
    rows.append([{"text": "Leave as-is", "callback_data": f"d:{qid}:skip"}])
    return {"inline_keyboard": rows}


def apply_preset(path: Path, preset: dict) -> bool:
    args = []
    m = preset.get("lens_model", "")
    if m and MODEL_RE.match(m):
        args.append(f"-EXIF:LensModel={m}")
    i = preset.get("lens_info", "")
    if i and INFO_RE.match(i):
        args.append(f"-EXIF:LensInfo={i}")
    fl = str(preset.get("set_focal_length", ""))
    if fl and FOCAL_RE.match(fl):
        args += [f"-EXIF:FocalLength={fl}", f"-EXIF:FocalLengthIn35mmFormat={fl}"]
    if not args:
        return False
    try:
        return subprocess.run(
            ["exiftool", "-q", "-q", "-overwrite_original", *args, str(path)],
            capture_output=True, timeout=60).returncode == 0
    except (subprocess.TimeoutExpired, OSError):
        return False


def resolve_decision(qid: str, choice: str, via: str) -> dict:
    """choice: 'skip' or a preset index as string. Atomic first-claim wins."""
    if not re.fullmatch(r"[0-9a-f]{16}", qid):
        return {"error": "bad id"}
    src = PENDING / f"{qid}.json"
    claim = RESOLVED / f".claim.{qid}.json"
    with _decision_lock:
        try:
            RESOLVED.mkdir(mode=0o775, exist_ok=True)
            os.rename(src, claim)  # atomic claim; loser sees FileNotFoundError
        except FileNotFoundError:
            return {"error": "already resolved"}
    try:
        q = json.load(open(claim))
    except Exception:
        q = {}
    cfg = load_config()
    outcome = "left unchanged"
    if choice != "skip":
        try:
            preset = cfg["lens_presets"][int(choice)]
            offered = q.get("labels")
            if isinstance(offered, list) and offered[int(choice)] != preset.get("label"):
                raise ValueError("presets changed since asked")
            target = safe_child(SORTED, str(q.get("rel", "")))
            if target.is_file() and target.suffix.lower() in RAW_EXTS and apply_preset(target, preset):
                outcome = f"applied {preset['label']}"
            else:
                outcome = "apply failed — left unchanged"
        except (ValueError, IndexError, KeyError):
            outcome = "bad choice — left unchanged"
    q.update({"outcome": outcome, "via": via, "resolved_ts": int(time.time())})
    with open(claim, "w") as f:
        json.dump(q, f)
    os.replace(claim, RESOLVED / f"{qid}.json")
    log.info("decision %s (%s): %s — %s", qid, via, q.get("rel"), outcome)

    tg = load_tg()
    if tg and q.get("tg_msg_id"):
        tg_call(tg, "editMessageText", {
            "chat_id": tg["chat_id"], "message_id": q["tg_msg_id"],
            "text": f"🔍 {q.get('rel')}\nLens: {q.get('lens')}\n✔ {outcome} (via {via})"})
    return {"ok": True, "outcome": outcome}


def ask_pass():
    cfg = load_config()
    tg = load_tg()
    now = time.time()
    timeout_s = float(cfg.get("ask_timeout_hours", 12)) * 3600
    if not PENDING.is_dir():
        return
    for pf in sorted(PENDING.glob("*.json")):
        qid = pf.stem
        if not re.fullmatch(r"[0-9a-f]{16}", qid):
            continue
        try:
            q = json.load(open(pf))
        except Exception:
            continue
        if now - float(q.get("ts", now)) > timeout_s:
            resolve_decision(qid, "skip", "timeout")
            continue
        if q.get("asked") or not tg:
            continue
        presets = cfg.get("lens_presets", [])
        sent = tg_call(tg, "sendMessage", {
            "chat_id": tg["chat_id"],
            "text": (f"🔍 Unknown lens on {str(q.get('rel', ''))[:200]}\n"
                     f"Camera: {str(q.get('camera') or '—')[:80]}\n"
                     f"Lens: {str(q.get('lens', ''))[:120]}\n"
                     f"LensID: {str(q.get('lensid') or '—')[:120]}\n"
                     f"Which glass was this? (auto-closes in {cfg.get('ask_timeout_hours', 12)}h)"),
            "reply_markup": _decision_keyboard(qid, presets)})
        if sent:
            # Serialize against resolve_decision's claim rename: if the
            # question was answered while sendMessage was in flight, writing
            # here would resurrect a resolved decision.
            with _decision_lock:
                if not pf.exists():
                    continue
                q["asked"] = True
                q["tg_msg_id"] = sent.get("result", {}).get("message_id")
                # Snapshot offered labels: presets may be reordered while the
                # question is open, and callback data is only an index.
                q["labels"] = [p.get("label", "") for p in presets[:10]]
                fd, tmp = tempfile.mkstemp(dir=PENDING, prefix=".a.")
                with os.fdopen(fd, "w") as f:
                    json.dump(q, f)
                os.replace(tmp, pf)


async def ask_loop():
    while True:
        try:
            await asyncio.to_thread(ask_pass)
        except Exception:
            log.exception("ask pass failed")
        await asyncio.sleep(15)


def _tg_poll_once() -> None:
    tg = load_tg()
    if not tg:
        time.sleep(30)
        return
    offset = 0
    try:
        offset = int(TG_OFFSET.read_text().strip())
    except (OSError, ValueError):
        pass
    body = tg_call(tg, "getUpdates", {
        "offset": offset, "timeout": 25, "allowed_updates": ["callback_query"]}, timeout=35)
    if not body:
        time.sleep(10)
        return
    for upd in body.get("result", []):
        offset = max(offset, upd.get("update_id", 0) + 1)
        cb = upd.get("callback_query")
        if not cb:
            continue
        data = str(cb.get("data", ""))
        answer = "?"
        # Only honor buttons pressed in the configured chat.
        if str(cb.get("message", {}).get("chat", {}).get("id", "")) == tg["chat_id"] \
                and data.startswith("d:"):
            parts = data.split(":")
            if len(parts) == 3:
                r = resolve_decision(parts[1], parts[2], "telegram")
                answer = r.get("outcome") or r.get("error") or "done"
        tg_call(tg, "answerCallbackQuery", {"callback_query_id": cb.get("id"), "text": answer[:190]})
    try:
        TG_OFFSET.write_text(str(offset))
    except OSError:
        pass


async def tg_poll_loop():
    while True:
        try:
            await asyncio.to_thread(_tg_poll_once)
        except Exception:
            log.exception("telegram poll failed")
            await asyncio.sleep(15)


@app.get("/api/decisions")
def api_decisions():
    pending, resolved = [], []
    if PENDING.is_dir():
        for pf in sorted(PENDING.glob("*.json")):
            try:
                q = json.load(open(pf))
                q["id"] = pf.stem
                pending.append(q)
            except Exception:
                continue
    if RESOLVED.is_dir():
        hist = sorted((p for p in RESOLVED.glob("*.json") if not p.name.startswith(".")),
                      key=lambda p: p.stat().st_mtime, reverse=True)[:12]
        for pf in hist:
            try:
                resolved.append(json.load(open(pf)))
            except Exception:
                continue
    return no_store({"pending": pending, "resolved": resolved})


@app.post("/api/decision")
async def api_decision(request: Request):
    try:
        body = await request.json()
        qid, choice = str(body["id"]), str(body["choice"])
    except Exception:
        return err("invalid request")
    r = await asyncio.to_thread(resolve_decision, qid, choice, "panel")
    return no_store(r) if "ok" in r else err(r["error"], 409)


# ------------------------------------------------------------ watch funnel ----

async def funnel_loop():
    while True:
        try:
            # Blocking scans/moves belong on the threadpool, not the event loop.
            await asyncio.to_thread(funnel_once)
        except Exception:
            log.exception("funnel pass failed")
        await asyncio.sleep(10)


def funnel_once():
    cfg = load_config()
    if not cfg["features"].get("watch_funnel", True):
        return
    now = time.time()
    for folder in cfg.get("watched_folders", []):
        try:
            root = validate_watch_folder(folder)
        except ValueError:
            continue
        for entry in os.scandir(root):
            try:
                if not entry.is_file(follow_symlinks=False) or entry.name.startswith("."):
                    continue
                st = entry.stat(follow_symlinks=False)
                if now - st.st_mtime < 60:  # let SMB copies settle; sorter re-validates anyway
                    continue
                dest = noclobber_move(Path(entry.path), INCOMING, entry.name, "w")
                log.info("funnel: %s/%s -> incoming/%s", root.name, entry.name, dest.name)
            except OSError:
                continue


# ------------------------------------------------------------------- shell ----

def no_store(payload: dict) -> JSONResponse:
    return JSONResponse(payload, headers={"Cache-Control": "no-store"})


@app.get("/assets/big-shoulders.woff2")
def display_font():
    path = Path(__file__).parent / "assets" / "big-shoulders.woff2"
    if not path.is_file():
        return err("asset missing", 404)
    return FileResponse(path,
                        media_type="font/woff2",
                        headers={"Cache-Control": "public, max-age=31536000, immutable"})


@app.get("/assets/archival-paper.webp")
def archival_paper_texture():
    path = Path(__file__).parent / "assets" / "archival-paper.webp"
    if not path.is_file():
        return err("asset missing", 404)
    return FileResponse(path,
                        media_type="image/webp",
                        headers={"Cache-Control": "public, max-age=31536000, immutable"})


@app.get("/")
def index():
    # no-cache: browsers must revalidate so a redeployed panel shows up on
    # plain reload instead of serving a stale cached shell.
    return FileResponse(Path(__file__).parent / "index.html", media_type="text/html",
                        headers={"Cache-Control": "no-cache"})


@app.on_event("startup")
async def startup():
    # /data is SMB-writable: a symlink pre-planted at .panel would redirect
    # every config write and thumb outside the tree. Refuse to start instead.
    for p in (PANEL_DIR, THUMBS, PENDING, RESOLVED):
        if p.is_symlink():
            raise RuntimeError(f"{p} is a symlink — refusing to start")
    PANEL_DIR.mkdir(mode=0o775, exist_ok=True)
    THUMBS.mkdir(mode=0o775, exist_ok=True)
    PENDING.mkdir(mode=0o775, exist_ok=True)
    RESOLVED.mkdir(mode=0o775, exist_ok=True)
    if not CONFIG_PATH.exists():
        save_config(json.loads(json.dumps(DEFAULT_CONFIG)))
        log.info("seeded default config at %s", CONFIG_PATH)
    cutoff = time.time() - 30 * 86400
    pruned = 0
    for d in (THUMBS, RESOLVED):
        for t in d.iterdir():
            try:
                if t.is_file() and t.stat().st_mtime < cutoff:
                    t.unlink()
                    pruned += 1
            except OSError:
                pass
    if pruned:
        log.info("pruned %d stale cache/history files", pruned)
    loop = asyncio.get_running_loop()
    loop.create_task(funnel_loop())
    loop.create_task(ask_loop())
    loop.create_task(tg_poll_loop())
    log.info("telegram: %s", "connected" if load_tg() else "no config — decisions via UI only")
