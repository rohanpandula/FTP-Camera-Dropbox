---
phase: 01-baseline
plan: 03
subsystem: testing
tags: [bash, rsync, ssh, docker, tower, ci-harness]

# Dependency graph
requires: []
provides:
  - "tests/run-on-tower.sh: the one vetted way to run tests/parallel-sort.sh and tests/unraid-*.sh from a Mac with no local Docker"
  - "PASS unraid-healthcheck baseline (~10s) recorded, remote directory and image provably removed"
  - "PASS parallel-sort baseline (48 cases, 3m31s) recorded, remote directory and image provably removed"
  - "README.md § Tests and .planning/codebase/TESTING.md document the helper; TESTING.md's two stale forward-references removed"
affects: [any future phase that needs to run tests/parallel-sort.sh or tests/unraid-*.sh]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "tests/run-on-tower.sh: sync-build-run-cleanup helper — 4-literal harness allowlist, charset-validated TOWER_TMP, gsd-test-<id> namespacing (git short hash + PID), EXIT trap guarded on the gsd-test- marker so a mangled path is a no-op instead of a guess"

key-files:
  created:
    - tests/run-on-tower.sh
  modified:
    - README.md
    - .planning/codebase/TESTING.md

key-decisions:
  - "[Rule 1 - bug] Added --exclude .claude to the rsync exclude list — .claude/worktrees/ holds live Claude Code executor checkouts (gitignored, present in the working tree during multi-agent phases) that must never be synced to tower or folded into a docker build context"

patterns-established:
  - "Injection-boundary allowlisting for values that reach a remote root shell: harness name is one of 4 literals via `case`, TOWER_TMP is charset-validated (^/[A-Za-z0-9._/-]*$) before any ssh/rsync call"

requirements-completed: [BASE-04]

# Metrics
duration: ~5min this session (deviation fix + Task 3); Task 1-2 duration not separately recorded (prior session, ended by 20:41:39Z)
completed: 2026-09-01
---

# Phase 1 Plan 3: Tower test helper Summary

**`tests/run-on-tower.sh` gives agents one vetted, injection-hardened way to run the Linux-only harnesses on tower; both `unraid-healthcheck` (~10s) and `parallel-sort` (48 cases, 3m31s) passed through it with tower left exactly as found.**

## Performance

This plan spanned two sessions separated by the Task 3 human-approval checkpoint (`type="checkpoint:human-verify" gate="blocking"`).

- **Session 1** (Tasks 1-2, prior agent invocation in an isolated worktree, later merged): Task 1 committed `2026-09-01T20:40:25Z`; Task 2 ran `20:41:29Z`→`20:41:39Z` (~10s, evidence-only, no commit). Merged to `gsd/2026-09-hardening` at `20:44:24Z` (`cea4019`).
- **Checkpoint pause:** operator approved with "approved" per the resume instructions.
- **Session 2** (this continuation, sequential executor on the main working tree): started after `20:44:44Z`; deviation-fix committed `20:46:11Z`; `parallel-sort` baseline ran `20:46:27Z`→`20:49:58Z` (211s); SUMMARY completed `2026-09-01T20:52:05Z`.
- **Tasks:** 3 completed (Task 1, Task 2, Task 3) + 1 auto-fixed deviation
- **Files modified:** 3 (`tests/run-on-tower.sh`, `README.md`, `.planning/codebase/TESTING.md`)

## Accomplishments
- `tests/run-on-tower.sh` written and merged: 4-literal harness allowlist, charset-validated `TOWER_TMP`, `gsd-test-<id>` namespacing, EXIT trap cleanup — all static safety gates (D-09 forbidden-string grep, forbidden docker-verb grep, bad-harness-name exit 2, hostile-`TOWER_TMP` exit 2) pass.
- Documented in README.md § Tests (two-line note + invocation) and `.planning/codebase/TESTING.md` (new `## Remote tower testing` section); TESTING.md's two stale forward-references ("(Phase 1)" and the macOS `TMPDIR=/private/tmp` caveat) removed.
- `PASS unraid-healthcheck` observed end to end through the helper (~10s), remote `gsd-test-*` directory and image provably gone, `docker ps` name list (76 containers) unchanged before/after.
- `PASS parallel-sort` observed end to end through the helper: 48 `PASS:` case lines, 3m31s wall clock, remote `gsd-test-*` directory and image provably gone, `docker ps` name list (76 containers) unchanged before/after.
- Deviation fix: `.claude/worktrees/` (live executor checkouts) excluded from the rsync so a concurrent multi-agent phase never leaks a worktree copy onto tower or into a docker build context.

## Task Commits

Each task was committed atomically:

1. **Task 1: Write tests/run-on-tower.sh and document it in README § Tests and TESTING.md** - `a635e3a` (tests) — merged into this branch by `cea4019`
2. **Task 2: Baseline run — unraid-healthcheck on tower, and prove the cleanup** - evidence-only, no commit (verification task)
3. **[Deviation, Rule 1] Exclude `.claude/` from the rsync sync** - `02ba800` (tests)
4. **Task 3: Approve and run the 10-minute parallel-sort baseline on tower** - evidence-only, no commit (checkpoint + verification task)

**Plan metadata:** committed alongside this SUMMARY.md

## Files Created/Modified
- `tests/run-on-tower.sh` - sync/build/run/cleanup helper for the four Linux-only harnesses (created in Task 1, `--exclude .claude` added as this session's deviation fix)
- `README.md` - § Tests gains a two-line note plus the `tests/run-on-tower.sh <harness>` invocation, inside the existing fenced block, before the closing fence
- `.planning/codebase/TESTING.md` - new `## Remote tower testing (tests/run-on-tower.sh)` section; the `parallel-sort` table row drops its stale "(Phase 1)" qualifier and the Frame.io row drops the stale macOS `TMPDIR=/private/tmp` caveat (BASE-02's `os.path.realpath` fix, landed in plan 01-02, made it obsolete)

## Decisions Made
- **[Rule 1 - Bug]** Added `--exclude .claude` to the rsync exclude list. Found during Task 3 pre-flight: the repository now contains `.claude/worktrees/agent-af864981cf9780d22`, a live Claude Code executor checkout (gitignored via `.gitignore:10`, added by `9041153` after Task 1 merged, but present in the working tree during this multi-agent phase). Without the exclude, `rsync -a --delete ./ "$TOWER:$dir/"` would have copied that live worktree into the `gsd-test-<id>` directory on tower and into the `docker build` context. Fixed inline, re-verified `bash -n`, the D-09 forbidden-string grep (0), and the forbidden docker-verb grep (0) before running the baseline. Committed separately (`02ba800`) per CONVENTIONS.md § Git subject format, distinct from the plan's Task 1 commit since it was discovered after that commit had already merged.

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 - Bug] Excluded `.claude/` (live executor worktrees) from the tower sync**
- **Found during:** Task 3 pre-flight (before running the `parallel-sort` baseline)
- **Issue:** `tests/run-on-tower.sh`'s rsync exclude list (`--exclude .git --exclude .planning --exclude .impeccable --exclude '__pycache__' ...`) predates `.claude/worktrees/` existing in this repo. A live worktree checkout under `.claude/worktrees/` would have been synced to tower's `/tmp/gsd-test-<id>/` and folded into the `docker build` context — harmless to tower itself (still cleaned up by the EXIT trap) but a correctness bug: it could pull in another agent's in-flight, uncommitted state and build a nondeterministic image.
- **Fix:** Added `--exclude .claude` to the rsync exclude list (one-line diff).
- **Files modified:** `tests/run-on-tower.sh`
- **Verification:** `bash -n` still parses; D-09 forbidden-string grep still `0`; forbidden docker-verb grep still `0`; `test -x` still 0755. Then ran `tests/run-on-tower.sh parallel-sort` successfully end to end.
- **Committed in:** `02ba800`

---

**Total deviations:** 1 auto-fixed (1 bug)
**Impact on plan:** Necessary correctness fix for a condition (concurrent worktree agents) that didn't exist when Task 1 was originally written. No scope creep — one line, no new abstraction, no flag added.

## Issues Encountered

None blocking. One minor, intentionally-not-fixed documentation drift: `.planning/codebase/TESTING.md`'s `## Remote tower testing` section (written in Task 1) lists the rsync exclude set without `.claude`, since that section was authored and merged before the deviation fix. This session's `<project_guardrails>` scoped edits to `tests/run-on-tower.sh`, `.planning/REQUIREMENTS.md`, and this SUMMARY only, so TESTING.md was deliberately left as-is. The drift is cosmetic (the script's behavior is correct and verified; only the doc's exclude list enumeration is one entry stale) — worth a one-line follow-up whenever TESTING.md is next touched.

## User Setup Required

None - no external service configuration required.

## Next Phase Readiness
- BASE-04 fully satisfied: helper exists, passes all static safety gates, and both baselines (`unraid-healthcheck`, `parallel-sort`) are recorded with tower provably left in its pre-run state.
- Any later phase needing a Linux-only harness run (sorter changes in Phase 2, healthcheck changes in Phase 3) can call `tests/run-on-tower.sh <harness>` directly — no further setup needed.
- Minor follow-up available but non-blocking: add `.claude` to `.planning/codebase/TESTING.md`'s documented exclude list to match the script (see Issues Encountered).
- No blockers.

## Verification Evidence

**Task 2 — `PASS unraid-healthcheck` (from `<completed_tasks>`, prior session):**
```
PASS unraid-healthcheck
```
Wall clock: `2026-09-01T20:41:29Z` → `2026-09-01T20:41:39Z` (~10s). Leftover check: `ls -d /tmp/gsd-test-*` → 0 entries; `docker images | grep gsd-test` → 0 entries. `docker ps` name list: 76 containers, identical before and after.

**Task 3 — `PASS parallel-sort` (this session):**
```
PASS parallel-sort
```
Wall clock: `2026-09-01T20:46:27Z` → `2026-09-01T20:49:58Z` (211s / 3m31s) — faster than D-10's "about 10 minutes" estimate; no Docker Hub retry was needed (single `docker build`, no timeout/retry markers in the log) and tower's Docker layer cache was likely already warm from Task 2's build minutes earlier.
`grep -c '^PASS:' /tmp/gsd-parallel-sort.log` → `48` (full suite ran, no early exit).
Cleanup proof: `ssh root@10.0.0.100 'ls -d /tmp/gsd-test-* | wc -l'` → `0`; `docker images | grep -c gsd-test` → `0`.
`docker ps --format "{{.Names}}"`: 76 containers, list byte-identical before and after (`diff` exit 0).
No `skip`/`error`/`warn`/`retry`/`timeout` markers anywhere in the log.

**Static gates (re-verified after the deviation fix, this session):**
- `bash -n tests/run-on-tower.sh` → exits 0
- `grep -c -e 'camera-sorter ' -e 'dropbox-panel' -e 'pure-ftpd' -e 'frameio-mirror' -e '/mnt/' tests/run-on-tower.sh` → `0` (D-09)
- `grep -c -e 'docker stop' -e 'docker restart' -e 'docker exec' -e 'docker kill' -e 'docker rm ' tests/run-on-tower.sh` → `0`
- `test -x tests/run-on-tower.sh` → 0755 preserved

---
*Phase: 01-baseline*
*Completed: 2026-09-01*
