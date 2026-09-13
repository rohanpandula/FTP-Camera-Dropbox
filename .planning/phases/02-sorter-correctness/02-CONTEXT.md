# Phase 2: Sorter Correctness - Context

**Gathered:** 2026-09-01
**Status:** Ready for planning
**Source:** Orchestrator decisions from the 2026-09-01 live-deployment review (every decision below is locked)
**Executor model:** opus (orchestrator flips `models.execution` before running this phase)

<domain>
## Phase Boundary

Two surgical changes to `sort.sh`, each with a harness case in `tests/parallel-sort.sh`: (1) `heif_container_validate` tolerates a short trailing alignment pad after the last box; (2) the reconcile STUCK scan keys on ctime instead of mtime. Nothing else in `sort.sh` changes. The full harness must pass inside the sorter image (use `tests/run-on-tower.sh parallel-sort` from Phase 1).

</domain>

<decisions>
## Implementation Decisions

### HEIF trailing-pad tolerance (SORT-01)
- **D-01:** In `heif_container_validate`, the guard that currently reads
  ```bash
  remaining=$((file_size - offset))
  (( remaining >= 8 )) || {
    log "validate: heif truncated box header at byte $offset"
    return 1
  }
  ```
  becomes
  ```bash
  remaining=$((file_size - offset))
  if (( remaining < 8 )); then
    # Some writers pad the file to 4-byte alignment after the last box
    # (X100VI DSCF8283.HIF: three zero bytes past mdat; exiftool accepts it).
    # A real truncation is still caught below: the cut box's declared size
    # overruns EOF. Only a walk that already parsed a box may stop here.
    (( box_count > 0 )) && break
    log "validate: heif truncated box header at byte $offset"
    return 1
  fi
  ```
  The `ftyp_seen`/`meta_seen` checks after the loop stay as they are. No other line of the validator changes.
- **D-02:** Do not require the pad bytes to be zero and do not cap the pad below 8; the box-size arithmetic already guarantees anything 8 bytes or longer is parsed as a box.
- **D-03:** Add `write_padded_heif` beside `write_valid_heif` (harness lines 40-62). Layout: the same `ftyp` (24 bytes) and `meta` (12 bytes) as `write_valid_heif`, then an `mdat` with an EXPLICIT size of 60008 (`printf '\x00\x00\xea\x68mdat'` followed by `dd if=/dev/zero bs=1000 count=60`), then three trailing zero bytes (`printf '\x00\x00\x00'`). Total 60047 bytes, above the 50000-byte floor. The explicit mdat size matters: the existing valid fixture uses a zero-size mdat that extends to EOF and would swallow the pad.
- **D-04:** New harness assertions in the existing HEIF case (around lines 837-886): write `padded-camera.heif` and `padded-camera.hif` (main maps `.hif` to the heif type); both must land under `sorted/*/heif/` with unchanged sha256; `truncated-camera.heic`/`.heif` must still quarantine; the log must contain no `validate: heif truncated box header` line for the padded fixtures. Print `PASS: padded HEIF/HIF with trailing alignment bytes sorts` on success.

### ctime for the STUCK scan (SORT-02)
- **D-05:** In `reconcile()`, only the stuck scan changes: `find "$INCOMING" -type f -mmin +"$STUCK_AGE_MIN" -print0` becomes `-cmin +"$STUCK_AGE_MIN"`, with a comment: SMB drags preserve capture-time mtime, so mtime says when the shot was taken, not when the file arrived; ctime is set by the create/write/rename that landed it. `prune_stale_ftp_tmp` and `prune_stale_raw_tmp` keep `-mmin` (an in-flight temp is being written; its mtime is the right signal), and `wait_stable`'s `STABLE_SKIP_AGE` keeps mtime on purpose (old-mtime drops skip the settle wait).
- **D-06:** Harness case (mandatory, negative): create `"$TEST_ROOT/data/incoming/late-drop.part"` and set its mtime three hours back with `touch -d "@$(( $(date +%s) - 10800 ))" ...` (GNU touch in the image); ctime is now. `.part` names are skipped by `process()` so the file stays in incoming. Start the sorter with `STUCK_AGE_MIN=60 RECONCILE_IDLE=1` plus the usual `STABLE_WAIT=1 LOCK_ROOT=...`, wait for at least two `reconcile scan` lines, then assert no `STUCK` line appears (`assert_log_absent_for` with the existing helper) and print `PASS: fresh arrival with an old mtime is not reported stuck`. Before D-05 this case fails, which is the point.
- **D-07:** Positive case (recommended, at Claude's discretion if it fits the suite's runtime): the same file with `STUCK_AGE_MIN=1`, wait about 65 seconds, expect exactly one `STUCK >1min: late-drop.part` line. Skip it if it would add more than ~90 seconds.

### Verification
- **D-08:** Acceptance is the full harness inside the sorter image: `tests/run-on-tower.sh parallel-sort` prints `PASS parallel-sort` with the existing 48 cases plus the new ones. Do not run `sort.sh` or the harness on the Mac.
- **D-09:** Commit as two commits: `sort.sh: accept trailing alignment pad after the last HEIF box` and `sort.sh: key the STUCK scan on ctime, not mtime`, each with its harness case. Each body names the observed failure (DSCF8283.HIF quarantine on 2026-08-28; nine R00000xx false STUCK lines on 2026-08-29).

### Claude's Discretion
- Whether the padded fixtures join the existing HEIF case block or get their own `PASS:` block.
- Log wording inside the comment.

</decisions>

<specifics>
## Specific Ideas

- Evidence for D-01: `quarantine/2026-08-22/DSCF8283.HIF` on tower is 10502144 bytes; boxes ftyp 24, meta 1007, free 3057, mdat 10498053 end at byte 10502141; the last three bytes are `00 00 00`. Running the deployed validator against it logs `validate: heif truncated box header at byte 10502141`; against its sorted sibling `DSCF8284.HIF` it returns 0.
- Evidence for D-05: sorter log 2026-08-29 04:23:06 UTC logged `STUCK >60min` for `R0000028-2.JPG` through `R0000031-2.JPG`; the same files logged `ok:` at 04:23:07-08 from inotify events. They had arrived seconds earlier by SMB drag with Aug 28 mtimes.

</specifics>

<canonical_refs>
## Canonical References

**Downstream agents MUST read these before planning or implementing.**

### Code under change
- `sort.sh` — `heif_container_validate` (grep `heif truncated box header`), `reconcile` (grep `STUCK >`), `wait_stable` (why mtime stays there), `prune_stale_ftp_tmp`
- `tests/parallel-sort.sh` — lines 40-62 (fixture writers), 140-235 (`fail`, `wait_for_log`, `wait_for_log_count`, `assert_log_absent_for`), 837-886 (existing HEIF case), any block that starts a sorter with `RECONCILE_IDLE=1` (the pattern to copy for D-06)

### Context
- `.planning/PROJECT.md` — Key Decisions (HEIF pad, ctime) and § Context findings 1 and 3
- `.planning/codebase/CONVENTIONS.md` — validator return contract, log vocabulary, `# ponytail:` markers
- `.planning/codebase/TESTING.md` — harness idioms; ctime cannot be set backwards
- `tests/run-on-tower.sh` (from Phase 1) — the only sanctioned way to run the harness

</canonical_refs>

<code_context>
## Existing Code Insights

### Reusable Assets
- `write_valid_heif` / `write_truncated_heif` show the exact byte layout; copy the `printf` style.
- `assert_log_absent_for <pattern> <seconds>` already exists for negative assertions.

### Established Patterns
- Every validator branch logs `validate: <reason>` before returning 1; keep that for the truncated path.
- Harness cases start a fresh sorter per scenario and stop it with `stop_sorter`.

### Integration Points
- `validate_file` calls `heif_container_validate "$f" "$original_ext"` for type `heif`; `get_type` maps `heic|heif|hif`.
- `reconcile` runs at startup (drain) and every `RECONCILE_IDLE` seconds; the stuck scan is its last step.

</code_context>

<deferred>
## Deferred Ideas

- Per-model RAW size floors (SORT-03): leave; no false positive observed.
- Excluding `.part`/dotfiles from the stuck scan: not needed; pure-ftpd temps are pruned first and the panel shows them as "receiving".

</deferred>

---

*Phase: 02-sorter-correctness*
*Context gathered: 2026-09-01 by the orchestrator*
