---
phase: 03-observability-and-panel-honesty
plan: 03
subsystem: observability
tags: [python, httpx, pytest, logging, frameio-mirror]

# Dependency graph
requires:
  - phase: 01-baseline
    provides: "BASE-02: Frame.io test suite resolves temp dirs with os.path.realpath, so pytest runs on macOS with the default TMPDIR"
provides:
  - "frameio-mirror/app.py: both blind exception-logging sites (_tg_send, reconcile_once) render '%s: %r' with type(exc).__name__, so an httpx timeout with an empty str() is still attributable"
  - "frameio-mirror/tests/test_logging.py: two regression tests pinning that behavior for ReadTimeout and ConnectTimeout"
affects: [phase-4-deploy, frameio-mirror-rebuild]

# Tech tracking
tech-stack:
  added: []
  patterns: ["log exceptions as '%s: %r' with type(exc).__name__ (CONVENTIONS.md Python) — now applied at all sites, not just notify_failure's operator-facing text"]

key-files:
  created: [frameio-mirror/tests/test_logging.py]
  modified: [frameio-mirror/app.py]

key-decisions: []

patterns-established: []

requirements-completed: [OBS-03]

# Metrics
duration: ~10min
completed: 2026-09-01
---

# Phase 3 Plan 03: Exception Types in Mirror Logs Summary

**Both frameio-mirror exception-logging blind spots (reconcile listing, Telegram send) now render `ClassName: repr(exc)` instead of a bare `%s`, so an httpx timeout with an empty message stays diagnosable; two new pytest regression tests pin the behavior and the full 59-test suite is green.**

## Performance

- **Duration:** ~10 min
- **Completed:** 2026-09-01T21:51:37Z
- **Tasks:** 2
- **Files modified:** 2

## Accomplishments
- Reproduced the exact 2026-08-23 production symptom locally: `reconcile_once` under a monkeypatched `httpx.ReadTimeout("")` logged `Reconcile listing failed: ` with nothing after the colon (RED gate, confirmed via test run before any fix).
- Rewrote both log sites (`_tg_send` line 534, `reconcile_once` line ~1385) to `"...: %s: %r", type(exc).__name__, exc` per CONVENTIONS.md § Python and D-12 — a 4-line diff (2 changed log lines + a 2-line why-comment), nothing else in `app.py` touched.
- Added `frameio-mirror/tests/test_logging.py` with two plain-pytest, `asyncio.run`-driven regression tests (no `pytest-asyncio`, no new dependency) that fail against the old format and pass against the new one.
- Full Frame.io suite: 59 passed (57 pre-existing + 2 new), no `TMPDIR` override, on macOS.

## Task Commits

1. **Task 1: Two failing tests for empty-message exceptions** — folded into the Task 2 commit below (no standalone commit). CONVENTIONS.md § Tests requires tests to land in the same commit as the code they cover, and the plan's Task 1 action explicitly says "Do not commit in this task." RED was still verified as a distinct gate: `python3 -m pytest -q tests/test_logging.py` was run against the unmodified `app.py` and both tests failed with the exact production symptom (`AssertionError: assert 'ReadTimeout' in 'ERROR ... Reconcile listing failed: \n'` and the equivalent for `ConnectTimeout`/`Telegram send exception:`), confirming the tests exercise real behavior before any fix existed.
2. **Task 2: Log the exception type and repr at both blind sites** - `8aa466d` (feat, code+tests combined per CONVENTIONS.md § Tests)

**Plan metadata:** committed alongside this SUMMARY (worktree mode — STATE.md/ROADMAP.md excluded, orchestrator updates those after merge).

_Note: This plan's Task 1 was `tdd="true"` but the plan explicitly overrides the default separate RED-commit pattern in favor of the project's single-commit convention; RED was verified by running the suite, not by a `test(...)` commit. See "TDD Gate Compliance" below._

## Files Created/Modified
- `frameio-mirror/tests/test_logging.py` - Two regression tests: `test_reconcile_listing_failure_names_the_exception_type` (monkeypatches `app.get_token` to raise `httpx.ReadTimeout("")`, seeds the folder registry via `app._save_state`, asserts `"ReadTimeout"` and `"Reconcile listing failed"` in `caplog.text`) and `test_telegram_send_failure_names_the_exception_type` (monkeypatches `httpx.AsyncClient.post` to raise `httpx.ConnectTimeout("")`, asserts `result is False` and `"ConnectTimeout"`/`"Telegram send exception"` in `caplog.text`).
- `frameio-mirror/app.py` - Line 534 (`_tg_send`) and line ~1387 (`reconcile_once`, after the added comment) now log `"%s: %r", type(exc).__name__, exc` instead of bare `"%s", exc`. A two-line comment above the reconcile site names the 2026-08-23 failure. No other line in the file changed.

## Decisions Made
None - followed plan (D-12, D-13) as specified.

## Deviations from Plan

None - plan executed exactly as written. Every acceptance criterion in both tasks passed on first attempt; no auto-fixes, no blocked package installs, no architectural questions.

## TDD Gate Compliance

This plan is `type: execute` (not `type: tdd`), so the plan-level RED/GREEN/REFACTOR git-log gate does not apply. Task 1 individually carried `tdd="true"`, and its own `<action>` text explicitly instructed no commit ("tests land in the same commit as the code they cover, which is Task 2") — overriding the generic two-commit TDD default in favor of CONVENTIONS.md § Git/§ Tests ("tests in the same commit as the code they cover"). RED was verified empirically (test run against unmodified `app.py`, 2 failures reproducing the exact production log text) rather than via a separate `test(...)` commit; GREEN was verified the same way (test run + full suite) immediately before the single combined commit. No gap in verification, just a single commit object instead of two.

## Issues Encountered
None. Every fact asserted in the plan's `<interfaces>` block (line numbers, function signatures, `_prune_retained_assets` early return, `notify_failure`'s immediate return when `_TG` is falsy, `_pending_downloads`/`_pending_publications` tolerating a minimal state file) checked out exactly against the current `app.py` before writing any code.

## User Setup Required
None - no external service configuration required. Note for Phase 4: this is a log-format-only change to `frameio-mirror`; the running container on tower needs a redeploy on its next rebuild to pick it up (per PROJECT.md "Out of Scope" — rebuilding the container is explicitly deferred, commands recorded for Phase 4).

## Next Phase Readiness
OBS-03 is complete and marked in REQUIREMENTS.md (only the OBS-03 line touched — OBS-01, OBS-02, PANEL-01 are owned by sibling plans 03-01/03-02 in this same wave). Nothing here blocks Phase 4 deploy; the mirror container simply needs to be rebuilt from the merged milestone branch to pick up the log-format change, which Phase 4 already accounts for.

---
*Phase: 03-observability-and-panel-honesty*
*Completed: 2026-09-01*

## Self-Check: PASSED

- FOUND: frameio-mirror/tests/test_logging.py
- FOUND: .planning/phases/03-observability-and-panel-honesty/03-03-SUMMARY.md
- FOUND: commit 8aa466d (frameio-mirror: log exception type and repr...)
- FOUND: commit 43eeb95 (docs(03-03): complete exception-type mirror logging plan)
