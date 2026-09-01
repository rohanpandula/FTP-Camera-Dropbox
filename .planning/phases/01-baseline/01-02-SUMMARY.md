---
phase: 01-baseline
plan: 02
subsystem: testing
tags: [python, pytest, frameio, macos, tempfile, realpath, gitignore]

# Dependency graph
requires:
  - phase: 01-baseline (plan 01)
    provides: "frameio-mirror at 0d566ce content, 57-passed TMPDIR=/private/tmp baseline, default-TMPDIR failure evidence (6 failed, symlink cause)"
provides:
  - "Frame.io suite at 57 passed with the default macOS TMPDIR (no override) — BASE-02"
  - "Verified .impeccable/ cannot be committed and the checkout is clean apart from planning docs and phase edits — BASE-03"
  - "Confirmation that TESTING.md's 'macOS needs TMPDIR=/private/tmp' line is now stale, flagged for 01-03"
affects: [01-03]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "Test temp-dir canonicalization: wrap the TemporaryDirectory().name (or the `with ... as directory` variable) in os.path.realpath() exactly once, at the point the Path root is derived, before it is handed to app.CFG — not at every downstream use of that root"

key-files:
  created: []
  modified:
    - frameio-mirror/tests/test_multi_folder.py
    - frameio-mirror/tests/test_app.py
    - frameio-mirror/tests/test_release_safety.py

key-decisions:
  - "Applied os.path.realpath at exactly the seven D-04 sites, not at every TemporaryDirectory usage in test_app.py/test_release_safety.py — those files have 20+ other TemporaryDirectory blocks that don't feed app.CFG and never tripped the guard; touching them would violate the 'smallest diff' instruction and D-04's explicit seven-site scope"
  - "Did not touch frameio-mirror/app.py — verified byte-identical via empty `git diff --stat` and a verbatim grep of the guard body"
  - "D-06 (Task 2) is verify-only as instructed: ran the checks, made zero edits, zero git operations beyond read-only status/check-ignore queries"

patterns-established:
  - "Realpath-before-CFG: any future TemporaryDirectory root that becomes a REFRESH_TOKEN_FILE/INCOMING_DIR/STAGING_DIR parent must be resolved with os.path.realpath before assignment, matching the seven sites fixed here"

requirements-completed: [BASE-02, BASE-03]

# Metrics
duration: ~13min
completed: 2026-09-01
---

# Phase 1 Plan 2: macOS symlink resolution + checkout hygiene verification Summary

**Frame.io suite now passes 57/57 with the stock macOS TMPDIR by resolving all seven D-04 TemporaryDirectory roots through `os.path.realpath` before they reach `app.CFG`; `app.py`'s canonical-path guard is untouched, and checkout hygiene (`.impeccable/` ignored, nothing stray staged) is verified.**

## Performance

- **Duration:** ~13 min
- **Started:** 2026-09-01T20:35:00Z (approx)
- **Completed:** 2026-09-01T20:47:50Z
- **Tasks:** 2 completed
- **Files modified:** 3

## Accomplishments
- All seven D-04 sites (`test_multi_folder.py` setUp; `test_app.py` setUp + 2 `with TemporaryDirectory() as directory` blocks; `test_release_safety.py` setUp + 2 `with TemporaryDirectory() as directory` blocks) now wrap their temp root in `os.path.realpath(...)` before it is handed to `app.CFG` as `refresh_token_file`/`incoming_dir`/`staging_dir`
- Suite went from `6 failed, 51 passed, 5 subtests passed` (default TMPDIR, this run) to `57 passed, 5 subtests passed` with **no** `TMPDIR` override
- Confirmed no regression: `TMPDIR=/private/tmp` still reports `57 passed, 5 subtests passed`
- `frameio-mirror/app.py` byte-unchanged: empty `git diff --stat`, and `_state_parent_path_is_canonical`'s body still greps verbatim as `return os.path.realpath(parent) == str(parent)`
- No `TemporaryDirectory` site beyond the seven named in D-04 needed treatment — the default-TMPDIR run after the fix produced zero `state parent contains a symlink` occurrences, so the seven-site list was sufficient (not just necessary)
- Verified `.impeccable/` is ignored via the tracked `.gitignore` (line 9) and that the checkout carries nothing outside `.planning/` and this phase's own edits (BASE-03)

## Task Commits

Each task was committed atomically:

1. **Task 1: Resolve every test temp directory with os.path.realpath before it reaches app.CFG** - `5597444` (tests: resolve macOS symlink rejection with os.path.realpath)
2. **Task 2: Verify the checkout is clean and .impeccable/ cannot be committed** - no commit (verify-only, zero file changes; evidence recorded below)

**Plan metadata:** committed alongside this SUMMARY.md

## Files Created/Modified
- `frameio-mirror/tests/test_multi_folder.py` - added `import os` (alphabetical, between `asyncio` and `tempfile`); `setUp`'s `root = Path(self._dir.name)` → `Path(os.path.realpath(self._dir.name))` (1 site)
- `frameio-mirror/tests/test_app.py` - `os` already imported; 3 sites resolved: `setUp`'s `runtime_root`, and the `root = Path(directory)` lines in `test_atomic_publish_preserves_two_same_name_payloads` and `test_swapped_temp_symlink_is_never_published_or_opened`
- `frameio-mirror/tests/test_release_safety.py` - `os` already imported; 3 sites resolved: `setUp`'s `runtime_root`, and the `root = Path(directory)` lines in `test_public_or_hardlinked_state_is_rejected_and_health_is_503` and `test_state_parent_on_shared_incoming_mount_is_rejected`

## Decisions Made
- Left the other 20+ `with tempfile.TemporaryDirectory() as directory:` blocks in `test_app.py` and `test_release_safety.py` untouched — they don't route through `app.CFG`'s three state-adjacent keys and never appear in a failure, so fixing them would be scope creep against D-04's named seven sites and the plan's "smallest diff" instruction.
- For the two `test_release_safety.py` sites that are themselves symlink/hardlink-rejection tests (`test_public_or_hardlinked_state_is_rejected_and_health_is_503`, `test_state_parent_on_shared_incoming_mount_is_rejected`), confirmed before editing that their assertions exercise permission bits (`chmod`), `os.link`, and a mocked `_fd_mount_id` — not the tempdir root's own symlink-ness — so resolving the root with realpath does not weaken what they test. The one test in that file that deliberately builds an internal symlink to test rejection (`test_symlinked_and_non_private_state_parents_are_rejected`) is not a D-04 site and was left untouched.
- D-06/Task 2 required no `.gitignore` edit, no stash, no add/rm — confirmed the checkout was already clean and the ignore rule was already tracked; nothing to change.

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 3 - Blocking, verification-method adaptation] `git check-ignore -v .impeccable` (bare path) fails in this worktree; used the trailing-slash form to prove the same fact**
- **Found during:** Task 2 (checkout hygiene verification)
- **Issue:** The plan's acceptance criteria and `<verify><automated>` block both call `git check-ignore -q/-v .impeccable` (no trailing slash). In this worktree that command exits 1 with no output. Root cause: `.impeccable/` does not exist on disk anywhere in this worktree — git worktrees only populate tracked files at the checked-out commit; the untracked `.impeccable/` directory visible in the *main* checkout (where 01-CONTEXT.md's planning-time fact was measured) is never copied into a linked worktree. `.gitignore`'s `.impeccable/` pattern is directory-only (trailing slash); git's ignore matcher can only apply a directory-only pattern to a bare, non-existent pathname if it can otherwise infer the path is a directory, and it can't for a path absent from the filesystem — so the bare-path query legitimately returns "not ignored" here, independent of whether the rule is correct.
- **Fix:** Verified with `git check-ignore -v .impeccable/` (explicit trailing slash on the query argument — the git-correct way to test a directory-only pattern against a path that doesn't exist yet). This is a pure read-only git-plumbing query; it does not create, stash, add, or remove anything, so it does not violate the task's "changes nothing" / "do NOT create... do NOT git stash... do NOT git add/rm" constraints. Output: `.gitignore:9:.impeccable/	.impeccable/` — exit 0, sourced from the tracked `.gitignore`, not `.git/info/exclude`. This proves the same underlying fact the acceptance criterion cares about (T-01-07: the rule is real and tracked, so a fresh clone or worktree that *does* materialize `.impeccable/` — e.g. by running the design tool — still can't commit it).
- **Files modified:** none
- **Verification:** `git check-ignore -v .impeccable/` → `.gitignore:9:.impeccable/	.impeccable/` (exit 0); `ls -la .impeccable` → "No such file or directory", confirming the directory genuinely doesn't exist here rather than the ignore rule being broken
- **Committed in:** n/a (no file change; this is a verification-method note only)

---

**Total deviations:** 1 auto-adapted (verification method only, no code/config change)
**Impact on plan:** None on the shipped code. BASE-03's actual guarantee (the tracked `.gitignore` rule is real and would ignore `.impeccable/` if it existed) is proven; only the *exact command form* used to prove it differs from the plan's literal text, for a structural reason (worktree isolation) unrelated to the ignore rule itself.

## Issues Encountered
- This worktree's Bash tool rejects "too complex" compound commands (loops, conditionals, `${VAR:-default}` parameter expansion) with "too complex to verify that it stays inside the worktree," independent of whether `git` is involved. Worked around by using only plain `&&`-chained simple commands. No effect on the actual verification content, only on how commands were phrased.
- Shell environment variables do not persist between Bash tool calls (only cwd does, and even that did not reliably persist across a `cd` embedded in a chained command in this session) — `unset TMPDIR` and the pytest invocation had to run in the same tool call, matching the pattern plan 01-01 used in place of the sandbox-blocked `env -u TMPDIR`.
- Unlike plan 01-01's execution shell (no `TMPDIR` preset, fell back to `/tmp`), this shell had `TMPDIR` preset to a `/var/folders/...` path (an actual symlinked macOS default). `unset TMPDIR` was still required per the project guardrails to get the "no override" acceptance run; the resulting fallback path was `/tmp/tmpXXXXXXXX` (own symlink to `/private/tmp`), so the pre-fix failure evidence below cites `/tmp/...` rather than `/var/folders/...` — same cause, same guard, different string, consistent with 01-01's note on this same discrepancy.

## User Setup Required

None - no external service configuration required.

## Next Phase Readiness
- BASE-02 satisfied: `cd frameio-mirror && python3 -m pytest -q` reports `57 passed` with no `TMPDIR` override on this Mac.
- BASE-03 satisfied: `.impeccable/` is provably ignored via a tracked `.gitignore` rule (see the trailing-slash verification above); `git status --short` in this worktree is fully empty (zero lines) — nothing outside this phase's own committed edits.
- `.planning/codebase/TESTING.md`'s line "Frame.io mirror ... until BASE-02 lands macOS needs `TMPDIR=/private/tmp`" is now stale. Per this plan's `<success_criteria>`, that edit belongs to plan 01-03's `files_modified` and was **not** made here.
- No blockers for 01-03 (`tests/run-on-tower.sh`, README.md § Tests, TESTING.md update).

## Verification Evidence

**Pre-fix baseline in this execution environment (`unset TMPDIR`, matches 01-01's documented cause):**
```
6 failed, 51 passed, 5 subtests passed in 0.78s
```
All 6 failures in `test_multi_folder.py`, e.g.:
```
WARNING  frameio-mirror:app.py:357 Failed to read state file /tmp/tmpum51bojq/state.json: [Errno 1] state parent contains a symlink: '/tmp/tmpum51bojq'
```

**Post-fix, no TMPDIR override (D-05 acceptance number):**
```
57 passed, 5 subtests passed in 0.57s
```
`grep -c 'state parent contains a symlink'` on that run's output → `0`.

**Post-fix, TMPDIR=/private/tmp (no regression):**
```
57 passed, 5 subtests passed in 0.74s
```

**app.py untouched:**
- `git diff --stat frameio-mirror/app.py` → (empty)
- `grep -q 'return os.path.realpath(parent) == str(parent)' frameio-mirror/app.py` → exit 0

**realpath site counts (acceptance criteria):**
- `test_multi_folder.py`: `grep -c 'os.path.realpath'` → `1`
- `test_app.py`: `grep -c 'os.path.realpath'` → `3`
- `test_release_safety.py`: `grep -c 'os.path.realpath'` → `3`
- `import os` count: `1` in each of the three files (no duplicates)

**Task 2 / BASE-03 evidence (verbatim):**
- `git status --short` → *(no output — the working tree is fully clean; `DESIGN.md`/`PRODUCT.md` are tracked at `dd352b1`, not the stale draft, and `.impeccable/`/`panel/assets/`/`tests/panel-static.sh` from the main checkout's untracked state simply don't exist in this worktree)*
- `git check-ignore -v .impeccable/` → `.gitignore:9:.impeccable/	.impeccable/` (exit 0; see Deviations for why the trailing slash was needed in this worktree)
- `git status --short | grep -c impeccable` → `0`
- `git diff --name-only -- .gitignore` → (empty — untouched)

---
*Phase: 01-baseline*
*Completed: 2026-09-01*
