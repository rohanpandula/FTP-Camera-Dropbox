---
phase: 02-sorter-correctness
reviewed: 2026-09-01T21:52:41Z
depth: standard
files_reviewed: 2
files_reviewed_list:
  - sort.sh
  - tests/parallel-sort.sh
findings:
  critical: 0
  warning: 1
  info: 1
  total: 2
status: issues_found
---

# Phase 2: Code Review Report

**Reviewed:** 2026-09-01T21:52:41Z
**Depth:** standard
**Files Reviewed:** 2
**Status:** issues_found

## Summary

Reviewed `git diff 4b82c96..HEAD -- sort.sh tests/parallel-sort.sh` (two commits: `b7e5e48` HEIF trailing-pad tolerance, `74a4cb8` ctime STUCK scan), 19 changed lines in `sort.sh` and 86 in the harness. Both changes match the locked decisions in `02-CONTEXT.md` exactly and `shellcheck -S style` returns zero findings for either file, including the exact diff line ranges.

**HEIF trailing-pad guard (`heif_container_validate`, sort.sh:869-880).** Traced the box walk by hand against both new fixtures:
- A walk that has parsed ≥1 box terminates via `break` on 1-7 trailing bytes, falls through to the unchanged `ftyp_seen`/`meta_seen` post-loop checks, and returns 0/1 from there — confirmed correct.
- `box_count == 0` still logs and returns 1 on the reject path (sort.sh:878-879) — see IN-01, this path is logically correct but currently unreachable.
- A truncated `mdat` (declared size > actual remaining bytes) still fails on the pre-existing `box_size > remaining` → "box overruns EOF" check (sort.sh:919-922), which runs *before* offset advances past the box and is untouched by this diff. Hand-traced `write_truncated_heif`'s math (mdat declares 65536 at an offset where only 60008 bytes remain) — still rejects.
- Adversarial question (can the tolerance admit a truncated file that previously failed?): no. The maximum region the new guard can silently skip is 1-7 bytes, which is one byte short of the minimum legal box header (8 bytes), so no box — malicious or otherwise — can hide in the tolerated tail. Any box whose declared size doesn't fit in the actual remaining bytes still fails the overrun check before the new guard is ever reached for that box. The only behavior change is accepting a *complete* trailing box structure followed by ≤7 bytes of headerless slack, which is exactly the alignment-padding case this phase targets.
- Hand-verified `write_padded_heif`'s byte layout: ftyp(24) + meta(12) + mdat header `\x00\x00\xea\x68` (0x0000EA68 = 60008) + 60000 zero bytes (`dd bs=1000 count=60`) + 3 trailing zero bytes = 60047 B total, matching the D-01/D-03 spec and clearing the 50000 B floor. The box walk lands exactly on `remaining == 3` after the mdat box, which is the guard's intended trigger.

**ctime STUCK scan (`reconcile`, sort.sh:2082-2091).** Confirmed via full-file grep that this is the *only* `find` predicate touched: `prune_stale_raw_tmp` (sort.sh:2045) and `prune_stale_ftp_tmp` (sort.sh:2059) still use `-mmin`, and `prune_stale_dupes` (sort.sh:2068) already used `-ctime` before this diff — consistent with the documented rationale ("the move keeps the camera's capture-time mtime... but bumps ctime"). ctime semantics match the "arrival time" intent: `touch -d` cannot set ctime backwards (it always reflects the last metadata-changing syscall's wall-clock time), so a file landed by SMB drag with a preserved old mtime still gets a fresh ctime at creation, and a genuinely stale/idle file's ctime is never bumped again by anything else in the pipeline while it sits in `incoming`. No other `find` call, and no other reference to `STUCK_AGE_MIN`, changed.

**Harness.** `write_padded_heif` (tests/parallel-sort.sh:52-67) byte-for-byte matches the spec above. The raised `wait_for_count`/`wait_for_lines` expectations (2→4 sorted/notified, quarantine count unchanged at 2) correctly account for 6 total fixtures (2 valid + 2 truncated + 2 padded) draining to 4 accepted + 2 quarantined. The whole-log negated assertion (`! grep -q 'validate: heif truncated box header' ... || fail ...`, tests/parallel-sort.sh:942-943) is safe under `set -euo pipefail`: `!` in front of a simple command is one of the constructs POSIX/bash explicitly exempts from triggering `-e`, and the truncated fixtures independently trip the *different* "box overruns EOF" message, verified by hand-tracing `write_truncated_heif`'s mdat math. The new STUCK case (tests/parallel-sort.sh:2645-2681) correctly builds the only mtime/ctime pairing the harness can construct (old mtime via `touch -d`, ctime pinned to "now"), uses the established `RECONCILE_IDLE=1` pattern, and `assert_log_absent_for`'s un-scaled 3-second window is safe here because `STUCK_AGE_MIN=60` gives a two-order-of-magnitude margin against any real-time jitter. One deviation from house style found — see WR-01.

## Narrative Findings (AI reviewer)

## Warnings

### WR-01: New STUCK-scan test case skips the harness's `stop_sorter`-first convention

**File:** `tests/parallel-sort.sh:2645`
**Issue:** Every other scenario block in this file (~50 of them) opens with `stop_sorter` before touching `$TEST_ROOT/data`, specifically because `stop_sorter()`'s own comment (tests/parallel-sort.sh:129-131) explains why: "A prior case must never retain an old log fd or process a later case's freshly recreated data tree." The new block added by `74a4cb8` breaks this pattern — it goes straight from `echo "PASS: dead inotify watcher exited for container restart"` (line 2643) into `rm -rf "$TEST_ROOT/data"` (line 2645) with no intervening `stop_sorter` call. The preceding "dead watcher" case does confirm its own top-level sort.sh process is reaped (`kill -0`/`wait` at lines ~2632-2636), but that only proves the immediate `sort.sh` process exited — it does not run `stop_sorter`'s defensive sweep of `list_descendants` for any background job (e.g. a notifier loop sleeping on `NOTIFY_INTERVAL`) that `sort.sh` may have spawned and not reaped on that exit path (sort.sh only traps `SIGTERM`/`SIGINT` for its `shutdown` handler, not a plain internal `exit`). In the current file this is low-risk in practice (the dead-watcher case's `incoming` is empty, so no `dispatch()` workers exist to race, and its `NOTIFY_INTERVAL=3600`/`RECONCILE_IDLE=30` mean any orphaned background job would stay asleep for the ~5s this new case runs), but it is a real gap in the defense-in-depth the rest of the file relies on, and it will bite silently if a case is ever inserted between these two blocks, or if this block is copied elsewhere, without someone noticing the missing safety net.
**Fix:** Add `stop_sorter` as the first line of the new block, matching every other scenario in the file:
```bash
echo "PASS: dead inotify watcher exited for container restart"

stop_sorter
rm -rf "$TEST_ROOT/data"
mkdir -p "$TEST_ROOT/data/incoming"
```

## Info

### IN-01: `box_count == 0` reject path in the new HEIF guard is currently unreachable

**File:** `sort.sh:855-858, 877-879`
**Issue:** The new guard's comment states "only a walk that already parsed a box may stop here; first bytes that cannot form a box header still fail" (sort.sh:876), implemented as `(( box_count > 0 )) && break` followed by a `log`+`return 1` fallback for `box_count == 0`. That fallback is logically correct but dead in practice: `heif_container_validate` already requires `file_size > 50000` (sort.sh:855-858) before the box walk begins, so the very first loop iteration always has `remaining == file_size > 50000`, and `remaining < 8` can never be true while `box_count == 0`. This isn't a functional bug — nothing incorrect is accepted or rejected — but the comment and the `box_count > 0` guard are documenting/implementing a defense that the current code can't actually exercise, which could confuse a future reader trying to find a test that hits it, or hide a latent gap if the 50000 B floor is ever loosened independently of this guard.
**Fix:** No behavior change needed. Optionally, note in the comment that this branch is presently unreachable given the file-size floor above, so a future reduction of that floor doesn't quietly change what this branch protects against without re-review — e.g. append: `# (unreachable today: the >50000B floor above guarantees remaining>=8 when box_count==0.)`

---

_Reviewed: 2026-09-01T21:52:41Z_
_Reviewer: Claude (gsd-code-reviewer)_
_Depth: standard_

## Resolution

- WR-01 fixed in commit d98737f (`stop_sorter` opens the STUCK-scan case). IN-01 addressed in commit 739d3ae (comment only, no behavior change). Both files pass `bash -n`; the harness itself was last run in full at plan 02-01 acceptance (50/50) and the change adds only an idempotent helper call at a case boundary.
