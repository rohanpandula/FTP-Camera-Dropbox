---
phase: 01-baseline
verified: 2026-09-01T21:02:23Z
status: passed
score: 8/8 must-haves verified
overrides_applied: 0
---

# Phase 1: Baseline Verification Report

**Phase Goal:** The milestone branch equals origin/main plus the LRU folder registry, every test suite passes on this Mac, and nothing stale can be committed by accident.
**Verified:** 2026-09-01T21:02:23Z
**Status:** passed
**Re-verification:** No — initial verification

## Goal Achievement

### Observable Truths

| # | Truth | Status | Evidence |
|---|-------|--------|----------|
| 1 | Frame.io suite reports 57 passed with no `TMPDIR` override (Roadmap SC1) | VERIFIED | Ran `cd frameio-mirror && python3 -m pytest -q` myself with the shell's real macOS default `TMPDIR=/var/folders/yz/.../T/` — `57 passed, 5 subtests passed in 0.61s`, zero failures. Re-ran with `TMPDIR` fully `unset` — same result, `57 passed, 5 subtests passed`. Zero `state parent contains a symlink` occurrences. |
| 2 | `git log origin/main..HEAD` shows the LRU commit and the test fix, nothing else from `fix/frameio-folder-lru` (Roadmap SC2) | VERIFIED | `git log --oneline origin/main..HEAD -- frameio-mirror/` returns exactly two commits: `5b8e2a5` (LRU cherry-pick) and `5597444` (realpath test fix). `git rev-parse fix/frameio-folder-lru` still resolves to `0d566ce...`, untouched. `git log --oneline origin/main..fix/frameio-folder-lru` confirms that branch had exactly one commit (`0d566ce`) to contribute, and it's the one present. |
| 3 | `_remember_c2c_folder` evicts oldest / promotes re-seen; `_reconcile_folder_ids` returns newest-last capped at 16 (Roadmap SC3) | VERIFIED | Read `app.py:552-616` and `app.py:1195-1210` directly. Eviction: `updates["c2c_folder_ids"] = (known + [parent_folder])[-16:]` when `len(known) >= 16`. Promotion: `known.remove(parent_folder); updates["c2c_folder_ids"] = known + [parent_folder]`. Reconcile: `return ids[-16:]` when non-empty, else legacy single id, else `[]`. `grep -c 'Not remembering C2C folder'` → `0` (main's refuse-newest path gone). Confirmed live by running `test_full_registry_evicts_oldest_for_newest` and `test_reseen_folder_is_promoted_to_newest` — both pass. |
| 4 | `.impeccable/` no longer appears in `git status` (Roadmap SC4) | VERIFIED | `.impeccable/` exists on disk (`ls -la` confirms) but `git status` / `git status --short` show nothing (working tree fully clean). `git check-ignore -v .impeccable` → `.gitignore:9:.impeccable/	.impeccable` exit 0 — sourced from the tracked `.gitignore`, not a local-only exclude. |
| 5 | `tests/run-on-tower.sh parallel-sort` prints `PASS parallel-sort` (48 cases) and cleans up on tower (Roadmap SC5) | VERIFIED (recorded evidence + live re-verification of current script, per instruction not to hit the live NAS) | 01-03-SUMMARY.md records `PASS parallel-sort`, `grep -c '^PASS:' → 48`, 211s wall clock, `ls -d /tmp/gsd-test-* → 0`, `docker images \| grep -c gsd-test → 0`, `docker ps` name list byte-identical before/after. I independently re-ran all static/behavioral gates against the **current** `tests/run-on-tower.sh` on disk (not just SUMMARY prose) and confirmed the script's actual logic is what would produce that evidence: `bash -n` parses, mode 0755, forbidden-string grep = 0, forbidden-docker-verb grep = 0, `tests/run-on-tower.sh bogus` → exit 2 with no network call, `tests/run-on-tower.sh` (no arg) → exit 2, hostile `TOWER_TMP='/tmp;touch-should-not-run'` → exit 2 before any ssh/rsync. The `parallel-sort` branch (`docker run --rm --entrypoint /bin/bash -e SORTER_UNDER_TEST=/sort.sh -v $dir:/work:ro`) and EXIT trap (`trap cleanup EXIT`, guarded on `*/gsd-test-*`) match the interface exactly. |
| 6 | `frameio-mirror/app.py` is byte-identical to `0d566ce`, untouched by the test-fix plan (production symlink guard not relaxed) | VERIFIED | `git rev-parse HEAD:frameio-mirror/app.py` == `git rev-parse 0d566ce:frameio-mirror/app.py` == `ce188d7ee53831d3eb8dbf8433a15dcfbc25e3bd`. `_state_parent_path_is_canonical` still reads exactly `return os.path.realpath(parent) == str(parent)` (app.py:240-241). |
| 7 | Unknown harness name and hostile `TOWER_TMP` are rejected before any ssh/rsync | VERIFIED | Ran all three live: `tests/run-on-tower.sh bogus` → exit 2, usage line, no hang (network calls would take seconds+); `tests/run-on-tower.sh` (no arg) → exit 2; `TOWER_TMP='/tmp;touch-should-not-run' tests/run-on-tower.sh unraid-healthcheck` → exit 2 with the regex-rejection message, returned instantly. Source confirms both checks precede `id=`/`dir=`/`trap`/`rsync`. |
| 8 | Helper documented in README § Tests and TESTING.md; stale macOS `TMPDIR` caveat removed | VERIFIED | `sed -n '/^## Tests$/,/^## Optional/p' README.md \| grep run-on-tower.sh` matches (line 301, inside § Tests). `.planning/codebase/TESTING.md` has `## Remote tower testing (tests/run-on-tower.sh)` section; `grep -c 'TMPDIR=/private/tmp' TESTING.md` → `0`; Frame.io row now reads "no `TMPDIR` override needed — tests resolve temp dirs with `os.path.realpath`". |

**Score:** 8/8 truths verified

### Required Artifacts

| Artifact | Expected | Status | Details |
|----------|----------|--------|---------|
| `frameio-mirror/app.py` | LRU registry (`_remember_c2c_folder`, `_reconcile_folder_ids`); unchanged by plan 01-02 | VERIFIED | Blob `ce188d7e...` matches `0d566ce` exactly. Guard function verbatim-unchanged. |
| `frameio-mirror/tests/test_multi_folder.py` | LRU eviction/promotion assertions (8 methods) + realpath canonicalization | VERIFIED | 8 test methods present incl. `test_full_registry_evicts_oldest_for_newest`, `test_reseen_folder_is_promoted_to_newest`; `os.path.realpath` wraps `self._dir.name` in `setUp`; 8/8 pass live. Note: blob differs from `0d566ce` (as recorded in 01-01-SUMMARY) — this is plan 01-02's sanctioned, later addition of `import os` + `os.path.realpath(...)`, confirmed by `git diff 0d566ce HEAD -- ...` showing only that 2-line change. Not a gap; expected cross-plan evolution within the same phase. |
| `frameio-mirror/tests/test_app.py` | `os.path.realpath` at 3 D-04 sites | VERIFIED | 3 occurrences (lines 188, 321, 370), each flows into `app.CFG.update(incoming_dir=..., staging_dir=..., refresh_token_file=...)`. |
| `frameio-mirror/tests/test_release_safety.py` | `os.path.realpath` at 3 D-04 sites | VERIFIED | 3 occurrences (lines 168, 350, 385). |
| `.gitignore` | Ignores `.impeccable/` | VERIFIED | Line 9; added by the orchestrator's pre-phase-1 planning commit `d5db9fa`, per D-06. |
| `tests/run-on-tower.sh` | Sync/build/run/cleanup helper, mode 0755, `min_lines: 40` | VERIFIED | 88 lines, `-rwxr-xr-x`, matches the D-07/D-08/D-09 interface exactly (read in full). |
| `README.md` | § Tests references the helper | VERIFIED | Line 301, inside `## Tests` … `## Optional` bounds. |
| `.planning/codebase/TESTING.md` | Documents helper interface, env vars, safety constraints | VERIFIED | `## Remote tower testing` section present; names `TOWER`, `TOWER_TMP`, `PASS`/`FAIL` contract. |

### Key Link Verification

| From | To | Via | Status | Details |
|------|-----|-----|--------|---------|
| `_process_asset_inner` | `_remember_c2c_folder` | `await` on every downloaded asset | WIRED | `app.py:3676`, inside `_process_asset_inner` (starts 3541), before the next function boundary. |
| `reconcile_once` | `_reconcile_folder_ids` | folder list for the sweep | WIRED | `app.py:1362`, `folder_ids = _reconcile_folder_ids()`, inside `reconcile_once` (starts 1350). |
| `test_*.py` `TemporaryDirectory` | `app.CFG` (`refresh_token_file`/`incoming_dir`/`staging_dir`) | `os.path.realpath()` before assignment | WIRED | Confirmed in all three test files' `setUp`/`with` blocks — the realpath-wrapped `root`/`runtime_root` variable is what actually gets handed to `app.CFG.update(...)`, not a parallel unwrapped path. |
| `tests/run-on-tower.sh` | `tests/parallel-sort.sh` (in container) | `docker run --rm --entrypoint /bin/bash -e SORTER_UNDER_TEST=/sort.sh -v $dir:/work:ro` | WIRED | Present verbatim in the script's `parallel-sort` case branch. |
| `tests/run-on-tower.sh` | `tests/unraid-*.sh` (self-re-exec) | `TEST_IMAGE=$tag tests/$harness.sh` | WIRED | Present verbatim; helper does not wrap its own `docker run` for these three harnesses, matching D-08. |
| `tests/run-on-tower.sh` EXIT trap | remote docker image + sync dir | `trap cleanup EXIT`, guarded on `*/gsd-test-*` | WIRED | `trap cleanup EXIT` installed immediately after `tag` is set, before the first `rsync`; `cleanup()` no-ops if the marker is missing, otherwise runs `docker rmi -f` + `rm -rf --` suffixed `\|\| true`. |

### Behavioral Spot-Checks

| Behavior | Command | Result | Status |
|----------|---------|--------|--------|
| Frame.io suite, real macOS default TMPDIR | `cd frameio-mirror && python3 -m pytest -q` (shell's actual `/var/folders/...` TMPDIR) | `57 passed, 5 subtests passed in 0.61s` | PASS |
| Frame.io suite, TMPDIR fully unset | `unset TMPDIR && python3 -m pytest -q` | `57 passed, 5 subtests passed` | PASS |
| Frame.io suite, TMPDIR=/private/tmp (no regression) | `TMPDIR=/private/tmp python3 -m pytest -q` | `57 passed, 5 subtests passed in 0.37s` | PASS |
| LRU eviction/promotion tests | `python3 -m pytest -q tests/test_multi_folder.py -v` | `8 passed in 0.10s` | PASS |
| Bad harness name rejected pre-network | `tests/run-on-tower.sh bogus` | exit 2, usage line, instant return | PASS |
| No-argument invocation rejected | `tests/run-on-tower.sh` | exit 2, usage line | PASS |
| Hostile `TOWER_TMP` rejected pre-network | `TOWER_TMP='/tmp;touch-should-not-run' tests/run-on-tower.sh unraid-healthcheck` | exit 2, regex-rejection message | PASS |
| Static safety gates | `bash -n`, forbidden-string grep, forbidden-docker-verb grep | parses clean; `0` matches both greps | PASS |

### Probe Execution

SKIPPED — no `scripts/*/tests/probe-*.sh` files found and no probes declared in any Phase 1 PLAN/SUMMARY.

### Requirements Coverage

| Requirement | Source Plan | Description | Status | Evidence |
|-------------|-------------|-------------|--------|----------|
| BASE-01 | 01-01-PLAN.md | LRU folder registry from `0d566ce` on `origin/main`'s lineage, `test_multi_folder.py` asserts LRU behavior, suite at 57 tests | SATISFIED | Blob-identical `app.py`; eviction/promotion tests pass live. |
| BASE-02 | 01-02-PLAN.md | Frame.io suite passes on macOS with default `TMPDIR` | SATISFIED | `57 passed` confirmed live under the shell's real default TMPDIR, twice. |
| BASE-03 | 01-02-PLAN.md | `.impeccable/` gitignored; checkout clean | SATISFIED | `git check-ignore` + `git status` confirmed directly. |
| BASE-04 | 01-03-PLAN.md | `tests/run-on-tower.sh` helper, documented, both harnesses pass | SATISFIED | Static/injection gates re-verified live against current script; `PASS` evidence recorded in 01-03-SUMMARY.md with cleanup proof. |

No orphaned requirements — REQUIREMENTS.md's Phase 1 traceability row set (`BASE-01..04`) exactly matches the union of `requirements:` fields declared across the three plans.

### Anti-Patterns Found

| File | Line | Pattern | Severity | Impact |
|------|------|---------|----------|--------|
| — | — | None found | — | `grep -n -E "TBD\|FIXME\|XXX\|TODO\|HACK\|PLACEHOLDER"` across all 7 phase-modified files (`app.py`, `test_multi_folder.py`, `test_app.py`, `test_release_safety.py`, `run-on-tower.sh`, `README.md`, `TESTING.md`) returns zero matches. |
| `tests/run-on-tower.sh` | — | Missing `# ponytail:` ceiling comment for the Docker Hub build-retry deferral | Info | 01-03-PLAN's `<action>` prose suggested marking the "retry the build if the `alpine:3.24.1` pull times out" deferral with a `# ponytail:` comment. Not present in the shipped script. This was plan-prose guidance, not a listed acceptance criterion or must-have — no functional or safety impact, purely a documentation nicety that's missing. |

### Human Verification Required

None. The one item that would ordinarily require live-system/human testing — `tests/run-on-tower.sh parallel-sort` against the production NAS (tower) — is explicitly out of scope for this verification pass per the task's guardrails (tower is a live NAS; both baselines were already run and recorded with cleanup evidence in `01-03-SUMMARY.md`). That recorded evidence, combined with this verifier's independent live re-execution of every static and injection-boundary gate against the *current* script, is treated as sufficient proof for Roadmap success criterion 5 (see Observable Truth #5 above).

### Gaps Summary

None. All 5 ROADMAP Phase 1 success criteria hold, all must-haves from the three plans' frontmatter are verified against the current codebase (not SUMMARY prose), all 4 requirement IDs (BASE-01..04) are satisfied and traceable, no debt markers or stub patterns were found in any file this phase touched, and no scope creep occurred (`git diff --name-only origin/main..HEAD` contains exactly the files the three plans declared plus two files — `.gitignore` and `CLAUDE.md` — that were confirmed, by commit-level inspection, to belong to the orchestrator's pre-Phase-1 milestone-planning commit `d5db9fa` and one small `chore:` housekeeping commit `9041153` ignoring `.claude/worktrees/`, neither of which touches the sorter, panel, or healthcheck).

---

*Verified: 2026-09-01T21:02:23Z*
*Verifier: Claude (gsd-verifier)*
