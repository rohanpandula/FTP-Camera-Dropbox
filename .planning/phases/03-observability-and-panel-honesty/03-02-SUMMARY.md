---
phase: 03-observability-and-panel-honesty
plan: 02
subsystem: panel
tags: [fastapi, pytest, filecmp, ctime, testclient, honesty-copy]

# Dependency graph
requires: []
provides:
  - "panel/app.py api_status age_s derived from st_ctime (arrival time), not st_mtime (capture time)"
  - "panel/app.py prune_verified byte-compares with filecmp.cmp(shallow=False) before deleting; returns a kept counter"
  - "panel/app.py _library_name_sizes restructured to name -> {size: [paths]} so prune has byte-comparison candidates"
  - "panel/index.html copy that no longer claims a name+size match is an identical copy"
  - "panel/tests/test_quarantine.py — the panel's first pytest suite (4 cases), run against a temporary DATA_ROOT"
  - "panel/.venv-based local test workflow (python3 -m venv panel/.venv + pinned pip install), gitignored"
affects: [04-deploy-and-docs]

# Tech tracking
tech-stack:
  added: [pytest (panel/.venv, dev-only — fastapi/pillow/httpx were already project dependencies)]
  patterns:
    - "TestClient(app.app) built without the `with` context manager so the FastAPI startup hook (funnel_loop/ask_loop/tg_poll_loop) never runs in tests"
    - "os.environ[\"DATA_ROOT\"] set via os.path.realpath(tempfile.mkdtemp()) before `import app`, since DATA_ROOT is read at module import time"
    - "autouse pytest fixture resets the 60s _lib_index_cache before every test to prevent cross-test cache bleed"

key-files:
  created: [panel/tests/test_quarantine.py]
  modified: [panel/app.py, panel/index.html, .gitignore]

key-decisions:
  - "Kept in_library as the cheap name+size hint (D-08); only prune_verified was upgraded to a byte check — matches PRODUCT.md principle 2 without changing the field's meaning"
  - "_library_name_sizes keeps its name, lock, and 60s TTL cache exactly; only the index's per-name value changed from set-of-sizes to {size: [paths]} so prune has candidates to filecmp against"
  - "pip install into panel/.venv required PIP_USER=0 to override a machine-level ~/.config/pip/pip.conf ([global] user = true) that otherwise conflicts with venv installs (\"Can not perform a '--user' install\"); no repo file or global pip config was changed"

patterns-established:
  - "Panel pytest suites live in panel/tests/, use a temp DATA_ROOT set before import, and run via panel/.venv/bin/python -m pytest -q panel/tests"

requirements-completed: [OBS-02, PANEL-01]

# Metrics
duration: ~15min
completed: 2026-09-01
---

# Phase 3 Plan 2: Panel Arrival Age and Byte-Verified Prune Summary

**`age_s` now comes from `st_ctime` (arrival, not capture time); `prune_verified` byte-compares with `filecmp.cmp(shallow=False)` before deleting and reports a `kept` count; all four "identical copy" claims in the UI were rewritten to say what was actually checked; shipped with the panel's first pytest suite (4 cases, TestClient + temp `DATA_ROOT`).**

## Performance

- **Duration:** ~15 min
- **Completed:** 2026-09-01T21:55Z
- **Tasks:** 3/3
- **Files modified:** 4 (panel/app.py, panel/index.html, .gitignore, + panel/tests/test_quarantine.py created)

## Accomplishments
- Fixed the mtime/ctime bug: a freshly dropped RAW carrying an old capture mtime no longer reports hours in intake or trips the derived stuck lamp — `age_s` is now `int(now - st.st_ctime)`.
- `prune_verified` no longer deletes on a name+size match alone. It looks up same-name, same-size candidates from the (restructured) library index and unlinks only when `filecmp.cmp(quar, candidate, shallow=False)` proves at least one candidate byte-identical; survivors are counted in a new `kept` field and left in place. An `OSError` during comparison is treated as "not identical," never as grounds to delete.
- Every panel string that overclaimed verification was rewritten: intake rows say "arrived … ago"; the quarantine badge says "Same name+size filed"; the row detail says "a same-size copy is filed; prune compares bytes before deleting"; the prune bar says "a same-name, same-size copy filed in the library"; the prune toast appends "; kept N whose bytes differed" only when `kept` is nonzero.
- Added `panel/tests/test_quarantine.py`, the panel's first pytest suite: 4 cases proving identical-bytes prune, same-size-different-bytes survival, the `in_library` name+size hint, and ctime-based arrival age — run against a fresh temporary `DATA_ROOT` per test via an autouse fixture.
- Proved the RED gate before touching `app.py` (3 of 4 tests failed against the unmodified code, exactly as the plan predicted) and the GREEN gate after (4 passed).

## Task Commits

Each task was committed atomically:

1. **Task 1: Panel test venv, gitignore, and the four failing quarantine tests** - `8824a0b` (tests: ignore local virtualenvs) — the venv and test file were built and RED-verified in this task, but per CONVENTIONS.md ("tests in the same commit as the code they cover") only `.gitignore` was committed here; `panel/tests/test_quarantine.py` landed in Task 2's commit alongside the code it tests.
2. **Task 2: ctime arrival age and byte-verified prune in panel/app.py** - `ee32eb4` (panel: derive intake age from ctime and byte-verify prune) — includes `panel/tests/test_quarantine.py`.
3. **Task 3: Stop the panel copy overclaiming verification** - `bf387cc` (panel: stop calling a name+size match an identical copy)

**Plan metadata:** SUMMARY.md + REQUIREMENTS.md commit follows this summary (worktree mode — STATE.md/ROADMAP.md are the orchestrator's to update after merge).

## Files Created/Modified
- `panel/app.py` - `age_s` from `st_ctime`; `import filecmp`; `_library_name_sizes` index restructured to `name -> {size: [paths]}`; `api_quarantine`'s `in_library` lookup updated for the new shape (same meaning); `prune_verified` rewritten to byte-compare before unlinking and return `kept`
- `panel/index.html` - four copy-only edits: arrival wording on intake rows, quarantine badge text, quarantine row detail, prune bar sentence, and the prune toast's `kept`-aware message
- `panel/tests/test_quarantine.py` - new; 4 pytest cases against a temporary `DATA_ROOT`, `TestClient(app.app)` built without the context manager
- `.gitignore` - added `.venv*/` (append-only, existing lines untouched)

## Decisions Made
- Left `in_library`/`_library_name_sizes`'s *meaning* untouched (still a name+size hint, per D-08) — only its internal shape changed (set-of-sizes → `{size: [paths]}`) to give `prune_verified` byte-comparison candidates. The honesty fix is entirely in the UI copy and in what `prune_verified` requires before deleting.
- `pip install "fastapi==0.115.*" "pillow==10.*" httpx pytest` into `panel/.venv` failed with `Can not perform a '--user' install` because `~/.config/pip/pip.conf` sets `[global] user = true` machine-wide (a pre-existing dotfile, not part of this repo). Fixed by prefixing the install with `PIP_USER=0` for that one invocation — no change to the global pip config or any repo file. [Rule 3 - Blocking]
- Python 3.14 (via pyenv shim) has no prebuilt Pillow 10.4.0 wheel yet; pip built it from source successfully in the venv. No action needed, noted for reproducibility.

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 3 - Blocking] Overrode a machine-level pip config that broke the venv install**
- **Found during:** Task 1 (venv creation)
- **Issue:** `panel/.venv/bin/pip install "fastapi==0.115.*" "pillow==10.*" httpx pytest` failed immediately with `ERROR: Can not perform a '--user' install. User site-packages are not visible in this virtualenv.` Root cause: `~/.config/pip/pip.conf` has `[global] user = true`, a user-level dotfile unrelated to this repo, forcing `--user` on every pip invocation on this machine — which is incompatible with installing into a venv.
- **Fix:** Re-ran the same install with `PIP_USER=0` prefixed to the command (env vars outrank pip's config-file precedence). No package name, version pin, or repo/global config file was changed.
- **Files modified:** none (env-var-only workaround for the one command)
- **Verification:** `panel/.venv/bin/python -c "import fastapi, PIL, httpx, pytest"` exits 0; versions confirmed within the plan's pins (fastapi 0.115.14, pillow 10.4.0).
- **Committed in:** N/A (no file change; the venv itself is gitignored)

---

**Total deviations:** 1 auto-fixed (1 blocking, environment-only)
**Impact on plan:** No scope change, no file touched outside the plan's stated set. All acceptance criteria and the plan's `<verification>` block pass unmodified.

## Issues Encountered
None beyond the pip config workaround above.

## User Setup Required
None - no external service configuration required.

## Next Phase Readiness
- `panel/app.py`, `panel/index.html`, and `panel/tests/` are ready for Phase 4 (deploy): the panel image Phase 4 rebuilds from the merged branch will carry this ctime/byte-verify behavior with no further code change.
- `panel/.venv` is local-only and gitignored; Phase 4's deploy does not need it (the Dockerfile's runtime deps are unchanged — no new dependency was added).
- No blockers for Plan 03-03 (mirror logging) or Plan 03-01 (healthcheck abort alert) — this plan touched only `panel/app.py`, `panel/index.html`, `panel/tests/`, and `.gitignore`, disjoint from both.

---
*Phase: 03-observability-and-panel-honesty*
*Completed: 2026-09-01*
