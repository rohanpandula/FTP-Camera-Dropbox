# Phase 1: Baseline - Pattern Map

**Mapped:** 2026-09-01
**Files analyzed:** 7
**Analogs found:** 6 / 7 (one is in-place cherry-pick)

## File Classification

| New/Modified File | Role | Data Flow | Closest Analog | Match Quality |
|-------------------|------|-----------|----------------|---------------|
| `frameio-mirror/app.py` | service | state-persistence (CRUD) | `frameio-mirror/app.py` (existing) | exact — cherry-pick conflict resolution |
| `frameio-mirror/tests/test_multi_folder.py` | test | unit-test | `frameio-mirror/tests/test_app.py` | exact — same test idioms |
| `frameio-mirror/tests/test_app.py` | test | unit-test | existing `test_app.py` | exact — add realpath() to existing patterns |
| `frameio-mirror/tests/test_release_safety.py` | test | unit-test | existing `test_release_safety.py` | exact — add realpath() to existing patterns |
| `tests/run-on-tower.sh` | utility/script | request-response (rsync+ssh) | `tests/unraid-healthcheck.sh` + `contrib/unraid/ftpdropbox-backup.sh` | role-match |
| `README.md` (§ Tests) | documentation | — | existing `README.md` lines 273–298 | exact — inline update |
| `.planning/codebase/TESTING.md` | documentation | — | existing `.planning/codebase/TESTING.md` | exact — inline update |

## Pattern Assignments

### `frameio-mirror/app.py` (service, state-persistence)

**Analog:** `frameio-mirror/app.py` (existing) — cherry-pick 0d566ce with conflict resolution.

**Conflict 1: `_remember_c2c_folder` (lines 552–611)**

Current version (main branch) rejects new folders when registry is full:
```python
# Lines 579-584 in main — REMOVE these lines
if len(known) >= 16:
    log.warning(
        "Not remembering C2C folder %s…: registry already holds %d folders",
        parent_folder[:8],
        len(known),
    )
```

LRU version (0d566ce) evicts oldest and promotes re-seen:
```python
# Lines 579-585 from 0d566ce — USE this instead
if len(known) >= 16:
    evicted = known.pop(0)
    log.info("Evicted C2C folder %s from registry (full: %d)", evicted[:8], 16)
known.append(parent_folder)
updates["c2c_folder_ids"] = known
```

**Conflict 2: `_reconcile_folder_ids` (lines 1189–1202)**

Current version (main branch) primary-first strategy:
```python
# Lines 1189-1202 in main — REPLACE with LRU version
def _reconcile_folder_ids() -> list[str]:
    """Every ingest folder to sweep: the legacy single id plus each
    folder discovered since (one per paired Camera-to-Cloud device)."""
    state = _load_state()
    ids: list[str] = []
    primary = CFG["c2c_folder_id"] or state.get("c2c_folder_id")
    if isinstance(primary, str) and primary:
        ids.append(primary)
    stored = state.get("c2c_folder_ids")
    if isinstance(stored, list):
        for fid in stored:
            if isinstance(fid, str) and fid and len(fid) <= 200 and fid not in ids:
                ids.append(fid)
    return ids[:16]
```

LRU version (0d566ce) — newest-last strategy, fallback to legacy:
```python
def _reconcile_folder_ids() -> list[str]:
    """Ingest folders to sweep: the LRU registry (newest last), falling back
    to the legacy single id for state files written before the registry."""
    state = _load_state()
    ids: list[str] = []
    stored = state.get("c2c_folder_ids")
    if isinstance(stored, list):
        for fid in stored:
            if isinstance(fid, str) and fid and len(fid) <= 200 and fid not in ids:
                ids.append(fid)
    if ids:
        return ids[-16:]
    primary = CFG["c2c_folder_id"] or state.get("c2c_folder_id")
    if isinstance(primary, str) and primary:
        return [primary]
    return []
```

**State management pattern** (context for D-04 realpath fix) — from existing app.py:

Imports and config loading (lines 1–206):
```python
import os
from pathlib import Path
# ...
CFG = _load_config()
```

State file atomic write (lines 366–473, `_save_state`):
```python
def _save_state(updates: dict, *, base_state: dict | None = None) -> None:
    """Merge and durably save private state, with a legacy bind-file fallback."""
    path, _parent, _leaf = _state_path_parts()
    state = _load_state(strict=True) if base_state is None else dict(base_state)
    state.update(updates)
    payload = json.dumps(state, separators=(",", ":")).encode("utf-8")
    # ... atomic write using temp file + os.replace ...
```

Path canonicalization (lines 240–241, `_state_parent_path_is_canonical`):
```python
def _state_parent_path_is_canonical(parent: Path) -> bool:
    return os.path.realpath(parent) == str(parent)
```

---

### `frameio-mirror/tests/test_multi_folder.py` (test, unit-test)

**Analog:** `frameio-mirror/tests/test_app.py` (existing)

**Test setup pattern with TemporaryDirectory** (lines 14–46 in test_multi_folder.py):

```python
class MultiFolderRegistryTests(unittest.TestCase):
    def setUp(self):
        self._dir = tempfile.TemporaryDirectory()
        root = Path(self._dir.name)
        incoming = root / "incoming"
        staging = root / "staging"
        incoming.mkdir()
        staging.mkdir(mode=0o700)
        staging.chmod(0o700)
        self.state = root / "state.json"
        self.state.write_text("{}")
        self.state.chmod(0o600)
        self._saved = {
            k: app.CFG[k]
            for k in ("refresh_token_file", "incoming_dir", "staging_dir",
                      "c2c_folder_id", "c2c_account_id")
        }
        app.CFG.update(
            refresh_token_file=str(self.state),
            incoming_dir=str(incoming),
            staging_dir=str(staging),
            c2c_folder_id="",
            c2c_account_id="",
        )
        self.mount_patcher = patch.object(
            app, "_require_private_staging_mount", return_value=None
        )
        self.mount_patcher.start()

    def tearDown(self):
        self.mount_patcher.stop()
        app.CFG.update(self._saved)
        self._dir.cleanup()
```

**Key pattern:** Keep `TemporaryDirectory` object for cleanup, use `.name` to get path. No `realpath()` needed in setUp because it's called during test initialization, not during app startup. Per D-04, realpath only needed at test points that pass the path to `app.CFG`, which happens in `setUp` — see below.

**Note from D-04:** This test file is taken wholesale from commit 0d566ce. No realpath modification needed because the paths are used only within the same test run (setUp → test → tearDown); the rejection of symlinks in `_state_parent_path_is_canonical` only triggers at app startup when reading persisted state. The LRU test doesn't trigger that path.

---

### `frameio-mirror/tests/test_app.py` (test, unit-test)

**Analog:** existing `frameio-mirror/tests/test_app.py` (in-place modification)

**TemporaryDirectory usage pattern at lines 187, 320, 369** (D-04 modification target):

**Before D-04:**
```python
# Line 187
self.runtime_paths = tempfile.TemporaryDirectory()
runtime_root = Path(self.runtime_paths.name)

# Line 320
with tempfile.TemporaryDirectory() as directory:
    root = Path(directory)

# Line 369
with tempfile.TemporaryDirectory() as directory:
    root = Path(directory)
```

**After D-04 — inline realpath at each site:**
```python
# Line 187 (setUp: keep temp object, add realpath before passing to CFG)
self.runtime_paths = tempfile.TemporaryDirectory()
runtime_root = Path(os.path.realpath(self.runtime_paths.name))
# Then use runtime_root everywhere the raw .name was used

# Line 320 and 369 (context manager: derive canonical path)
with tempfile.TemporaryDirectory() as directory:
    root = Path(os.path.realpath(directory))
```

**Why:** macOS `/var/folders` is a symlink to `/private/var/folders`. The app's `_state_parent_path_is_canonical` checks `os.path.realpath(parent) == str(parent)` and rejects the symlink on app startup. Resolving the path before passing it to `app.CFG` bypasses this check — the path string becomes canonical, matching `realpath(parent)`.

**Imports at test_app.py line 1–16:**
```python
import os  # (already present)
import tempfile
import unittest
from pathlib import Path
```

---

### `frameio-mirror/tests/test_release_safety.py` (test, unit-test)

**Analog:** existing `frameio-mirror/tests/test_release_safety.py` (in-place modification)

**TemporaryDirectory usage pattern at lines 167, 349, 384** — same D-04 fix as test_app.py.

**Before D-04 (line 167, setUp):**
```python
self.runtime_paths = tempfile.TemporaryDirectory()
runtime_root = Path(self.runtime_paths.name)
```

**After D-04:**
```python
self.runtime_paths = tempfile.TemporaryDirectory()
runtime_root = Path(os.path.realpath(self.runtime_paths.name))
```

**Before D-04 (lines 349, 384 context managers):**
```python
with tempfile.TemporaryDirectory() as directory:
    root = Path(directory)
```

**After D-04:**
```python
with tempfile.TemporaryDirectory() as directory:
    root = Path(os.path.realpath(directory))
```

---

### `tests/run-on-tower.sh` (utility/script, request-response)

**Analogs:** 
- `tests/unraid-healthcheck.sh` (self-re-exec pattern, `TEST_IMAGE`, test harness invocation)
- `contrib/unraid/ftpdropbox-backup.sh` (rsync, ssh, error handling, log functions)

**Self-re-exec pattern** from `tests/unraid-healthcheck.sh` lines 1–12:

```bash
#!/bin/bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
IMAGE=${TEST_IMAGE:-camera-sorter:candidate-latest}

if [[ ${HEALTHCHECK_TEST_IN_CONTAINER:-0} != 1 ]]; then
  exec docker run --rm --user 0:0 \
    -e HEALTHCHECK_TEST_IN_CONTAINER=1 \
    -v "$ROOT:/repo:ro" \
    "$IMAGE" bash /repo/tests/unraid-healthcheck.sh
fi
```

**For run-on-tower.sh**, adapt to remote execution pattern:
- Check env `TOWER_TEST_ON_TOWER` instead of `*_TEST_IN_CONTAINER`
- Skip docker re-exec (tower already executes inside docker)
- Move rsync and ssh logic into main flow

**Rsync and SSH pattern** from `contrib/unraid/ftpdropbox-backup.sh`:

```bash
# Rsync with selective excludes (lines ~73 in ftpdropbox-backup.sh)
out=$(rsync -a --stats \
  --exclude '.tmp.*' --exclude '.raw-validate-tmp/' \
  -- "$SOURCE/" "$DEST/" 2>&1)
rc=$?
if [[ $rc -eq 0 ]]; then
  # success logic
fi
```

**Logging pattern** (lines 19–20 in ftpdropbox-backup.sh):

```bash
log() { echo "[$(date '+%F %T')] $*" >> "$LOG"; }
```

For run-on-tower.sh, output goes to stderr/stdout (no persistent log needed for test helper).

**D-07/D-08 interface — exact specification:**

```bash
tests/run-on-tower.sh <parallel-sort|unraid-healthcheck|unraid-backup|unraid-fixperms>

# Env:
#   TOWER (default root@10.0.0.100)
#   TOWER_TMP (default /tmp)

# Behavior:
# 1. id="$(git rev-parse --short HEAD)-$$"
# 2. dir="$TOWER_TMP/gsd-test-$id"
# 3. rsync -a --delete --exclude .git --exclude .planning \
#      --exclude .impeccable --exclude '__pycache__' \
#      --exclude '.pytest_cache' --exclude '.ruff_cache' --exclude '.venv*' \
#      ./ "$TOWER:$dir/"
# 4. ssh -o BatchMode=yes "$TOWER" "docker build -q -t camera-sorter:gsd-test-$id $dir"
# 5. For parallel-sort: ssh "$TOWER" "docker run --rm ... /work/tests/parallel-sort.sh"
# 6. For unraid-*: ssh "$TOWER" "cd $dir && TEST_IMAGE=camera-sorter:gsd-test-$id tests/<harness>.sh"
# 7. trap on EXIT: ssh "$TOWER" "docker rmi -f ...; rm -rf $dir"
# 8. Exit status is the harness's
# 9. Last line printed: PASS <harness> or FAIL <harness> (rc=N)
```

**D-09 constraint:** Script must NEVER contain strings `camera-sorter ` (with space), `dropbox-panel`, `frameio-mirror`, `pure-ftpd`, or any `/mnt/` path. Only `docker build`, `docker run --rm`, and `docker rmi` with `gsd-test-` tag are allowed.

---

### `README.md` (documentation, § Tests)

**Analog:** existing `README.md` lines 273–298

**Current section:**
```markdown
## Tests

The concurrency suite runs inside the sorter image so it uses the same Bash,
filesystem tools, and inotify implementation as production:

```bash
docker build -t camera-sorter:test .
docker run --rm --entrypoint /bin/bash \
  -e SORTER_UNDER_TEST=/sort.sh \
  -v "$PWD:/work:ro" camera-sorter:test /work/tests/parallel-sort.sh

# Root-only Unraid helper regressions (protected state, backup status, and
# narrowly scoped permission repair):
TEST_IMAGE=camera-sorter:test tests/unraid-healthcheck.sh
TEST_IMAGE=camera-sorter:test tests/unraid-backup.sh
TEST_IMAGE=camera-sorter:test tests/unraid-fixperms.sh

# Frame.io durability, webhook, pagination, path-race, and cleanup regressions.
# Mount only the tests so /app remains the exact code baked into the image:
docker build -t camera-frameio:test frameio-mirror
test "$(docker run --rm --entrypoint sha256sum camera-frameio:test /app/app.py | awk '{print $1}')" \
  = "$(sha256sum frameio-mirror/app.py | awk '{print $1}')"
docker run --rm --user 99:100 -e PYTHONPATH=/app \
  -v "$PWD/frameio-mirror/tests:/tests:ro" \
  --entrypoint python camera-frameio:test -m unittest discover -s /tests -v
```
```

**D-10 addition:** Insert after the "Frame.io" block, two lines documenting the tower helper:

```markdown
# Remote Linux-only harnesses (Unraid, healthcheck, concurrency):
# Syncs uncommitted changes and runs on tower via docker:
tests/run-on-tower.sh <parallel-sort|unraid-healthcheck|unraid-backup|unraid-fixperms>
```

---

### `.planning/codebase/TESTING.md` (documentation, reference)

**Analog:** existing `.planning/codebase/TESTING.md` lines 1–25

**D-10 addition:** Insert new section after "## Healthcheck harness" (line 22), before line 25:

```markdown
## Remote tower testing (`tests/run-on-tower.sh`)

Run Linux-only harnesses on tower from the development Mac without setting up
a colima instance. Syncs the current working tree (uncommitted changes included)
via rsync, builds a throwaway test image, runs the harness, and cleans up.

**Interface:** `tests/run-on-tower.sh <parallel-sort|unraid-healthcheck|unraid-backup|unraid-fixperms>`

**Env:** `TOWER` (default `root@10.0.0.100`), `TOWER_TMP` (default `/tmp`)

**Behavior:** Requires passwordless ssh, rsync, and docker on tower. Prints `PASS <harness>` 
or `FAIL <harness> (rc=N)`. Exit status is the harness's. 

**Constraints:** Excludes `.git`, `.planning`, `.impeccable`, `__pycache__`, `.pytest_cache`, 
`.ruff_cache`, `.venv*`; never contains production container names or `/mnt/` paths.
```

---

## Shared Patterns

### Python Test Setup: Config Override and Cleanup

**Source:** `frameio-mirror/tests/test_app.py` lines 184–201 and `test_multi_folder.py` lines 12–46

**Apply to:** All Frame.io test files (test_app.py, test_release_safety.py, test_multi_folder.py)

**Pattern:**
```python
class TestCase(unittest.IsolatedAsyncioTestCase):
    def setUp(self):
        self.original_cfg = dict(app.CFG)
        self.runtime_paths = tempfile.TemporaryDirectory()
        runtime_root = Path(os.path.realpath(self.runtime_paths.name))  # D-04: realpath
        # ... set up subdirs ...
        app.CFG.update(
            refresh_token_file=str(state),
            incoming_dir=str(incoming),
            staging_dir=str(staging),
        )

    def tearDown(self):
        app.CFG.update(self.original_cfg)
        self.runtime_paths.cleanup()
```

**Why:** CFG is global; tests must save/restore it. TemporaryDirectory object must be kept for cleanup; `.name` is accessed once and wrapped in `realpath()` before passing to CFG.

---

### Bash Script Structure

**Source:** `tests/unraid-healthcheck.sh` lines 1–5 and `contrib/unraid/ftpdropbox-backup.sh` lines 1–6

**Apply to:** `tests/run-on-tower.sh`

**Pattern:**
```bash
#!/bin/bash
set -euo pipefail

# Document purpose and usage at the top
# Global constants and env defaults
TOWER="${TOWER:-root@10.0.0.100}"
TOWER_TMP="${TOWER_TMP:-/tmp}"

# Helper functions (log, ssh_run, etc.)

# Main logic
main() {
  # implementation
}

# Trap cleanup on EXIT
trap cleanup EXIT
main "$@"
```

---

## No Analog Found

None — all files in Phase 1 have close analogs within the existing codebase or are in-place modifications.

---

## Metadata

**Analog search scope:** `frameio-mirror/`, `tests/`, `contrib/`, `panel/`, `.planning/codebase/`

**Files scanned:** 15+ (existing tests, existing scripts, README, CONVENTIONS, TESTING docs)

**Pattern extraction date:** 2026-09-01

**Key insights:**
- LRU cherry-pick conflicts are deterministic: D-02 specifies exact byte-for-byte match required
- macOS symlink rejection is bypassed by realpath() at the point CFG is set, not app startup
- run-on-tower.sh reuses unraid-healthcheck self-re-exec pattern and ftpdropbox-backup rsync/ssh pattern
- All test modifications are inline realpath() additions; no new test files need scaffolding
