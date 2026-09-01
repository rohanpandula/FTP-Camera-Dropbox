# Phase 3: Observability and Panel Honesty — Pattern Map

**Mapped:** 2026-09-01  
**Files analyzed:** 11 (9 new/modified, 2 new test files)  
**Analogs found:** 11 / 11 (100%)

---

## File Classification

| File | Role | Data Flow | Closest Analog | Match Quality |
|------|------|-----------|----------------|---------------|
| `contrib/unraid/ftpdropbox-healthcheck.sh` | monitoring/ops script | request-response + event-driven | itself (existing functions) | exact |
| `tests/unraid-healthcheck.sh` | bash test harness | test orchestration | itself (case structure) | exact |
| `tests/fixtures/healthcheck/docker` | test stub/fixture | dispatch (case statement) | itself (lines 26–53) | exact |
| `tests/fixtures/healthcheck/curl` | test fixture | log recording | itself (lines 1–8) | exact |
| `panel/app.py` | FastAPI service | CRUD + file inspection | itself (existing endpoints) | exact |
| `panel/index.html` | HTML/JS template | UI rendering | itself (existing markup) | exact |
| `tests/panel-static.sh` | bash static test | contract assertion | itself (lines 1–47) | exact |
| `panel/tests/test_quarantine.py` | pytest suite (new) | async test with fixtures | `frameio-mirror/tests/test_app.py` | role-match |
| `panel/tests/__init__.py` | Python package init | package marker | N/A | N/A |
| `frameio-mirror/app.py` | async logging patterns | structured exception logging | itself (lines 519–535, 1383–1390) | exact |
| `frameio-mirror/tests/test_logging.py` | pytest suite with caplog (new) | exception capture + assertion | `frameio-mirror/tests/test_app.py` + pytest fixtures | role-match |

---

## Pattern Assignments

### Plan A: FTP Abort Alert in Healthcheck

#### `contrib/unraid/ftpdropbox-healthcheck.sh` (monitoring script, request-response + event-driven)

**Analog:** Self — existing functions in the same file

**Reusable function patterns** (lines 32–140):

```bash
# tg() function for Telegram sends — returns 0 on success, 1 on failure
tg() {
  local text=$1 token chat response
  if command -v jq >/dev/null 2>&1; then
    token=$(jq -er '.bot_token | select(type == "string" and length > 0)' \
      "$TG_JSON" 2>/dev/null || true)
    chat=$(jq -er \
      '.chat_id | if type == "number" then tostring elif type == "string" and length > 0 then . else empty end' \
      "$TG_JSON" 2>/dev/null || true)
  else
    # Fallback for systems without jq
    token=$(sed -n 's/.*"bot_token"[^"]*"\([^"]*\)".*/\1/p' "$TG_JSON" 2>/dev/null)
    chat=$(sed -n 's/.*"chat_id"[^"]*"\([^"]*\)".*/\1/p' "$TG_JSON" 2>/dev/null)
  fi
  [ -z "$token" ] || [ -z "$chat" ] && return 1
  response=$(curl -fsS -m 15 -X POST "https://api.telegram.org/bot${token}/sendMessage" \
    --data-urlencode "chat_id=${chat}" --data-urlencode "text=${text}" 2>/dev/null) \
    || return 1
  if command -v jq >/dev/null 2>&1; then
    jq -e '.ok == true' >/dev/null 2>&1 <<< "$response"
  else
    grep -Eq '"ok"[[:space:]]*:[[:space:]]*true' <<< "$response"
  fi
}

# add() function for problem accumulation
add() { problems="${problems}• $1
"; }

# prepare_state_storage() for state file security
prepare_state_storage() {
  local state_dir state_meta
  case "$STATE" in /*/*) ;; *) return 1 ;; esac
  state_dir=${STATE%/*}
  if [[ -e "$state_dir" || -L "$state_dir" ]]; then
    [[ -d "$state_dir" && ! -L "$state_dir" ]] || return 1
  else
    install -d -m 0700 -o 0 -g 0 -- "$state_dir" || return 1
  fi
  state_meta=$(stat -c '%u:%g:%a' -- "$state_dir" 2>/dev/null || true)
  [[ "$state_meta" == "0:0:700" ]] || return 1
}

# docker_cmd() wrapper for timeout + safety
docker_cmd() {
  timeout -k 2 "$DOCKER_TIMEOUT" docker "$@"
}

# resolve_first_container() helper for FTP container name discovery
resolve_first_container() {
  local candidate
  for candidate in $1; do
    if container_exists "$candidate"; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}
```

**FTP probe guard pattern** (lines 220–227):
```bash
# FTP actually listening probe guard — same pattern for abort probe
if [ -n "$ftp_container" ] \
   && [ "$(docker_cmd inspect "$ftp_container" --format '{{.State.Status}}' 2>/dev/null)" = "running" ] \
   && [ "$(uptime_secs "$ftp_container")" -gt "$GRACE" ]; then
  if ! docker_cmd exec "$ftp_container" sh -c \
    "awk 'NR > 1 { split(\$2, a, \":\"); if (a[2] == \"0015\" && \$4 == \"0A\") found=1 } END { exit !found }' /proc/net/tcp /proc/net/tcp6 2>/dev/null"; then
    add "$ftp_container runs but nothing listens on :21 — config or crashed daemon inside container"
  fi
fi
```

**State change alert pattern** (lines 270–285):
```bash
# Alert only on state change
prev=$(cat "$STATE" 2>/dev/null || echo "")
if [ -n "$problems" ]; then
  if [ "$problems" != "$prev" ]; then
    if tg "🔴 Camera pipeline problem(s):
$problems"; then
      commit_state "$problems"
    fi
  fi
else
  if [ -n "$prev" ]; then
    if tg "🟢 Camera pipeline recovered — all checks passing"; then
      commit_state ""
    fi
  fi
fi
```

**Abort probe placement note:** The new abort probe (D-01 through D-04) should be added after the "FTP actually listening" probe block (after line 227), guarded by the same conditions: `$ftp_container` must be set, running, and past grace period. It calls `docker_cmd logs --since "${ABORT_WINDOW:-15m}" "$ftp_container" 2>&1` and parses production log lines directly (see CONTEXT.md D-01). The fingerprint dedup file lives at `${STATE%/*}/ftp-aborts.seen` (same secure parent directory). Abort alerts use `tg()` directly (bypass the `$problems` mechanism per D-03).

---

#### `tests/unraid-healthcheck.sh` (bash test harness)

**Analog:** Self — harness structure

**Test case setup pattern** (lines 19–40):
```bash
new_case() {
  CASE_DIR=$(mktemp -d /tmp/healthcheck-test.XXXXXX)
  install -d -m 0700 -o 0 -g 0 "$CASE_DIR/state" "$CASE_DIR/incoming"
  install -d -m 0700 -o 0 -g 0 "${MAINTENANCE_MARKER%/*}"
  rm -f -- "$MAINTENANCE_MARKER"
  printf '{"bot_token":"test-token","chat_id":-123456}\n' > "$CASE_DIR/tg.json"
  printf '%s\n' "$(date +%s)" > "$CASE_DIR/state/backup.stamp"
  chmod 0600 "$CASE_DIR/tg.json" "$CASE_DIR/state/backup.stamp"
  CURL_LOG="$CASE_DIR/curl.log"
}

run_check() {
  env \
    PATH="$FIXTURES:$PATH" \
    STATE="$CASE_DIR/state/health.state" \
    BACKUP_STAMP="$CASE_DIR/state/backup.stamp" \
    CAMERA_INCOMING="$CASE_DIR/incoming" \
    TG_JSON="$CASE_DIR/tg.json" \
    FAKE_CURL_LOG="$CURL_LOG" \
    "$@" \
    bash "$SCRIPT"
}
```

**Case assertion pattern** (lines 42–46):
```bash
new_case
run_check
[[ ! -e "$CASE_DIR/state/health.state" ]]
[[ ! -e "$CURL_LOG" ]]
echo "PASS: Compose FTP name and absent optional Frame.io are healthy"
```

**Curl log verification pattern** (line 56):
```bash
grep -q -- 'chat_id=-123456' "$CURL_LOG"
```

For abort test cases, assertions will use `grep -q` on `$CURL_LOG` to verify Telegram message text contains expected strings (filename, byte size, KB/s speed).

---

#### `tests/fixtures/healthcheck/docker` (test stub)

**Analog:** Self — dispatch structure

**Current implementation** (lines 26–53):
```bash
case ${1:-} in
  info)
    exit "${FAKE_DOCKER_INFO_RC:-0}"
    ;;
  inspect)
    container=${2:-}
    present "$container" || exit 1
    case "$*" in
      *State.Status*) status_for "$container" ;;
      *State.ExitCode*) printf '%s\n' "${FAKE_EXIT_CODE:-1}" ;;
      *State.StartedAt*) printf '%s\n' '2020-01-01T00:00:00Z' ;;
    esac
    ;;
  start)
    exit "${FAKE_START_RC:-0}"
    ;;
  exec)
    container=${2:-}
    case "$container" in
      camera-ftp|pure-ftpd) exit "${FAKE_FTP_LISTEN_RC:-0}" ;;
      frameio-mirror) exit "${FAKE_FRAMEIO_HEALTH_RC:-0}" ;;
      *) exit 1 ;;
    esac
    ;;
  *)
    exit 64
    ;;
esac
```

**For abort probe:** Add a `logs)` branch before the `*)` default that reads and prints `${FAKE_FTP_LOG_FILE}` if set, or nothing if unset. The script should accept `docker logs --since "..." $container` and output the contents of the file specified in the env var.

---

#### `tests/fixtures/healthcheck/curl` (test fixture)

**Analog:** Self — log recording pattern

**Current implementation** (lines 1–8):
```bash
#!/bin/bash
set -u

if [[ -n ${FAKE_CURL_LOG:-} ]]; then
  printf '%s\n' "$*" >> "$FAKE_CURL_LOG"
fi
printf '%s\n' "${FAKE_CURL_BODY:-{\"ok\":true}}"
exit "${FAKE_CURL_RC:-0}"
```

This stub records the full command line (including `--data-urlencode` arguments) to `$FAKE_CURL_LOG` and returns a mocked response. Test cases verify curl was called with the correct text via grep on this log.

---

### Plan B: Panel Arrival Age and Byte-Verified Prune

#### `panel/app.py` (FastAPI service, CRUD + file inspection)

**Analog:** Self — existing endpoints and patterns

**DATA_ROOT import-time initialization** (line 39):
```python
DATA = Path(os.environ.get("DATA_ROOT", "/data")).resolve()
```

The panel reads `DATA_ROOT` at module import time (before any route handler runs). Tests must set `os.environ["DATA_ROOT"]` before importing the app module (see D-10).

**CSRF guard middleware pattern** (lines 106–120):
```python
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
```

**walk_files() utility** (lines 318–325):
```python
def walk_files(root: Path, skip_hidden_dirs: bool = True):
    if not root.is_dir():
        return
    for dirpath, dirnames, filenames in os.walk(root):
        if skip_hidden_dirs:
            dirnames[:] = [d for d in dirnames if not d.startswith(("_", "."))]
        for name in filenames:
            yield Path(dirpath) / name
```

**api_status() endpoint — age_s computation** (lines 329–344):
```python
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
```

**Note:** D-07 changes `age_s` from `st.st_mtime` to `st.st_ctime` (arrival time, not modification time). The JSON field name stays `age_s`.

**_library_name_sizes() cached index** (lines 600–617):
```python
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
```

**D-09 note:** The index must be extended to map `name -> {size: [paths]}` (or a parallel `name -> [paths]` map) to support byte-comparison during prune. The 60-second cache persists.

**api_quarantine() endpoint** (lines 621–634):
```python
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
```

**api_quarantine_action() — prune_verified branch** (lines 638–665):
```python
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
```

**D-09 note:** The response must change to include a `kept` field for files with matching size but different bytes (after byte comparison is added). Response becomes `{"ok": true, "removed": n, "kept": m}`. Add `# ponytail:` comment noting that prune reads each candidate once and that a hash cache is the upgrade if quarantine ever holds hundreds of RAWs.

---

#### `panel/index.html` (HTML/JS template)

**Analog:** Self — existing markup patterns

**age() utility function** (lines 1096–1101):
```javascript
function age(seconds) {
  if (seconds < 90) return `${seconds}s`;
  if (seconds < 5400) return `${Math.round(seconds / 60)}m`;
  if (seconds < 129600) return `${Math.round(seconds / 3600)}h`;
  return `${Math.round(seconds / 86400)}d`;
}
```

**Incoming intake list** (line 1281):
```html
${inbound ? `<div class="register-list" aria-label="Files currently in intake">${status.incoming.map(file => `<div class="register-row"><div class="row-main"><div class="row-title">${esc(file.name)}</div><div class="row-detail">Waiting or checking · ${age(file.age_s)} in intake</div></div><span class="row-value">${bytes(file.size)}</span></div>`).join("")}</div>` : ""}
```

**D-07 note:** The copy "Waiting or checking · ${age(file.age_s)} in intake" should be updated to say "arrived ... ago" as per decision. Search for `age_s` and `age(` usage in index.html to find all affected locations.

**Quarantine row markup** (line 1335):
```html
<div class="row-main"><div class="row-title">${esc(file.rel)}${file.in_library ? '<span class="dup-flag">Copy in library</span>' : ""}</div><div class="row-detail">${bytes(file.size)} · held ${age(Math.max(0, Math.round(Date.now() / 1000 - file.mtime)))} ago · ${file.in_library ? "an identical copy is already filed" : "no copy found in the library"}</div></div>
```

**D-08 changes:**
- Badge text `Copy in library` → `Same name+size filed`
- Row detail `an identical copy is already filed` → `a same-size copy is filed; prune compares bytes before deleting`

**Prune bar markup** (lines 1343–1348):
```javascript
function pruneBar(files) {
  const verified = files.filter(file => file.in_library).length;
  if (!verified) return "";
  return `<div class="prune-bar"><span>${verified} ${plural(verified, "file")} ${verified === 1 ? "has" : "have"} an identical copy already filed in the library.</span>
    <button class="button danger" type="button" data-quarantine="prune_verified" data-rel="" data-armed="0">Prune verified copies</button></div>`;
}
```

**D-08 changes:**
- Bar sentence: `{n} file(s) have a same-name, same-size copy filed in the library.` (replaces "identical copy")
- Button text stays `Prune verified copies`

**D-09 note on UI state update:** When prune response includes `kept` count (after byte comparison implemented), the toast message (line 1641) should mention kept files:
```javascript
: action === "prune_verified" ? `Pruned ${result.removed} verified duplicate${result.removed === 1 ? "" : "s"} from quarantine`
```
Changes to: `Pruned ${result.removed} verified duplicate...; kept ${result.kept} whose bytes differed` (when `kept > 0`).

---

#### `tests/panel-static.sh` (bash static test)

**Analog:** Self — assertion pattern

**Contract markers** (lines 14–34):
```bash
required = (
    '["now", "Now"]',
    '["library", "Library"]',
    '["attention", "Attention"]',
    '["automations", "Automations"]',
    'overview: "now"',
    'folders: "library"',
    'quarantine: "attention"',
    'rules: "automations"',
    'decisions: "attention"',
    'switches: "automations"',
    'const esc = value =>',
    'data-armed="0"',
    'data-quarantine="prune_verified"',
    'prune_verified',
    '/api/status',
    '/api/library',
    '/api/quarantine',
    '/api/decisions',
    '/api/config',
)
```

**D-08 and D-09 note:** The markers that must remain stable after copy changes:
- `'data-quarantine="prune_verified"'` — button attribute
- `'prune_verified'` — action name
- Existing patterns like `'["attention", "Attention"]'` and `/api/quarantine` must not be removed

---

#### `panel/tests/test_quarantine.py` (pytest suite — new)

**Analog:** `frameio-mirror/tests/test_app.py` (lines 184–199 fixture setup pattern)

**Fixture pattern from frameio tests** (lines 184–199):
```python
class FrameioSafetyTests(unittest.IsolatedAsyncioTestCase):
    def setUp(self):
        self.original_cfg = dict(app.CFG)
        self.runtime_paths = tempfile.TemporaryDirectory()
        runtime_root = Path(os.path.realpath(self.runtime_paths.name))
        runtime_incoming = runtime_root / "incoming"
        runtime_staging = runtime_root / "staging"
        runtime_state = runtime_root / "state.json"
        runtime_incoming.mkdir()
        runtime_staging.mkdir(mode=0o700)
        runtime_staging.chmod(0o700)
        write_private_state(runtime_state)
        app.CFG.update(
            incoming_dir=str(runtime_incoming),
            staging_dir=str(runtime_staging),
            refresh_token_file=str(runtime_state),
```

**D-10 requirements:**
- Set `os.environ["DATA_ROOT"]` to a temp dir **BEFORE importing app** (module-level constants read it)
- Do not rely on the startup hook; create `sorted/2026-01-01/raw/`, `quarantine/2026-01-01/`, and `.panel/` directly in setUp
- Use `fastapi.testclient.TestClient(app)` without context manager
- POST JSON to `/api/quarantine/action` — no Origin header needed (CSRF guard passes curl-style requests)

**Test cases to implement** (per D-10):
1. Identical bytes → `prune_verified` removes file, reports `removed == 1, kept == 0`
2. Same size, different bytes → file survives, `kept == 1`
3. `GET /api/quarantine` marks both as `in_library` true (name+size hint)
4. `GET /api/status` for file in `incoming/` with mtime set 3h back reports `age_s < 60`

**Example setup pattern:**
```python
import os
import tempfile
from pathlib import Path

# MUST set before importing app
os.environ["DATA_ROOT"] = tempfile.mkdtemp()

import app  # Now imports use the test DATA_ROOT

from fastapi.testclient import TestClient

client = TestClient(app.app)
```

---

#### `panel/tests/__init__.py` (Python package init — new)

No analog needed; this file marks the directory as a Python package. It can be empty or contain shared test fixtures.

---

### Plan C: Exception Types in Mirror Logs

#### `frameio-mirror/app.py` (async logging patterns)

**Analog:** Self — existing exception logging

**_tg_send() Telegram exception logging** (lines 519–535):
```python
async def _tg_send(text: str) -> bool:
    """Direct send to Telegram (no throttle). Returns True on success."""
    if not _TG:
        return False
    async with httpx.AsyncClient() as client:
        try:
            resp = await client.post(
                f"https://api.telegram.org/bot{_TG['bot_token']}/sendMessage",
                data={"chat_id": _TG["chat_id"], "text": text},
                timeout=10,
            )
            if resp.status_code == 200:
                return True
            log.warning("Telegram send failed: HTTP %d %s", resp.status_code, resp.text[:200])
        except Exception as exc:
            log.warning("Telegram send exception: %s", exc)
    return False
```

**D-12 change:** Line 534 should become:
```python
log.warning("Telegram send exception: %s: %r", type(exc).__name__, exc)
```

**reconcile_once() listing exception logging** (lines 1383–1390):
```python
    except Exception as exc:
        listing_complete = False
        log.error("Reconcile listing failed: %s", exc)
        await notify_failure(
            "reconcile_list_failed",
            f"Frame.io folder listing raised {type(exc).__name__}; durable jobs will still retry.",
            throttle_minutes=60,
        )
```

**D-12 change:** Line 1385 should become:
```python
log.error("Reconcile listing failed: %s: %r", type(exc).__name__, exc)
```

**Rationale:** httpx timeout exceptions (e.g., `httpx.ReadTimeout("")`) stringify to empty messages; including `type(exc).__name__` and `repr(exc)` preserves diagnostic information (e.g., "ReadTimeout: ReadTimeout()")

---

#### `frameio-mirror/tests/test_logging.py` (pytest suite with caplog — new)

**Analog:** `frameio-mirror/tests/test_app.py` (unittest.IsolatedAsyncioTestCase fixture pattern) + pytest `caplog` fixture

**Fixture setup pattern from frameio tests** (reuse lines 184–199 pattern):
```python
import asyncio
import os
import tempfile
from pathlib import Path
from unittest.mock import patch

import pytest
import app


@pytest.fixture
async def runtime_state():
    """Set up runtime directories and config for test."""
    runtime_root = Path(tempfile.mkdtemp())
    runtime_incoming = runtime_root / "incoming"
    runtime_staging = runtime_root / "staging"
    runtime_state_file = runtime_root / "state.json"
    runtime_incoming.mkdir()
    runtime_staging.mkdir(mode=0o700)
    runtime_state_file.write_text("{}")
    runtime_state_file.chmod(0o600)
    
    original_cfg = dict(app.CFG)
    app.CFG.update(
        incoming_dir=str(runtime_incoming),
        staging_dir=str(runtime_staging),
        refresh_token_file=str(runtime_state_file),
    )
    yield runtime_state_file
    app.CFG.update(original_cfg)
```

**D-13 test case requirements:**

1. **ReadTimeout test** (using `monkeypatch` to raise `httpx.ReadTimeout("")`):
```python
@pytest.mark.asyncio
async def test_reconcile_timeout_logged_with_type(runtime_state, caplog, monkeypatch):
    """Reconcile listing timeout is logged with exception type."""
    import httpx
    
    # Set up minimal state so reconcile_once can reach the listing
    # (see how test_app.py prepares CFG)
    
    monkeypatch.setattr(app, "get_token", side_effect=httpx.ReadTimeout(""))
    
    # Trigger reconcile_once
    await app.reconcile_once()
    
    # Assert "ReadTimeout" appears in logs
    assert "ReadTimeout" in caplog.text
```

2. **ConnectTimeout test** (using `monkeypatch` to raise `httpx.ConnectTimeout("")` on `_tg_send`):
```python
@pytest.mark.asyncio
async def test_telegram_connect_timeout_logged_with_type(caplog, monkeypatch):
    """Telegram send ConnectTimeout is logged with exception type."""
    import httpx
    
    # Set app._TG to enable sends
    app._TG = {"bot_token": "test", "chat_id": "123"}
    
    monkeypatch.setattr(httpx.AsyncClient, "post", side_effect=httpx.ConnectTimeout(""))
    
    result = await app._tg_send("test message")
    
    assert result is False
    assert "ConnectTimeout" in caplog.text
    
    app._TG = None
```

**pytest fixtures available:**
- `caplog` — built-in pytest fixture for capturing log output
- `monkeypatch` — built-in pytest fixture for mocking
- `asyncio.run()` or `@pytest.mark.asyncio` for async tests

---

## Shared Patterns

### State Management and Security

**Source:** `contrib/unraid/ftpdropbox-healthcheck.sh` lines 63–91

**Apply to:** All scripts that write state files

```bash
prepare_state_storage() {
  # Verify state directory is 0700 root:root
  local state_dir state_meta
  case "$STATE" in /*/*) ;; *) return 1 ;; esac
  state_dir=${STATE%/*}
  if [[ -e "$state_dir" || -L "$state_dir" ]]; then
    [[ -d "$state_dir" && ! -L "$state_dir" ]] || return 1
  else
    install -d -m 0700 -o 0 -g 0 -- "$state_dir" || return 1
  fi
  state_meta=$(stat -c '%u:%g:%a' -- "$state_dir" 2>/dev/null || true)
  [[ "$state_meta" == "0:0:700" ]] || return 1
}

commit_state() {
  # Atomic write via mktemp + mv (no clobber)
  local payload=$1 state_tmp
  state_tmp=$(mktemp "${STATE}.tmp.XXXXXX") || return 1
  chmod 0600 -- "$state_tmp" \
    && printf '%s' "$payload" > "$state_tmp" \
    && mv -f -- "$state_tmp" "$STATE" \
    && return 0
  rm -f -- "$state_tmp"
  return 1
}
```

### Exception Logging (Python)

**Source:** `frameio-mirror/app.py` lines 533–534 (being updated per D-12)

**Apply to:** All Python services logging exceptions

```python
# Always log exception type and repr, never bare exception
log.error("Operation failed: %s: %r", type(exc).__name__, exc)
```

Reason: Some exceptions (e.g., httpx timeouts) have empty string representations.

---

## No Analog Found

All files analyzed have clear analogs in the existing codebase or are straightforward new test files following established patterns.

---

## Metadata

**Analog search scope:** `contrib/unraid/`, `tests/`, `panel/`, `frameio-mirror/`, `.planning/codebase/`  
**Files scanned:** 4 existing bash scripts, 2 existing Python services, 1 existing HTML template, 1 existing bash harness, 3 test fixture files, reference docs  
**Pattern extraction date:** 2026-09-01  
**Files with 100% analog coverage:** 11 / 11

---

*Phase: 03-observability-and-panel-honesty*  
*Context gathered: 2026-09-01 by orchestrator*
