---
phase: 02-sorter-correctness
plan: 01
subsystem: sorter
tags: [bash, iso-bmff, heif, validation, ctime, reconcile, harness]

# Dependency graph
requires:
  - "tests/run-on-tower.sh (Phase 1, plan 01-03) — the only sanctioned way to run the Linux-only harness"
provides:
  - "heif_container_validate tolerates a 1-to-7-byte trailing alignment pad after the last box, gated on box_count > 0"
  - "reconcile's STUCK scan keys on ctime (find -cmin), so arrival time drives the stuck signal instead of capture time"
  - "tests/parallel-sort.sh: write_padded_heif fixture writer plus two new PASS: cases (50 total, was 48)"
affects:
  - "Phase 3 observability work — the STUCK log line is now trustworthy enough to alert on"
  - "any future HEIF/HIF intake from writers that pad to 4-byte alignment"

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "Box-walk termination on a sub-header remainder gated on having already parsed a box, so the 'first bytes are not a box header' rejection is preserved"
    - "ctime for arrival-time questions, mtime for liveness/in-flight questions — now applied consistently across reconcile's four scans"

key-files:
  created: []
  modified:
    - sort.sh
    - tests/parallel-sort.sh

key-decisions:
  - "D-07's positive STUCK >1min case skipped under D-07's own ~90s budget rule; substituted with a source-adjacency assertion (see Deferred / Skipped Work)"
  - "Padded fixtures joined the existing HEIF case block rather than spinning up a second sorter (02-CONTEXT.md § Claude's Discretion)"

requirements-completed: [SORT-01, SORT-02]

# Metrics
duration: ~24 min wall clock (2026-09-01T21:15Z start of edits → 21:39:04Z acceptance run end)
completed: 2026-09-01
---

# Phase 2 Plan 1: Sorter Correctness Summary

**Two surgical `sort.sh` fixes with their harness cases: `heif_container_validate` now breaks out of the box walk on a sub-8-byte trailing pad once at least one box has parsed (instead of quarantining valid camera HEIFs), and the reconcile STUCK scan keys on ctime instead of mtime (instead of crying wolf over SMB drags that preserve capture-time mtime).**

## Performance

- **Tasks:** 3 completed (2 code tasks + 1 acceptance run), 0 deviations requiring code changes
- **Files modified:** 2 (`sort.sh`, `tests/parallel-sort.sh`)
- **Acceptance run:** 222 s (3m42s) wall clock on tower, vs the 211 s Phase 1 baseline — **+11 s (+5.2%)** for 2 added cases

## Accomplishments

- `heif_container_validate` accepts the `DSCF8283.HIF` shape (last box ends 3 bytes before EOF) while still rejecting truncation, missing brands, and first-bytes-not-a-box-header. Diff to `sort.sh` is 13 `+/-` lines, all inside the one guard.
- `reconcile`'s stuck scan uses `find -cmin +"$STUCK_AGE_MIN"`; `prune_stale_raw_tmp`, `prune_stale_ftp_tmp`, and `wait_stable`'s `STABLE_SKIP_AGE` all deliberately keep mtime. Post-change `sort.sh` has exactly one `-cmin +` and two `-mmin +`.
- `write_padded_heif` added beside its two siblings; builds a 60,047-byte fixture with an explicit 60,008-byte mdat (`\x00\x00\xea\x68mdat`) so the pad is not swallowed by a zero-size box.
- Harness grew from 48 to 50 `PASS:` cases; the full suite passed inside the sorter image on tower with tower provably left as found.

## Task Commits

Each task was committed atomically:

1. **Task 1: Tolerate a trailing alignment pad after the last HEIF box (SORT-01)** — `b7e5e48` (`sort.sh`, `tests/parallel-sort.sh`)
2. **Task 2: Key the reconcile STUCK scan on ctime instead of mtime (SORT-02)** — `74a4cb8` (`sort.sh`, `tests/parallel-sort.sh`)
3. **Task 3: Acceptance — full parallel-sort suite inside the sorter image on tower (D-08)** — evidence-only, no commit (verification task)

**Plan metadata:** committed alongside this SUMMARY.md (SUMMARY.md + REQUIREMENTS.md only; STATE.md and ROADMAP.md are the orchestrator's to write after merge).

## Files Created/Modified

- `sort.sh` — two regions only:
  - `heif_container_validate`: the `(( remaining >= 8 )) || { ... }` compound became an `if (( remaining < 8 )); then ... fi` block whose body is a 6-line why-comment, `(( box_count > 0 )) && break`, then the unchanged `log` + `return 1`. When `box_count == 0` the `(( ))` test is false, `&& break` short-circuits, and control falls through to the reject — preserving SORT-01's "first bytes cannot form a box header" rejection.
  - `reconcile`: the stuck-scan `find` operator `-mmin` → `-cmin`, with a comment naming the 2026-08-29 false-STUCK burst. Log string, loop body, `-type f`, and `-print0 2>/dev/null` all unchanged.
- `tests/parallel-sort.sh` —
  - `write_padded_heif` inserted between `write_valid_heif` and `write_truncated_heif`.
  - Existing HEIF case extended in place: 2 more fixture writes, 2 more hash captures, `wait_for_count sorted` 2→4, `wait_for_lines notify-queue` 2→4 (both quarantine waits stay at 2), 2 more sorted-path lookups, 2 sha256 assertions, the negative `! grep -q 'validate: heif truncated box header'` assertion, and a new `PASS:` line.
  - New STUCK case appended at EOF: `late-drop.part` with a three-hour-old mtime and fresh ctime, sorter at `RECONCILE_IDLE=1 STUCK_AGE_MIN=60`, three `reconcile scan` lines, `assert_log_absent_for 'STUCK >' 3`, file-still-present assertion, `PASS:` line, `stop_sorter`.

## Decisions Made

- **Padded fixtures reused the existing HEIF case block** rather than getting their own sorter start. 02-CONTEXT.md § Claude's Discretion left this open; reusing the block adds two files to a batch that already runs `SORT_WORKERS=4` and costs no extra sorter lifecycle. The raised `wait_for_count`/`wait_for_lines` expectations (4 sorted, 4 notify rows, quarantine still 2) are what prove the padded files sorted rather than quarantined.
- **The truncated-box-header negative assertion is whole-log, not per-file.** Safe because `write_truncated_heif` trips a *different* message (`heif box overruns EOF`) and the case truncates `sorter.log` with `: >` before starting the sorter.
- **Comment in `reconcile` avoids the literal string `STUCK >`** so that `grep -c 'STUCK >' sort.sh` stays at 1, preserving the plan's "log prefix was not reworded" check as a meaningful signal rather than one inflated by prose.

## Deviations from Plan

No code deviations — the plan executed as written. Two acceptance-criterion proxies needed adjusted grep invocations; neither reflects a substantive difference in the delivered code.

**1. [Plan criterion imprecision, not a code change] `grep -A6 'write_padded_heif() {' | grep -c 'count=60'` returns 0, not 1**
- **Found during:** Task 1 verification
- **Issue:** The `-A6` window is too small to reach the `dd ... count=60` line. D-03 mandates a comment carrying both the byte accounting *and* the why-the-mdat-size-is-explicit rationale; with the required 6-line comment plus `local path=$1`, `{`, and three `printf` lines, `count=60` sits at offset 12. The criterion is only satisfiable with a zero-line comment, which contradicts D-03. For reference, the pre-existing `write_valid_heif` has a 2-line comment and its own `dd` at offset 8, so `-A6` would fail on the sibling too.
- **Resolution:** No code change. Substance verified with a wider window: `grep -A14 'write_padded_heif() {' tests/parallel-sort.sh | grep -c 'count=60'` → `1`. The fixture's runtime behavior is proven directly by `PASS: padded HEIF/HIF with trailing alignment bytes sorts` on tower.

**2. [Grep invocation, not a code change] `wait_for_count "$TEST_ROOT/data/sorted" 4 30` count needs `-F`**
- **Issue:** Without `grep -F`, the `$` in `$TEST_ROOT` is interpreted by GNU grep's BRE engine and the pattern misses. Same for the `-cmin +"$STUCK_AGE_MIN"` adjacency check.
- **Resolution:** Re-ran as fixed-string greps. `grep -c -F 'wait_for_count "$TEST_ROOT/data/sorted" 4 30'` → `2` (the pre-existing four-file case at line 845 plus the raised HEIF case at line 894; the criterion asks for "at least 1"). `grep -F -A2 -- '-cmin +"$STUCK_AGE_MIN"' sort.sh | grep -c 'STUCK >'` → `1`.

**Total deviations:** 0 code changes. 2 verification-command corrections.

## Deferred / Skipped Work

**D-07's positive `STUCK >1min` case was deliberately skipped**, under D-07's own "skip it if it would add more than ~90 seconds" budget rule. Reasoning:

- `STUCK_AGE_MIN` is validated against `^[1-9][0-9]*$` in `sort.sh`'s numeric-knob loop, so `STUCK_AGE_MIN=0` exits 2 at startup. **1 is the floor.**
- GNU findutils truncates the age to whole minutes before the `+n` comparison (the documented `-atime +1` rule: "a file has to have been accessed at least two days ago"). So `-cmin +1` does not fire until the file's ctime is roughly **120 seconds** old, not the ~65 s D-07 assumed.
- ~125 s of pure sleeping added to a suite that runs 211-222 s would grow it by ~57%, well past D-07's ~90 s budget.

**Substituted assertion** (zero runtime cost, guards the same regression — T-02-04 "STUCK scan silently stops firing"): the `-cmin +"$STUCK_AGE_MIN"` find and the `STUCK >` log line must remain adjacent inside `reconcile`, verified by `grep -F -A2 -- '-cmin +"$STUCK_AGE_MIN"' sort.sh | grep -c 'STUCK >'` → `1`, plus `grep -c 'STUCK >' sort.sh` → `1` proving the log prefix was not reworded. Combined with the negative runtime case, this covers "the scan exists and still logs STUCK" and "it keys on ctime". The only thing left unproven is GNU find's own `-cmin` semantics, which is not this project's code.

## Issues Encountered

None blocking. The acceptance run passed on the first attempt with no retries and no fixes needed.

## User Setup Required

None — no external service configuration required.

## Next Phase Readiness

- SORT-01 and SORT-02 fully satisfied and marked Complete in `.planning/REQUIREMENTS.md`.
- Phase 3's observability work can now treat the `STUCK >Nmin:` line as a trustworthy signal — it no longer fires on SMB drags, so alerting on it will not train the operator to ignore it.
- Note for whoever touches the panel's age display in Phase 3: CONCERNS.md item 3 covers the *same* mtime-as-arrival-time root cause on the panel side. This plan fixed only the sorter's stuck scan; the panel's age computation is still mtime-based and is Phase 3's scope.
- No blockers.

## Verification Evidence

**Task 3 — `PASS parallel-sort` on tower (2026-09-01):**

```
PASS parallel-sort
```

- Last line of `/tmp/gsd-parallel-sort-02.log` is exactly `PASS parallel-sort`
- `grep -c '^PASS:' /tmp/gsd-parallel-sort-02.log` → `50` (48 Phase 1 baseline + 1 from Task 1 + 1 from Task 2; full suite ran, no early exit)
- `grep -c 'FAIL' /tmp/gsd-parallel-sort-02.log` → `0`
- `grep -F -c 'PASS: padded HEIF/HIF with trailing alignment bytes sorts'` → `1`
- `grep -F -c 'PASS: fresh arrival with an old mtime is not reported stuck'` → `1`
- `grep -F -c 'PASS: HEIC and HEIF used bounded ISO-BMFF validation'` → `1` (pre-existing HEIF case still passes with its raised expectations)

**Wall clock:** `2026-09-01T21:35:22Z` → `2026-09-01T21:39:04Z` = **222 s (3m42s)**, against the 211 s Phase 1 baseline. The +11 s is consistent with two added cases (the padded fixtures ride along in an existing batch; the STUCK case adds one sorter lifecycle plus ~3 s of reconcile observation).

**Tower cleanup proof (read-only commands only):**

```
$ ssh -o BatchMode=yes root@10.0.0.100 'ls -d /tmp/gsd-test-* 2>/dev/null | wc -l; docker images --format "{{.Repository}}:{{.Tag}}" | grep -c gsd-test || true'
0
0
```

Zero leftover `gsd-test-*` directories, zero leftover `gsd-test` images. No docker verb other than the helper's own `build` / `run --rm` / `rmi` was issued; no production container was named; no `/mnt` path and no credential file was touched.

**Static gates (local, `bash -n` only — neither script was executed on the Mac):**

| Check | Expected | Actual |
|-------|----------|--------|
| `bash -n sort.sh` | exit 0 | exit 0 |
| `bash -n tests/parallel-sort.sh` | exit 0 | exit 0 |
| `grep -F -c 'box_count > 0 )) && break' sort.sh` | 1 | 1 |
| `grep -c -- '-cmin +' sort.sh` | 1 (was 0) | 1 |
| `grep -c -- '-mmin +' sort.sh` | 2 (was 3) | 2 |
| `grep -c 'STUCK >' sort.sh` | 1 unchanged | 1 |
| `grep -c 'STABLE_SKIP_AGE' sort.sh` | 4 unchanged | 4 |
| `grep -c -- "-name '.pureftpd-upload.*' -mmin" sort.sh` | 1 | 1 |
| `git diff -- sort.sh \| grep -c '^[+-]'` (Task 1) | ≤ 20 | 13 |
| `grep -c 'write_padded_heif' tests/parallel-sort.sh` | 3 | 3 |
| `grep -F -c '\x00\x00\xea\x68mdat' tests/parallel-sort.sh` | 1 | 1 |
| `grep -F -c "printf '\x00\x00\x00'" tests/parallel-sort.sh` | 1 | 1 |
| `grep -c 'padded-camera' tests/parallel-sort.sh` | ≥ 6 | 6 |
| `grep -c 'echo "PASS:' tests/parallel-sort.sh` | 50 | 50 |
| `grep -c 'late-drop.part' tests/parallel-sort.sh` | ≥ 4 | 4 |
| `grep -F -c 'touch -d "@$(( $(date +%s) - 10800 ))"' tests/parallel-sort.sh` | 1 | 1 |
| `grep -F -c "assert_log_absent_for 'STUCK >' 3" tests/parallel-sort.sh` | 1 | 1 |
| `grep -c 'STUCK_AGE_MIN=60' tests/parallel-sort.sh` | ≥ 3 | 3 |
| `grep -c 'RECONCILE_IDLE=1 ' tests/parallel-sort.sh` | 3 | 3 |
| `grep -c 'STUCK >1min' tests/parallel-sort.sh` | 0 (D-07 skipped) | 0 |
| `git diff --name-only HEAD~2..HEAD` | 2 files only | `sort.sh`, `tests/parallel-sort.sh` |

**Padded-fixture box walk (traced before the tower run, confirmed by the passing case):**
ftyp at 0 (size 24) → offset 24; meta (size 12) → offset 36; mdat (size 60,008) → offset 60,044; `60044 < 60047` so the loop re-enters with `remaining = 3` and `box_count = 3`, the new branch breaks, and the post-loop `ftyp_seen`/`meta_seen` checks return 0.

## Known Stubs

None. Both changes are complete implementations with runtime coverage on tower.

## Threat Flags

None. No new network endpoint, auth path, file-access pattern, or schema change was introduced. The one relaxed parser guard (T-02-01) is bounded to a `remaining < 8` window below the 8-byte minimum box header, gated on `box_count > 0`, and backed by the untouched post-loop `ftyp_seen`/`meta_seen` checks and the untouched `box_size > remaining` overrun check — the latter re-proven at runtime by the still-passing truncated-HEIF quarantine assertions.

---
*Phase: 02-sorter-correctness*
*Completed: 2026-09-01*
