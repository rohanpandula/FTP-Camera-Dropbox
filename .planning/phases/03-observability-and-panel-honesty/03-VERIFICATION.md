---
phase: 03-observability-and-panel-honesty
verified: 2026-09-01T22:03:59Z
status: passed
score: 15/15 must-haves verified
overrides_applied: 0
---

# Phase 3: Observability and Panel Honesty Verification Report

**Phase Goal:** Every aborted FTP upload reaches Telegram once, the panel reports arrival age truthfully, mirror failures are diagnosable from the log, and "verified" means bytes matched.
**Verified:** 2026-09-01T22:03:59Z
**Status:** passed
**Re-verification:** No — initial verification

## Goal Achievement

### Observable Truths

| # | Truth | Status | Evidence |
|---|-------|--------|----------|
| 1 | (SC1) One healthcheck run over stubbed `docker logs` containing one `451-Transfer aborted` sequence sends one Telegram message naming file, MB received, KB/s; a second run over the same state sends nothing new | ✓ VERIFIED | `contrib/unraid/ftpdropbox-healthcheck.sh:245-282` implements the probe exactly as specified; `tests/unraid-healthcheck.sh` Case 1/2 assert this; proven end-to-end on tower via `tests/run-on-tower.sh unraid-healthcheck` — `/tmp/gsd-hc-merge.log` shows `PASS: an aborted upload alerts once with file, size and speed` and `PASS: a repeated abort in the next window is not re-sent`, 23 `PASS:` lines total, final line `PASS unraid-healthcheck` |
| 2 | A log containing only `226-File successfully transferred` sends nothing | ✓ VERIFIED | `tests/unraid-healthcheck.sh` Case 3; tower log: `PASS: a completed upload sends no abort alert` |
| 3 | Two aborts inside one window produce two distinct messages | ✓ VERIFIED | `tests/unraid-healthcheck.sh` Case 4 (DSC01932.ARW / DSC01931.ARW); tower log: `PASS: two aborts in one window send two messages` |
| 4 | An unpaired abort (no preceding NOTICE) still alerts, using "unknown file" and the 451 timestamp | ✓ VERIFIED | `tests/unraid-healthcheck.sh` Case 5 (orchestrator addition for the D-03 fallback path); tower log: `PASS: unpaired abort alerts as unknown file` |
| 5 | (D-03) The abort probe never adds a line to `$problems` and never calls `commit_state` — an abort is an event, not persistent state | ✓ VERIFIED | `grep -c 'add "' contrib/unraid/ftpdropbox-healthcheck.sh` = 18 (unchanged from pre-phase baseline); `grep -c 'commit_state ' ...` = 2 (unchanged); probe block sends via `tg "$message"` directly |
| 6 | (D-04) An unresolved FTP container or a failing `docker logs` produces no alert and no problem line, and never changes the script's exit status | ✓ VERIFIED | `ftp_log=$(docker_cmd logs --since "$ABORT_WINDOW" "$ftp_container" 2>&1 \|\| true)`; block gated on `$ftp_container` non-empty + `running`; empty capture short-circuits (`if [ -n "$ftp_log" ]`); all 18 pre-existing harness cases (container-down, wedged Docker, etc.) still pass unchanged |
| 7 | (SC2) `/api/status` reports `age_s` from ctime; a file with an old mtime dropped moments ago shows a small age | ✓ VERIFIED | `panel/app.py:349` `"age_s": int(now - st.st_ctime)`; `panel/tests/test_quarantine.py::test_status_age_s_is_arrival_time` sets mtime 3h back via `os.utime`, asserts `age_s < 60`; `panel/.venv/bin/python -m pytest -q panel/tests` → 4 passed |
| 8 | (SC3a) `frameio-mirror` log lines for a failed reconcile listing include the exception class name even when `str(exc)` is empty | ✓ VERIFIED | `frameio-mirror/app.py:1387` `log.error("Reconcile listing failed: %s: %r", type(exc).__name__, exc)`; `test_reconcile_listing_failure_names_the_exception_type` monkeypatches `httpx.ReadTimeout("")` and asserts `"ReadTimeout" in caplog.text` |
| 9 | (SC3b) `frameio-mirror` log lines for a failed Telegram send include the exception class name even when `str(exc)` is empty | ✓ VERIFIED | `frameio-mirror/app.py:534` `log.warning("Telegram send exception: %s: %r", type(exc).__name__, exc)`; `test_telegram_send_failure_names_the_exception_type` monkeypatches `httpx.ConnectTimeout("")`, asserts `"ConnectTimeout" in caplog.text` |
| 10 | (D-12) Log sites that already pass `exc_info=True` are unchanged | ✓ VERIFIED | Lines 1458 (`Reconcile loop exception`) and 3881 (`Unexpected error processing asset`) still use bare `%s` + `exc_info=True`, untouched; `git diff` for the fix commit (`8aa466d`) touches only 4 added / 2 deleted lines in `frameio-mirror/app.py` |
| 11 | (SC4) `prune_verified` deletes a quarantined file only when a same-name library file is byte-identical; a same-size different-bytes file survives | ✓ VERIFIED | `panel/app.py:661-694`: `filecmp.cmp(f, candidate, shallow=False)` gates every unlink; `OSError` during comparison treated as "not identical"; `test_prune_verified_removes_identical_bytes` (removed=1, kept=0) and `test_prune_verified_keeps_same_size_different_bytes` (removed=0, kept=1, file still exists) both pass |
| 12 | The prune response carries `kept`, counting same-size files whose bytes differed | ✓ VERIFIED | `panel/app.py:694` returns `{"ok": True, "removed": removed, "kept": kept}`; UI toast at `panel/index.html:1641` reads `result.kept` |
| 13 | No panel copy claims a name+size match is an identical copy (PRODUCT.md principle 2) | ✓ VERIFIED | `grep -c "identical copy" panel/index.html` = 0; `grep -c "Copy in library"` = 0; badge now "Same name+size filed", row detail "a same-size copy is filed; prune compares bytes before deleting", prune bar "a same-name, same-size copy filed in the library.", intake rows "arrived … ago" |
| 14 | `tests/panel-static.sh` still passes after the copy changes | ✓ VERIFIED | Ran `tests/panel-static.sh` → `panel static checks passed`, exit 0; all 19 required markers, `node --check`, no inline handlers, no `style=` |
| 15 | The existing 57 Frame.io tests still pass with no `TMPDIR` override, plus the 2 new logging tests | ✓ VERIFIED | Ran `cd frameio-mirror && python3 -m pytest -q` → `59 passed, 5 subtests passed` |

**Score:** 15/15 truths verified

### Required Artifacts

| Artifact | Expected | Status | Details |
|----------|----------|--------|---------|
| `contrib/unraid/ftpdropbox-healthcheck.sh` | FTP abort probe with fingerprint dedup, `ABORT_WINDOW` knob, updated header | ✓ VERIFIED | 346 lines; probe block at 245-282; `ABORT_WINDOW="${ABORT_WINDOW:-15m}"` at line 40 with charset validation and self-heal to `15m`; header (lines 6-9) documents the alert and the knob |
| `tests/fixtures/healthcheck/docker` | `logs` subcommand driven by `FAKE_FTP_LOG_FILE` | ✓ VERIFIED | `logs)` branch added before the `*) exit 64` default; `cat -- "$FAKE_FTP_LOG_FILE"` when set and readable, silent + exit 0 otherwise; `bash -n` clean |
| `tests/unraid-healthcheck.sh` | 5 new abort cases on top of the existing 18 (23 total) | ✓ VERIFIED | `grep -c '^echo "PASS:'` = 23; all 5 new cases match the plan's specified fixtures and assertions verbatim |
| `panel/app.py` | ctime-derived age, byte-verified prune, `kept` counter | ✓ VERIFIED | `st.st_ctime` (1), `filecmp.cmp(...shallow=False)` (1), `kept` (4 occurrences: variable, log, response, comment) |
| `panel/index.html` | Honest quarantine copy and arrival-age wording | ✓ VERIFIED | All 4 copy edits present verbatim; `identical copy` count 0; `tests/panel-static.sh` passes |
| `panel/tests/test_quarantine.py` | 4 pytest cases over a temporary `DATA_ROOT` | ✓ VERIFIED | 4 test functions, `DATA_ROOT` set via `os.path.realpath(tempfile.mkdtemp())` before `import app`, autouse fixture resets `_lib_index_cache`; `4 passed` |
| `.gitignore` | Local virtualenvs stay out of git | ✓ VERIFIED | `.venv*/` present at line 11; `git check-ignore -q panel/.venv` exits 0; `git status --porcelain panel/.venv` empty |
| `frameio-mirror/app.py` | Type-and-repr exception logging at the two blind sites | ✓ VERIFIED | Both sites render `%s: %r` with `type(exc).__name__`; scoped diff (4 add / 2 del) |
| `frameio-mirror/tests/test_logging.py` | Two regression tests for empty-message exceptions | ✓ VERIFIED | 2 `def test_` functions, no `pytest.mark.asyncio`/`pytest_asyncio`, `asyncio.run`-driven; both pass |

### Key Link Verification

| From | To | Via | Status | Details |
|------|-----|-----|--------|---------|
| abort probe | `tg()` | Direct call bypassing `$problems`/`commit_state` | ✓ WIRED | `tg "$message"` called directly inside the probe block; `add "`/`commit_state ` counts unchanged from baseline |
| abort probe | `docker logs` | `docker_cmd logs --since` | ✓ WIRED | `ftp_log=$(docker_cmd logs --since "$ABORT_WINDOW" "$ftp_container" 2>&1 \|\| true)` |
| `tests/unraid-healthcheck.sh` | `tests/fixtures/healthcheck/docker` | `FAKE_FTP_LOG_FILE` env passed through `run_check` | ✓ WIRED | 6 occurrences of `FAKE_FTP_LOG_FILE=` passed to `run_check`; stub reads the same variable |
| `panel/app.py prune_verified` | `filecmp` | `shallow=False` byte comparison before unlink | ✓ WIRED | `filecmp.cmp(f, candidate, shallow=False)` gates every `f.unlink()` |
| `panel/app.py api_status` | `os.stat st_ctime` | `age_s` computation | ✓ WIRED | `int(now - st.st_ctime)`; consumed by both the JSON response and the derived-health branch |
| `panel/index.html quarantineAction` | `/api/quarantine/action` response | `result.kept` read in the toast | ✓ WIRED | `${result.kept ? `; kept ${result.kept} whose bytes differed` : ""}` |
| `panel/tests/test_quarantine.py` | `panel/app.py` | `DATA_ROOT` set before import, `TestClient(app.app)` | ✓ WIRED | `os.environ["DATA_ROOT"]` set on line 15, `import app` on line 19 |
| `frameio-mirror/app.py reconcile_once` | `log.error` | `%s: %r` with `type(exc).__name__` and `exc` | ✓ WIRED | Line 1387, format string matches exactly |
| `frameio-mirror/app.py _tg_send` | `log.warning` | `%s: %r` with `type(exc).__name__` and `exc` | ✓ WIRED | Line 534, format string matches exactly |
| `frameio-mirror/tests/test_logging.py` | `frameio-mirror/app.py` | Monkeypatched `get_token` / `httpx.AsyncClient.post` raising empty-message timeouts | ✓ WIRED | `monkeypatch.setattr(app, "get_token", ...)` and `monkeypatch.setattr(httpx.AsyncClient, "post", ...)`; both tests pass |

### Data-Flow Trace (Level 4)

| Artifact | Data Variable | Source | Produces Real Data | Status |
|----------|---------------|--------|---------------------|--------|
| `panel/app.py api_status` | `age_s` | `os.stat(f).st_ctime` on real files under `INCOMING` | Yes — real filesystem stat, no static fallback | ✓ FLOWING |
| `panel/app.py prune_verified` | `identical` / `removed` / `kept` | `filecmp.cmp()` against real candidate files resolved from `_library_name_sizes()` walking `SORTED` | Yes — real byte comparison, `OSError` fails safe to "not identical" | ✓ FLOWING |
| `contrib/unraid/ftpdropbox-healthcheck.sh` abort probe | `ftp_log` | `docker_cmd logs --since "$ABORT_WINDOW" "$ftp_container"` (real container log in production; `FAKE_FTP_LOG_FILE`-driven stub in tests) | Yes — production path reads the live pure-ftpd container log; test path is a faithful stand-in exercised on tower | ✓ FLOWING |
| `frameio-mirror/app.py` log lines | `type(exc).__name__`, `exc` | The actual raised exception object at each call site | Yes — not a static string; verified with real `httpx.ReadTimeout`/`ConnectTimeout` instances in tests | ✓ FLOWING |

### Behavioral Spot-Checks

| Behavior | Command | Result | Status |
|----------|---------|--------|--------|
| `bash -n` on both healthcheck scripts + docker stub | `bash -n contrib/unraid/ftpdropbox-healthcheck.sh; bash -n tests/unraid-healthcheck.sh; bash -n tests/fixtures/healthcheck/docker` | All exit 0 | ✓ PASS |
| Panel pytest suite | `panel/.venv/bin/python -m pytest -q panel/tests` | `4 passed, 17 warnings` | ✓ PASS |
| Panel static contract | `tests/panel-static.sh` | `panel static checks passed`, exit 0 | ✓ PASS |
| Frame.io mirror full suite | `cd frameio-mirror && python3 -m pytest -q` | `59 passed, 5 subtests passed` | ✓ PASS |
| Scope check — only declared files touched | `git diff bf0e964..595bc75 --stat` (Phase-2-end to Phase-3-end) | Exactly the 9 files declared across the three plans' `files_modified` (10th, `panel/tests/__init__.py`, was correctly not created — collection works without it) | ✓ PASS |

### Probe Execution

No `scripts/*/tests/probe-*.sh` convention exists in this project (searched, none found). This project uses its own `tests/*.sh` harness convention instead, covered under Behavioral Spot-Checks and the tower run below.

**Tower harness (sanctioned remote check, run by the orchestrator per task instructions — not re-run by this verifier):**

| Probe | Command | Result | Status |
|-------|---------|--------|--------|
| `unraid-healthcheck` (merged tree) | `tests/run-on-tower.sh unraid-healthcheck` | Final line `PASS unraid-healthcheck`; `grep -c '^PASS:' ` = 23 (all 18 pre-existing + 5 new abort cases); log at `/tmp/gsd-hc-merge.log`, timestamp `Tue Sep 1 14:59:01 2026` | PASS |

This is accepted as the authoritative evidence for ROADMAP success criterion 1, per the verification task's explicit instruction not to re-run the harness locally (it only runs inside the sorter image on tower). `03-01-SUMMARY.md` independently records two earlier tower passes (untimed + timed, both `PASS unraid-healthcheck`, 23/23 `PASS:` lines) taken before the merge, consistent with this post-merge run.

### Requirements Coverage

| Requirement | Source Plan | Description | Status | Evidence |
|-------------|-------------|--------------|--------|----------|
| OBS-01 | 03-01-PLAN.md | Healthcheck alerts once per aborted FTP upload, deduplicated via fingerprint file, docker stub `logs` subcommand added | ✓ SATISFIED | Probe code, 5 harness cases, tower proof (23 `PASS:` lines, `PASS unraid-healthcheck`) |
| OBS-02 | 03-02-PLAN.md | Panel `/api/status` derives `age_s` and derived health lamp from `st_ctime`; UI copy says "arrived" | ✓ SATISFIED | `st.st_ctime` in code; `test_status_age_s_is_arrival_time` passes; `panel/index.html` line 1281 reads "arrived … ago" |
| OBS-03 | 03-03-PLAN.md | Mirror logs exception type + repr for reconcile-listing and Telegram-send failures; unit test for empty-`str()` exceptions | ✓ SATISFIED | Both log sites rewritten; 2 regression tests pass; full suite 59 passed |
| PANEL-01 | 03-02-PLAN.md | `in_library`/`prune_verified` compare bytes via `filecmp.cmp(shallow=False)`; pytest with TestClient + temp `DATA_ROOT` proves both paths | ✓ SATISFIED | `filecmp.cmp` gates every unlink; `kept` counter; 2 dedicated pytest cases + `in_library` hint test, all pass |

**Orphan check:** REQUIREMENTS.md maps exactly OBS-01, OBS-02, OBS-03, PANEL-01 to Phase 3, and all four appear in the `requirements:` frontmatter of the three plans (03-01: `[OBS-01]`, 03-02: `[OBS-02, PANEL-01]`, 03-03: `[OBS-03]`). No orphaned requirements.

### Anti-Patterns Found

None. Scanned all 8 phase-3-modified files for `TBD`/`FIXME`/`XXX`/`TODO`/`HACK`/`PLACEHOLDER`, "coming soon"/"not yet implemented"-style prose, empty-return stubs, and hardcoded-empty-data patterns. The only "placeholder" hits in `panel/index.html` are pre-existing, legitimate uses (CSS class `.media-placeholder`, HTML `placeholder=` form attributes, `input::placeholder` selector) unrelated to this phase's changes. One `# ponytail:` comment exists in `panel/app.py:663`, exactly as required by D-09 — it documents a deliberate, bounded simplification (no content-hash cache in prune) with a named upgrade path, not a debt marker.

### Human Verification Required

None. No `<verify><human-check>` blocks exist in any of the three PLAN.md files (all `<verify>` blocks in all three plans are `<automated>`). All four ROADMAP success criteria are objectively verifiable via grep/test/tower-harness, which was done. No visual-only, real-time, or external-service-dependent behavior was introduced by this phase that automated checks cannot cover.

### Gaps Summary

None. All 15 merged truths (4 ROADMAP success criteria plus 11 supporting must-haves drawn from the three plans' frontmatter) are VERIFIED against the actual codebase — not just SUMMARY.md claims. Every artifact exists, is substantive, is wired, and (where it renders dynamic data) the data flow traces to a real source. Every key link is wired. Requirements coverage is complete with no orphans. No anti-patterns or debt markers were introduced. The diff between the end of Phase 2 and the end of Phase 3 touches exactly the files declared in the three plans' `files_modified` — no scope creep. Local test suites (`frameio-mirror`: 59 passed, `panel`: 4 passed, `tests/panel-static.sh`: passed) were run directly by this verifier, not taken on faith from SUMMARY.md. The one check this verifier could not re-run directly (the Linux-only `unraid-healthcheck` harness, which only runs inside the sorter image on tower) is backed by a fresh post-merge log file (`/tmp/gsd-hc-merge.log`) with all 23 expected `PASS:` lines and the final `PASS unraid-healthcheck` marker, per the task's explicit instruction to treat that as primary evidence.

---

*Verified: 2026-09-01T22:03:59Z*
*Verifier: Claude (gsd-verifier)*
