---
phase: 01-baseline
plan: 01
subsystem: api
tags: [python, pytest, frameio, cherry-pick, lru-cache]

# Dependency graph
requires: []
provides:
  - "frameio-mirror/app.py and tests/test_multi_folder.py at 0d566ce content (LRU folder registry) on the milestone branch"
  - "Frame.io suite at 57 passed under TMPDIR=/private/tmp, established as the phase baseline"
  - "Default-TMPDIR failure evidence (6 failed, symlink cause) handed to plan 01-02"
affects: [01-02]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "LRU registry: `(known + [parent_folder])[-16:]` eviction, `known.remove()`+append promotion on re-seen folder"
    - "Cherry-pick-as-deliverable-commit: no wrapper commit added around `git cherry-pick`"

key-files:
  created: []
  modified:
    - frameio-mirror/app.py
    - frameio-mirror/tests/test_multi_folder.py

key-decisions:
  - "Cherry-pick applied clean (both pre-image blobs already matched 0d566ce^ exactly) — D-02's conflict-resolution fallback was not needed"
  - "Default-TMPDIR run intentionally left red (6 failed) per D-04/D-05 scope boundary; not fixed in this plan"

patterns-established:
  - "LRU eviction/promotion pattern in _remember_c2c_folder and _reconcile_folder_ids (newest-last, capped at 16)"

requirements-completed: [BASE-01]

# Metrics
duration: 5min
completed: 2026-09-01
---

# Phase 1 Plan 1: Cherry-pick LRU folder registry Summary

**Cherry-picked commit `0d566ce` (LRU C2C folder registry) onto the milestone branch clean, byte-identical to source; Frame.io suite at 57 passed under `TMPDIR=/private/tmp`.**

## Performance

- **Duration:** 5 min
- **Started:** 2026-09-01T20:31:49Z
- **Completed:** 2026-09-01T20:36:59Z
- **Tasks:** 2 completed
- **Files modified:** 2

## Accomplishments
- `frameio-mirror/app.py` and `frameio-mirror/tests/test_multi_folder.py` now byte-identical to commit `0d566ce` on the milestone branch, carried by exactly one cherry-picked commit ahead of `origin/main` that touches `frameio-mirror/`
- `_remember_c2c_folder` evicts `known[0]` at 16 entries and promotes a re-seen folder to newest; `_reconcile_folder_ids` returns the registry newest-last capped at 16, falling back to the legacy single id only when empty
- Frame.io suite established at `57 passed` (`TMPDIR=/private/tmp`), including the two new LRU tests (`test_full_registry_evicts_oldest_for_newest`, `test_reseen_folder_is_promoted_to_newest`)
- Default-TMPDIR failure evidence captured for plan 01-02 (below)

## Task Commits

Each task was committed atomically:

1. **Task 1: Cherry-pick 0d566ce and prove content identity with the LRU commit** - `5b8e2a5` (the cherry-pick's own commit; no wrapper commit added, per plan instruction)
2. **Task 2: Run the Frame.io suite and record the 57-passed baseline** - no code changes; verification only, evidence recorded below and in this SUMMARY

**Plan metadata:** committed alongside this SUMMARY.md

## Files Created/Modified
- `frameio-mirror/app.py` - `_remember_c2c_folder` (LRU evict/promote) and `_reconcile_folder_ids` (newest-last, capped at 16) replaced with the `0d566ce` versions; guards (`isinstance`/non-empty/`len<=200`) and `_state_parent_path_is_canonical` untouched
- `frameio-mirror/tests/test_multi_folder.py` - taken wholesale from `0d566ce` (8 test methods, up from 6); replaces `test_registry_rejects_garbage_and_caps` with `test_registry_rejects_garbage`, `test_full_registry_evicts_oldest_for_newest`, `test_reseen_folder_is_promoted_to_newest`

## Decisions Made
- Cherry-pick applied with zero conflicts, confirmed by the planning-time fact that both pre-image blobs at HEAD already matched `0d566ce^` exactly (`d9c6a68...` for app.py, `f94d539...` for test_multi_folder.py) — verified again immediately before picking. D-02's manual conflict-resolution text was therefore unused.
- Left the default-TMPDIR run red, as instructed by D-04/D-05 scope (owned by plan 01-02); did not touch `_state_parent_path_is_canonical`.

## Deviations from Plan

None - plan executed exactly as written. Both tasks matched their `<action>` and `<acceptance_criteria>` with no conflict-resolution fallback, no auto-fixes, and no scope changes.

## Issues Encountered

None materially — one environmental note: this Bash tool's shell has no `TMPDIR`/`TEMP`/`TMP` preset, so `unset TMPDIR` (used in place of the sandbox-blocked `env -u TMPDIR`) made Python's `tempfile` fall back to `/tmp` rather than the `/var/folders/...` path a normal interactive Terminal session would show. `/tmp` is itself a symlink to `/private/tmp` on macOS, so the failure mode (`_state_parent_path_is_canonical` rejecting a non-canonical parent) and the exact log-line prefix are unaffected; only the captured path differs from the planning doc's example. Recorded verbatim below.

## Verification Evidence

**Blob identity (D-02/D-03, both match `0d566ce` exactly):**
- `git rev-parse HEAD:frameio-mirror/app.py` → `ce188d7ee53831d3eb8dbf8433a15dcfbc25e3bd`
- `git rev-parse HEAD:frameio-mirror/tests/test_multi_folder.py` → `aadaa89569e99a9629aeb30457bcb3ab0faa8a3b`
- `git diff 0d566ce HEAD -- frameio-mirror/app.py frameio-mirror/tests/test_multi_folder.py` → no output
- `git log --oneline origin/main..HEAD --no-merges -- frameio-mirror/ | wc -l` → `1`
- `git branch --list fix/frameio-folder-lru` still present; `git rev-parse fix/frameio-folder-lru` still `0d566ce0e78fd634f39e376cf059a66a7846d59d` (untouched)

**Frame.io suite, `TMPDIR=/private/tmp` (D-03 acceptance number):**
```
57 passed, 5 subtests passed in 0.41s
```
- `tests/test_multi_folder.py` alone: `8 passed in 0.09s`
- The two new LRU tests alone: `2 passed in 0.08s`

**Default-TMPDIR "before" evidence for plan 01-02 (D-04/D-05 not yet applied):**
```
6 failed, 51 passed, 5 subtests passed in 0.53s
```
Failing tests, all in `test_multi_folder.py`: `test_first_discovery_sets_legacy_and_list`, `test_full_registry_evicts_oldest_for_newest`, `test_registry_merges_legacy_only_state`, `test_registry_rejects_garbage`, `test_reseen_folder_is_promoted_to_newest`, `test_second_camera_folder_extends_registry`. That is 2 more failures than the pre-pick baseline (4 of 6 tests) recorded in `01-01-PLAN.md`'s `facts_verified_at_planning_time`, because the pick added 2 new tests that also persist state and thus hit the same guard.

Verbatim symlink line (path differs from the `/var/folders/...` example in the plan only because this shell had no `TMPDIR`/`TEMP`/`TMP` preset — see Issues Encountered):
```
WARNING  frameio-mirror:app.py:357 Failed to read state file /tmp/tmp5gk1p0pn/state.json: [Errno 1] state parent contains a symlink: '/tmp/tmp5gk1p0pn'
```
and, from a persistence path:
```
WARNING  frameio-mirror:app.py:601 Could not persist C2C reconciliation state ([Errno 1] state parent contains a symlink: '/tmp/tmpibyc3x99'); continuing this download
```

**Owner of the fix:** plan 01-02 (BASE-02, D-04/D-05) — resolve every `tempfile.TemporaryDirectory()` path with `os.path.realpath(...)` before handing it to the app as `REFRESH_TOKEN_FILE`/`STAGING_DIR`/`INCOMING_DIR`, per `01-CONTEXT.md`.

## User Setup Required

None - no external service configuration required.

## Next Phase Readiness
- Plan 01-02 (BASE-02) can proceed directly: the exact failure list and cause (non-canonical `TMPDIR` parent) are recorded above, and the fix sites (`test_multi_folder.py:14`, `test_app.py:187,320,369`, `test_release_safety.py:167,349,384`) are already identified in `01-CONTEXT.md` D-04.
- No blockers. `fix/frameio-folder-lru` remains untouched at `0d566ce` for reference.

---
*Phase: 01-baseline*
*Completed: 2026-09-01*

## Self-Check: PASSED

- FOUND: `.planning/phases/01-baseline/01-01-SUMMARY.md`
- FOUND: commit `5b8e2a5` (Task 1 cherry-pick)
- FOUND: commit `eaf377c` (plan metadata: SUMMARY.md + REQUIREMENTS.md)
