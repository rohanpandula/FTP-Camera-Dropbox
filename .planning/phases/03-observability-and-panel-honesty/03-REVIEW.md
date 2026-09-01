---
phase: 03-observability-and-panel-honesty
reviewed: 2026-09-01T00:00:00Z
depth: standard
files_reviewed: 8
files_reviewed_list:
  - contrib/unraid/ftpdropbox-healthcheck.sh
  - tests/fixtures/healthcheck/docker
  - tests/unraid-healthcheck.sh
  - panel/app.py
  - panel/index.html
  - panel/tests/test_quarantine.py
  - frameio-mirror/app.py
  - frameio-mirror/tests/test_logging.py
findings:
  critical: 1
  warning: 2
  info: 2
  total: 5
status: issues_found
---

# Phase 03: Observability and Panel Honesty — Code Review Report

**Reviewed:** 2026-09-01
**Depth:** standard
**Files Reviewed:** 8
**Status:** issues_found

## Summary

Reviewed the diff against `14a0b7d` for all three independent changes: (A) the FTP-abort Telegram probe in `contrib/unraid/ftpdropbox-healthcheck.sh` plus its test fixtures/harness cases, (B) `panel/app.py`/`index.html`'s ctime-based arrival age and byte-verified `prune_verified`, and (C) `frameio-mirror/app.py`'s two `%s: %r` exception-logging fixes.

Plan C is clean — both changed log lines were traced to their call sites and empirically verified to (a) actually fix the blank-message bug the tests target (confirmed `str(httpx.ReadTimeout(""))` is `''`), and (b) not leak the Telegram bot token via `repr(exc)` (confirmed empirically: `repr()` on an `httpx` transport exception does not surface the `.request.url` attribute). `frameio-mirror`'s full suite passes (59 passed, 5 subtests).

Plan A's parsing/pairing/dedup logic is solid and matches the documented production log shapes; all 5 new harness cases exercise real behavior (verified by reading the fixture `logs)` branch and tracing session-key overwrite semantics). One narrow data-integrity edge case was found in the session-dictionary cleanup, plus an inconsistency versus this script's own established defense-in-depth pattern for state files.

Plan B has one proven Critical finding: the shared library index that now gates real deletions in `prune_verified` doesn't reject symlinked candidates on the `sorted/` side, while the quarantine side does. Given this codebase's own documented threat model (`/data` is SMB-writable by LAN clients — the reason `.panel/` subdirectories, `noclobber_move`, and the CSRF guard all exist), this is exploitable to make the panel delete a quarantine file with no genuine archived backing. I built a standalone reproduction against the actual `app.py` (not the test file) and confirmed the delete happens. Both panel test suites (4 tests) and the frameio-mirror suite (59 tests) pass; `age_s`/`kept`/`in_library` semantics all check out against their spec (D-07/D-08/D-09).

## Critical Issues

### CR-01: `prune_verified` follows symlinked "library" candidates and can delete a quarantine file with no genuine archived copy backing it

**File:** `panel/app.py:605-625` (root cause: `_library_name_sizes`), consumed at `panel/app.py:666-687` (`prune_verified`)
**Issue:**

`_library_name_sizes()` builds the candidate index by walking `sorted/` and calling `f.stat()` on every entry with no `is_symlink()` check:

```python
616        if SORTED.is_dir():
617            for f in walk_files(SORTED):
618                try:
619                    st = f.stat()
620                    index.setdefault(f.name, {}).setdefault(st.st_size, []).append(f)
621                except OSError:
622                    continue
```

`prune_verified` then iterates these candidates and, on the first `filecmp.cmp(f, candidate, shallow=False) == True`, unconditionally deletes the quarantine file:

```python
666        for f in list(walk_files(QUAR)):
667            try:
668                if f.is_symlink():        # <- quarantine side IS checked
669                    continue
670                st = f.stat()
671                candidates = index.get(f.name, {}).get(st.st_size, [])
...
675                for candidate in candidates:   # <- candidate side is NOT checked
676                    try:
677                        if filecmp.cmp(f, candidate, shallow=False):
678                            identical = True
679                            break
```

`Path.stat()`, `filecmp.cmp()`, and `open()` all follow symlinks. Because the quarantine side explicitly skips symlinks but the library-candidate side does not, a symlink placed inside `sorted/<date>/<type>/` with a name and apparent size matching a real quarantine file — but pointing anywhere else readable by the panel process — is accepted as a verified "library copy" and triggers deletion of the quarantine file, even though nothing durable was ever archived.

This matters specifically because `/data` (which contains `sorted/`) is documented in this codebase as SMB-writable by LAN clients — that's the exact threat this same file already defends against elsewhere (the startup hook refuses to start if `.panel`/`THUMBS`/`PENDING`/`RESOLVED` are symlinks, `noclobber_move` uses `os.link(..., follow_symlinks=False)`). `sorted/` itself gets no equivalent protection here, and `prune_verified` now performs a real, irreversible `f.unlink()` gated on it. `PROJECT.md` states "Silent loss is the one failure this system must never have"; this defeats the specific safeguard (byte verification) this diff was written to add.

**Proof (empirical, not run against production data — built and run against a scratch `DATA_ROOT`, no real files touched):**
```python
# quarantine file with NO real backing copy anywhere in sorted/
quar_file = QUAR/"2026-01-01"/"DSC-VICTIM.ARW"; quar_file.write_bytes(payload)
# attacker-controlled file OUTSIDE sorted/, plus a symlink inside sorted/ pointing at it
outside = DATA/"outside_sorted_evidence.bin"; outside.write_bytes(payload)
os.symlink(outside, SORTED/"2026-01-01"/"raw"/"DSC-VICTIM.ARW")

POST /api/quarantine/action {"action": "prune_verified"}
# -> {"ok": true, "removed": 1, "kept": 0}
# quar_file.exists() -> False
```
This reproduces cleanly against the current `panel/app.py`.

Note: the *old* code (pre-diff, at `14a0b7d`) had the same missing check but gated deletion on name+size alone (no byte comparison at all), which was even easier to trigger. This diff raises the bar (attacker now also needs the symlink target's bytes to match) but does not close the underlying gap, and it's the diff that turned this index from a soft UI hint into a live deletion gate.

**Fix:** Reject symlinks in the shared index (root-cause fix — also cleans up the `in_library` hint in `api_quarantine`, which currently can claim `in_library: true` for a hint that isn't backed by a real file either):
```python
if SORTED.is_dir():
    for f in walk_files(SORTED):
        try:
            if f.is_symlink():
                continue
            st = f.stat()
            index.setdefault(f.name, {}).setdefault(st.st_size, []).append(f)
        except OSError:
            continue
```
Add a regression test alongside `test_prune_verified_keeps_same_size_different_bytes`: a same-name/same-size symlink under `sorted/` pointing at a byte-identical file elsewhere must leave the quarantine file in place (`removed == 0`).

## Warnings

### WR-01: `unset "ftp_notice[$session]"` silently no-ops when the session key contains `]`, causing stale abort data to be replayed

**File:** `contrib/unraid/ftpdropbox-healthcheck.sh:264`
**Issue:** The session key (`user@host` captured from pure-ftpd's log, where `host` reflects the client's reported/reverse-DNS identity — exactly the "attacker-influenced log content" this review was asked to scrutinize) is used as `unset "ftp_notice[$session]"`. This is a *dynamically substituted string* that bash's `unset` has to re-parse as `name[subscript]` syntax at runtime — unlike a direct `${ftp_notice[$session]}` reference (which bash's parser resolves the subscript for at parse time and never re-parses). Verified empirically:
```bash
$ declare -A m=(); session='weird]host'; m[$session]="value1"
$ unset "m[$session]"; echo "${m[$session]:-EMPTY}"
value1        # <- unset silently failed; the stale entry is still there
```
Concretely: if two `451-Transfer aborted` events occur for the same odd session key without an intervening `[NOTICE] ... uploaded` line between them, the second abort will incorrectly reuse the first abort's stale filename/bytes/speed instead of correctly falling back to "unknown file". This is a data-integrity bug in alert *content*, not an injection/code-execution risk — `$session` is never re-interpreted as a command, only as an array subscript, and the pipe-delimited `pair` field round-trips correctly through `${rest#*|}` even when the filename itself contains `|` (verified separately).
**Fix:** Use a form that doesn't require `unset` to re-parse a data-driven string, e.g. a nameref, or simply drop the stale entry via reassignment instead of unset:
```bash
ftp_notice[$session]=""   # or: unset -v 'ftp_notice['"$session"']' is not any safer; prefer reassignment
```
or, simpler, don't rely on deletion at all — the next `[NOTICE]` for that session already overwrites the entry; only skip re-pairing by tracking a separate "already paired" set keyed the same (safe) way values are read elsewhere.

### WR-02: `ftp-aborts.seen` gets none of the symlink/ownership/hardlink verification this script applies to every other state file

**File:** `contrib/unraid/ftpdropbox-healthcheck.sh:276-283`
**Issue:** `$STATE`, `$HEALTH_LOCK`, `$BACKUP_STAMP`, and `$MAINTENANCE_MARKER` are all validated for `uid:gid:mode:nlink` and rejected if they're symlinks or hardlinks before being trusted (see `prepare_state_storage`, the `$HEALTH_LOCK` block, and the backup-stamp block). `ftp-aborts.seen` gets none of that:
```bash
276          seen_file="${STATE%/*}/ftp-aborts.seen"
277          [ -e "$seen_file" ] || (umask 077; : > "$seen_file")
278          if ! grep -Fqx "$fingerprint" "$seen_file" 2>/dev/null && tg "$message"; then
279            printf '%s\n' "$fingerprint" >> "$seen_file"
```
Practical exploitability is low today — the containing directory (`${STATE%/*}`) is already verified `root:root 0700` by `prepare_state_storage()` before this code runs, so only root could plant something malicious at this path in the first place. But this is a real inconsistency with CONVENTIONS.md's own stated rule for this script ("Paths are security boundaries... recheck ... after every rename") and with the paranoid posture applied to every sibling state file in the same directory. If `STATE`'s parent directory validation is ever relaxed or this file's path is ever made configurable, there's no independent guard here to catch it.
**Fix:** Apply the same `-L`/`-f`/`stat -c '%u:%g:%a:%h'` check used for `$BACKUP_STAMP` before the first read/append each run, or at minimum before the `grep`/`>>` in a fresh run (not just at creation time).

## Info

### IN-01: No harness case exercises "docker logs fails" (D-04)

**File:** `tests/unraid-healthcheck.sh`, `tests/fixtures/healthcheck/docker:50-55`
**Issue:** The review brief and the script's own header comment call out that a failed `docker logs` (or unresolved `$ftp_container`) must be a silent no-op (D-04). The 5 new cases cover pairing, dedup, success-only, two-aborts, and unpaired-abort, but none simulate a non-zero `docker logs` exit or missing container. The stub's `logs)` branch (`tests/fixtures/healthcheck/docker:50-55`) always `exit 0`, so there's no way to drive this path today.
**Fix:** Add a `FAKE_LOGS_RC` env var to the stub (mirroring `FAKE_DOCKER_INFO_RC`/`FAKE_START_RC`) and a harness case asserting no curl call and no `health.state` write when `docker logs` fails.

### IN-02: `mktemp` return value unchecked when trimming `ftp-aborts.seen`

**File:** `contrib/unraid/ftpdropbox-healthcheck.sh:280`
**Issue:** `commit_state()` (line 95) checks `mktemp ... || return 1` before using the temp path. The abort-alert block's trim step doesn't:
```bash
280            seen_tmp=$(mktemp "${seen_file}.tmp.XXXXXX")
281            chmod 0600 -- "$seen_tmp"
282            tail -n 500 "$seen_file" > "$seen_tmp"
283            mv -f -- "$seen_tmp" "$seen_file"
```
If `mktemp` fails (e.g. ENOSPC), `seen_tmp` is empty and the subsequent `chmod`/`tail`/`mv` fail with stderr noise but no crash — dedup itself is unaffected since the fingerprint was already appended via `>>` on line 279 before this block runs, so the only consequence is the 500-line cap silently not being enforced for that cycle. Low impact given fingerprint lines are ~65 bytes each, but worth matching the existing `commit_state` pattern for consistency.
**Fix:** `seen_tmp=$(mktemp "${seen_file}.tmp.XXXXXX") || return` (or skip the trim block) if `mktemp` fails.

---

_Reviewed: 2026-09-01_
_Reviewer: Claude (gsd-code-reviewer)_
_Depth: standard_
