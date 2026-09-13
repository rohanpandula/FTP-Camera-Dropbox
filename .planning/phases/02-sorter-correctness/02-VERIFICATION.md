---
phase: 02-sorter-correctness
verified: 2026-09-01T21:48:03Z
status: passed
score: 5/5 must-haves verified
overrides_applied: 0
---

# Phase 2: Sorter Correctness Verification Report

**Phase Goal:** The sorter accepts every valid camera HEIF and stops reporting freshly arrived files as stuck.
**Verified:** 2026-09-01T21:48:03Z
**Status:** passed
**Re-verification:** No — initial verification

## Goal Achievement

### Observable Truths

| # | Truth | Status | Evidence |
|---|-------|--------|----------|
| 1 | A HEIF whose last box ends three bytes before EOF sorts into `sorted/<date>/heif/` with its sha256 unchanged (ROADMAP SC1, D-01/D-03/D-04) | ✓ VERIFIED | `sort.sh:869-879` — the `remaining < 8` guard now does `(( box_count > 0 )) && break` before the log-and-reject, exactly the D-01 shape. `tests/parallel-sort.sh:52-64` `write_padded_heif` builds a 60,047 B fixture; I hand-traced the box walk myself (ftyp 24B→offset 24; meta 12B→offset 36; mdat declared `\x00\x00\xea\x68`=60,008B→offset 60,044; remaining=3<8, box_count=3>0 → break; post-loop `ftyp_seen=1`/`meta_seen=1` → return 0). The harness case (`tests/parallel-sort.sh:894-945`) writes both `padded-camera.heif`/`.hif`, captures sha256 before sorting, and asserts the sorted-path sha256 matches. Primary proof: the actual acceptance-run log at `/tmp/gsd-parallel-sort-02.log` (still on disk, read directly, not via SUMMARY prose) line 14: `PASS: padded HEIF/HIF with trailing alignment bytes sorts`. |
| 2 | A HEIF whose declared mdat overruns EOF still quarantines and still logs `validate: heif box overruns EOF` (ROADMAP SC1, D-01) | ✓ VERIFIED | `write_truncated_heif` (`tests/parallel-sort.sh:69-78`) declares mdat size `\x00\x01\x00\x00`=65,536 but supplies only 60,008 bytes. I traced the walk: at the mdat box, `remaining=60,008 ≥ 8`, so the untouched `box_size(65,536) > remaining(60,008)` check fires first — **before** the new branch is ever reachable — logging `validate: heif box overruns EOF at byte 36` and returning 1. This is the T-02-02 threat-model claim, confirmed by code trace, not just narrative. Harness asserts `wait_for_count quarantine 2 30` (unchanged), `grep -q 'heif box overruns EOF'`, and unchanged sha256 for both quarantined files. Log line 13: `PASS: HEIC and HEIF used bounded ISO-BMFF validation`. |
| 3 | A file with an hours-old mtime that arrived seconds ago produces no `STUCK >` line across repeated reconcile scans (ROADMAP SC2, D-05/D-06) | ✓ VERIFIED | `sort.sh:2091` — stuck scan is now `find "$INCOMING" -type f -cmin +"$STUCK_AGE_MIN" -print0`. `tests/parallel-sort.sh:2652-2679` — `late-drop.part` created then `touch -d "@$(( $(date +%s) - 10800 ))"` backdates only mtime (ctime necessarily becomes "now" since ctime cannot be set backwards); sorter runs `RECONCILE_IDLE=1 STUCK_AGE_MIN=60`; waits for 3 `reconcile scan` lines (`wait_for_log_count`, which multiplies by `TEST_TIMEOUT_SCALE` — confirmed by reading its body); then `assert_log_absent_for 'STUCK >' 3` (confirmed this helper uses **raw** seconds, no scale multiplier — read its body directly). Log line 51: `PASS: fresh arrival with an old mtime is not reported stuck`. |
| 4 | `tests/parallel-sort.sh` runs to completion inside the sorter image: the 48 existing `PASS:` cases plus the 2 added ones (ROADMAP SC3, D-08) | ✓ VERIFIED | Per task instruction, I did not re-run the harness (Linux-only, tower-only). Instead I found the **actual raw acceptance-run log** still present on disk at `/tmp/gsd-parallel-sort-02.log` (mtime `Sep 1 14:38:55`, after both commits at `14:33:35` and `14:35:03` — consistent timeline) and read it directly as primary evidence (not SUMMARY transcription). Independently ran the exact acceptance greps against that file myself: last line `PASS parallel-sort`; `grep -c '^PASS:'` = `50`; `grep -c 'FAIL'` = `0`; both new lines present verbatim; the pre-existing `PASS: HEIC and HEIF used bounded ISO-BMFF validation` still present with its raised expectations. This is stronger evidence than the SUMMARY's own transcription of the same numbers, and it matches exactly. |
| 5 | tower is left with zero `gsd-test-*` directories and zero `gsd-test` images after the acceptance run (D-08) | ✓ VERIFIED (recorded evidence — not independently re-checked, per explicit guardrail not to touch tower) | 02-01-SUMMARY.md records `ssh ... 'ls -d /tmp/gsd-test-* | wc -l; docker images ... | grep -c gsd-test'` → `0` / `0`. This specific claim cannot be independently re-verified without an SSH session to `root@10.0.0.100`, which the task explicitly forbids. Accepted per the task's own instruction to treat recorded evidence as proof; not re-run. |

**Score:** 5/5 truths verified

### Required Artifacts

| Artifact | Expected | Status | Details |
|----------|----------|--------|---------|
| `sort.sh` | `heif_container_validate` trailing-pad break; contains `box_count > 0 )) && break` | ✓ VERIFIED | `grep -F -c 'box_count > 0 )) && break' sort.sh` = `1`. Read the function in full (lines 842-966): only the `remaining >= 8` guard changed, post-loop `ftyp_seen`/`meta_seen` checks untouched, `box_size > remaining` overrun check untouched. |
| `sort.sh` | STUCK scan uses `-cmin`; contains `-cmin +"$STUCK_AGE_MIN"` | ✓ VERIFIED | `grep -c -- '-cmin +' sort.sh` = `1` at line 2091. `grep -c -- '-mmin +' sort.sh` = `2` (lines 2045 `prune_stale_raw_tmp`, 2059 `prune_stale_ftp_tmp`, both correctly still mtime). `wait_stable`'s `STABLE_SKIP_AGE` (line 1242, `stat -c %Y`) still mtime — 4 occurrences of `STABLE_SKIP_AGE` unchanged. |
| `tests/parallel-sort.sh` | `write_padded_heif` fixture writer plus the two new `PASS:` cases | ✓ VERIFIED | `write_padded_heif` defined at line 52, called at lines 869-870 (`grep -c 'write_padded_heif'` = `3`). `grep -c 'echo "PASS:'` = `50` (was 48). Both new `PASS:` strings present verbatim (confirmed both in source and in the real acceptance log). |

### Key Link Verification

| From | To | Via | Status | Details |
|------|-----|-----|--------|---------|
| `sort.sh::heif_container_validate` | post-loop `ftyp_seen`/`meta_seen` checks | `break` (not `return 1`) once `box_count > 0` | ✓ WIRED | Hand-traced the padded-fixture box walk end to end: the `break` exits the `while` loop with `ftyp_seen=1` and `meta_seen=1` already set from the earlier ftyp/meta box iterations, so the post-loop checks pass and the function returns 0. Confirmed `heif_container_validate` is called from `validate_file` at line 1295 (`heif_container_validate "$f" "$original_ext" \|\| return 1`), so the whole chain from file arrival to accept/reject is connected. |
| `sort.sh::reconcile` stuck scan | `log "STUCK >${STUCK_AGE_MIN}min: ..."` | `find -cmin +"$STUCK_AGE_MIN" -print0` piped into the same `while IFS= read -r -d ''` loop | ✓ WIRED | `grep -F -A2 -- '-cmin +"$STUCK_AGE_MIN"' sort.sh \| grep -c 'STUCK >'` = `1` (note: this grep requires `-F`; the plain `-A2` form without `-F` silently returns 0 because `$STUCK_AGE_MIN` is interpreted by BRE — I reproduced this exact false-negative myself and then confirmed the true positive with `-F`, matching SUMMARY's documented deviation #2 verbatim). |
| `tests/parallel-sort.sh::write_padded_heif` | existing HEIF case block | `padded-camera.heif`/`.hif` dropped into incoming beside valid/truncated fixtures | ✓ WIRED | 6 occurrences of `padded-camera` (2 writes, 2 hash captures, 2 sorted-path `find` lookups), all inside the single HEIF case block (lines 862-945), matching the "reuse the block" discretion call recorded in the SUMMARY. |
| `tests/run-on-tower.sh parallel-sort` | `PASS parallel-sort` | throwaway `gsd-test-<id>` image and `--rm` container on tower | ✓ WIRED | Confirmed via the actual raw log content, line 52: `PASS parallel-sort`, exact string match. |

### Data-Flow / Logic Trace

Not a UI/data-fetching phase, so the standard Level-4 component-props trace does not apply. The bash-equivalent was performed instead: manually re-executed the box-walk arithmetic for both new fixtures (padded and, by contrast, the pre-existing truncated fixture) against the actual guard conditions in the current `sort.sh`, confirming the log/PASS lines are backed by real per-byte computation rather than a hardcoded pass. Both traces are recorded in the Observable Truths table above (#1 and #2).

### Behavioral Spot-Checks

| Behavior | Command | Result | Status |
|----------|---------|--------|--------|
| `sort.sh` parses | `bash -n sort.sh` | exit 0 | ✓ PASS |
| `tests/parallel-sort.sh` parses | `bash -n tests/parallel-sort.sh` | exit 0 | ✓ PASS |
| Full harness (Linux-only, tower-only — not re-run per guardrail) | primary acceptance log read directly from `/tmp/gsd-parallel-sort-02.log` | `PASS parallel-sort`, 50/50 `PASS:`, 0 `FAIL` | ✓ PASS (recorded run, independently re-read) |

`sort.sh` and `tests/parallel-sort.sh` cannot run on macOS (Linux-only, `set -u`/`set -euo pipefail` scripts that spawn real sorter processes and depend on GNU coreutils `find -cmin`/`stat -c`/`touch -d @epoch`) — this is a hard constraint from the plan, not a shortcut taken during verification.

### Probe Execution

SKIPPED — no `scripts/*/tests/probe-*.sh` files found; no probes declared in the Phase 2 PLAN or SUMMARY.

### Requirements Coverage

| Requirement | Source Plan | Description | Status | Evidence |
|-------------|-------------|--------------|--------|----------|
| SORT-01 | 02-01-PLAN.md | `heif_container_validate` accepts a 1-7 byte trailing pad once ≥1 box parsed, still rejects overrun mdat, still rejects unparseable first bytes; new harness case passes | ✓ SATISFIED | Code trace + harness log line 14; `[x]` in REQUIREMENTS.md, traceability row "Complete" |
| SORT-02 | 02-01-PLAN.md | Reconcile STUCK scan keys on ctime (`find -cmin`); harness proves the negative; `wait_stable`'s `STABLE_SKIP_AGE` keeps mtime | ✓ SATISFIED | Code trace + harness log line 51; `[x]` in REQUIREMENTS.md, traceability row "Complete" |

No orphaned requirements — REQUIREMENTS.md's Phase 2 traceability rows (`SORT-01`, `SORT-02`) exactly match the `requirements:` field declared in `02-01-PLAN.md`'s frontmatter.

### Anti-Patterns Found

| File | Line | Pattern | Severity | Impact |
|------|------|---------|----------|--------|
| — | — | None found | — | `grep -n -E "TBD\|FIXME\|XXX\|TODO\|HACK\|PLACEHOLDER"` across both phase-modified files returns only pre-existing `mktemp ... .XXXXXX` template placeholders (substring false-positives on "XXX", not debt markers), none inside either commit's diff. No `placeholder`/`coming soon`/`not yet implemented` language anywhere in either file. |

### Scope Discipline

`git diff --name-only origin/main...HEAD -- sort.sh tests/parallel-sort.sh` = exactly those two files. `git diff --name-only b7e5e48~1..199e500` (the phase's three commits) touches only `sort.sh`, `tests/parallel-sort.sh`, `.planning/REQUIREMENTS.md`, and the SUMMARY — matching the hard constraint that only `sort.sh` and `tests/parallel-sort.sh` change as source, and that `STATE.md`/`ROADMAP.md` are left for the orchestrator. Both commit diffs (`b7e5e48`: 11 lines in `sort.sh`; `74a4cb8`: 8 lines in `sort.sh`) are minimal and touch only the two named guard regions — read in full, no drive-by changes elsewhere in either 2,100+/2,600+ line file.

### Context Decisions (02-CONTEXT.md D-01..D-09) Cross-Check

| Decision | Honored? | Evidence |
|----------|----------|----------|
| D-01 (guard rewrite shape) | Yes | Code matches the prescribed `if (( remaining < 8 )); then ... (( box_count > 0 )) && break ... fi` structure verbatim. |
| D-02 (no zero-byte check, no cap below 8) | Yes | No content check on the pad bytes anywhere in the diff. |
| D-03 (fixture byte layout) | Yes | Hand-verified: 24+12+60,008+3=60,047 B, mdat size word `0xea68`=60,008 confirmed by manual hex arithmetic. |
| D-04 (harness assertions) | Yes | All listed assertions present: raised `wait_for_count`/`wait_for_lines` to 4, quarantine waits unchanged at 2, sorted-path lookups, sha256 checks, negative `! grep` assertion, new `PASS:` line. |
| D-05 (ctime scan + comment) | Yes | `-cmin +"$STUCK_AGE_MIN"`, comment names the 2026-08-29 burst, the three mtime-keeping functions explicitly untouched. |
| D-06 (mandatory negative case) | Yes | `late-drop.part`, `touch -d "@$(( $(date +%s) - 10800 ))"`, `RECONCILE_IDLE=1 STUCK_AGE_MIN=60`, `wait_for_log_count 'reconcile scan' 3 20`, `assert_log_absent_for 'STUCK >' 3`, file-still-present check, `PASS:` line. |
| D-07 (positive case, discretionary) | Skipped, per its own rule | `STUCK_AGE_MIN=1` floor + GNU find's whole-minute truncation before `+n` comparison means the earliest fire is ~120s, not ~65s assumed — exceeds the ~90s budget D-07 itself allows skipping under. Confirmed `grep -c 'STUCK >1min' tests/parallel-sort.sh` = `0` (deliberately absent) and the substitute source-adjacency assertion is present and verified true. This is a plan-sanctioned discretionary skip, not a gap. |
| D-08 (acceptance = full harness on tower) | Yes | Verified via the real acceptance log, see Truth #4. |
| D-09 (two commits, each with its harness case, subjects+bodies naming the observed failures) | Yes | `b7e5e48`/`74a4cb8` subjects match exactly; bodies name `DSCF8283.HIF` and `R000002*.JPG` respectively. |

### Human Verification Required

None. This phase is entirely bash validation logic and a deterministic test harness with no UI, no visual surface, and no ambiguous behavior — every claim was checkable by direct code trace, grep count, git diff, or (for the harness pass/fail) by reading the actual raw acceptance-run log still present on disk. The one item that ordinarily could not be mechanically re-verified (tower cleanup, Truth #5) is barred from re-verification by an explicit guardrail in this task, not by any inherent need for human judgment — no one needs to look at anything, the instruction is simply "don't touch tower," and recorded evidence was explicitly pre-approved as sufficient proof.

### Gaps Summary

None. All 3 ROADMAP Phase 2 success criteria hold, all 5 must-haves from the plan's frontmatter are verified against the current codebase (not SUMMARY prose — independently re-derived via code trace, git diff, and the actual raw acceptance log found on disk), both requirement IDs (SORT-01, SORT-02) are satisfied and traceable with no orphans, no debt markers or stub patterns exist in either modified file, no scope creep occurred, and the one deliberately-skipped test case (D-07's positive `STUCK >1min` case) is explicitly plan-sanctioned under its own stated budget rule with a verified substitute assertion in place — not an unresolved gap.

---

*Verified: 2026-09-01T21:48:03Z*
*Verifier: Claude (gsd-verifier)*
