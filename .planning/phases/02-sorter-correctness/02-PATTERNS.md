# Phase 02: Sorter Correctness - Pattern Map

**Mapped:** 2026-09-01
**Files analyzed:** 2 (sort.sh, tests/parallel-sort.sh)
**Analogs found:** 5/5 (100% — all changes are modifications to existing functions)

## File Classification

| File | Role | Data Flow | Closest Analog | Match Quality |
|------|------|-----------|----------------|---------------|
| `sort.sh::heif_container_validate` | validator (utility) | file-I/O | self (existing function) | exact-modify |
| `sort.sh::reconcile` | dispatcher/scheduler (utility) | file-I/O + event-driven | self (existing function) | exact-modify |
| `sort.sh::prune_stale_raw_tmp` | cleanup (utility) | file-I/O | self (existing function) | exact-reference |
| `sort.sh::prune_stale_ftp_tmp` | cleanup (utility) | file-I/O | self (existing function) | exact-reference |
| `sort.sh::wait_stable` | waiter (utility) | file-I/O | self (existing function) | exact-reference |
| `tests/parallel-sort.sh::write_padded_heif` | test fixture writer | file-I/O (write) | write_valid_heif / write_truncated_heif | exact |
| `tests/parallel-sort.sh::test case (HEIF padding)` | test case | request-response | existing HEIF case (lines 846-905) | exact |
| `tests/parallel-sort.sh::test case (ctime STUCK)` | test case | request-response | existing RECONCILE_IDLE=1 cases (lines 427, 606) | exact |

---

## Pattern Assignments

### `sort.sh::heif_container_validate` — modify the guard at lines 869–873

**Location:** `/Users/rohan/Projects/FTP-Camera-Dropbox/sort.sh`, lines 842–962

**Current guard** (lines 869–873):
```bash
remaining=$((file_size - offset))
(( remaining >= 8 )) || {
  log "validate: heif truncated box header at byte $offset"
  return 1
}
```

**Pattern to copy — ftyp/meta checks after the loop** (lines 959–961):
```bash
(( ftyp_seen == 1 )) || { log "validate: heif missing ftyp box"; return 1; }
(( meta_seen == 1 )) || { log "validate: heif missing meta box"; return 1; }
return 0
```

**Why:** The modification adds a conditional break that allows the loop to exit early if we've already parsed at least one box and encounter padding (< 8 remaining bytes). The ftyp/meta checks stay exactly as-is: they still validate the presence of required boxes, just after a loop that may now exit gracefully on padding.

**Key detail:** line 956 increments `box_count`, so by the time we encounter the remaining < 8 check, `box_count > 0` when we've parsed the ftyp/meta and reached the trailing pad.

---

### `sort.sh::reconcile` — change the stuck scan at line 2078

**Location:** `/Users/rohan/Projects/FTP-Camera-Dropbox/sort.sh`, lines 2065–2082

**Current stuck scan** (lines 2078–2080):
```bash
find "$INCOMING" -type f -mmin +"$STUCK_AGE_MIN" -print0 2>/dev/null | while IFS= read -r -d '' f; do
  log "STUCK >${STUCK_AGE_MIN}min: $(log_name "$f")"
done
```

**Context before (why mtime is wrong here):**
- Lines 2052: `prune_stale_ftp_tmp` scans with `-mmin +"$STUCK_AGE_MIN"` (keeps mtime for FTP temp detection)
- Line 2038: `prune_stale_raw_tmp` scans with `-mmin +"$RAW_VALIDATE_TMP_STALE_MIN"` (keeps mtime for in-flight validation detection)

**Pattern to reference for mtime usage** (line 2052):
```bash
find "$INCOMING" -type f -name '.pureftpd-upload.*' -mmin +"$STUCK_AGE_MIN" \
  -exec rm -f -- {} + 2>/dev/null
```

**Pattern to reference for ctime usage** (line 2061, in prune_stale_dupes):
```bash
find "$QUARANTINE/_dupes" -type f -ctime +"$DUPES_KEEP_DAYS" -delete 2>/dev/null
```

**Comment to add** (from D-05):
```bash
# SMB drags preserve capture-time mtime, so mtime says when the shot was taken,
# not when the file arrived; ctime is set by the create/write/rename that landed it.
```

**Key detail:** The log message itself stays unchanged; only the `-mmin` operator becomes `-cmin`.

---

### `sort.sh::prune_stale_raw_tmp` — reference pattern for -mmin with directories

**Location:** `/Users/rohan/Projects/FTP-Camera-Dropbox/sort.sh`, lines 2032–2040

**Pattern:**
```bash
prune_stale_raw_tmp() {
  [[ -d "$RAW_VALIDATE_TMPDIR" ]] || return 0
  # raw_payload_validate creates only raw.* directories here. A validation is
  # bounded to four minutes by default, so 15-minute-old entries are abandoned
  # scratch from a hard stop and can be removed safely.
  find "$RAW_VALIDATE_TMPDIR" -mindepth 1 -maxdepth 1 -type d \
    -name 'raw.*' -mmin +"$RAW_VALIDATE_TMP_STALE_MIN" \
    -exec rm -rf -- {} + 2>/dev/null
}
```

**Why it stays unchanged:** This scans directories created during validation, not files received from outside. Its mtime is the creation time of the validation, not the camera's capture time. Keeps -mmin per D-05 comment.

---

### `sort.sh::prune_stale_ftp_tmp` — reference pattern for why mtime stays here

**Location:** `/Users/rohan/Projects/FTP-Camera-Dropbox/sort.sh`, lines 2042–2054

**Pattern:**
```bash
prune_stale_ftp_tmp() {
  # pure-ftpd runs with -0 (atomic uploads): an in-flight transfer is a
  # .pureftpd-upload.* dot-temp, so process() never sees it. Stock pure-ftpd
  # renames that temp onto the real name even after a 451 abort (which is how
  # truncated partials used to reach quarantine); the fork under pure-ftpd/
  # unlinks it on abort instead. Either way pure-ftpd aborts stalled transfers
  # at ~15 min and cameras re-send whole files (never REST/resume), so an
  # hour-old temp has no living writer — it is debris from a pure-ftpd crash.
  # Pruned at STUCK_AGE_MIN so debris disappears before the stuck scan below
  # would flag it. Without -0 this find matches nothing.
  find "$INCOMING" -type f -name '.pureftpd-upload.*' -mmin +"$STUCK_AGE_MIN" \
    -exec rm -f -- {} + 2>/dev/null
}
```

**Key detail:** This scans in-flight temp files whose mtime is the start of the FTP write, not the camera's capture time. Keeps -mmin per D-05 comment; the comment explains this is ordered before the STUCK scan so debris doesn't trigger false positives.

---

### `sort.sh::wait_stable` — reference pattern for why STABLE_SKIP_AGE uses mtime

**Location:** `/Users/rohan/Projects/FTP-Camera-Dropbox/sort.sh`, lines 1222–1247

**Pattern** (lines 1227–1241):
```bash
# Skip the wait only for files whose mtime is over STABLE_SKIP_AGE old (1h
# default). Why 1h is safe where the old 60s skip wasn't: pure-ftpd aborts
# stalled transfers at ~15 min (observed 451 Timeouts on 2.4 GHz uploads),
# and camera retries land within minutes — no FTP writer can exist behind an
# hour-old mtime. Bulk SMB drops of already-shot photos (Finder preserves
# mtimes) drain at seconds/file instead of STABLE_WAIT/file. Anything with a
# fresh mtime still pays the full double-stat wait, and the LibRaw unpack in
# validate_file remains the backstop for truncated RAWs.
now=$(date +%s); mtime=$(stat -c %Y "$f" 2>/dev/null || echo "$now")
if (( now - mtime >= STABLE_SKIP_AGE )); then
  [[ -f "$f" && ! -L "$f" ]] || return 1
  end_id=$(path_identity "$f") || return 1
  [[ "$start_id" == "$end_id" ]]
  return
fi
```

**Key detail:** `wait_stable` keeps mtime because it detects in-flight writes (fresh mtime = being written). The comment explains: mtime reflects when the shot was taken (SMB preserves it), so bulk drops skip the wait. This stays unchanged per D-05.

---

### `tests/parallel-sort.sh::write_padded_heif` — fixture writer

**Location:** `/Users/rohan/Projects/FTP-Camera-Dropbox/tests/parallel-sort.sh`, lines 40–62

**Existing fixtures pattern** (lines 40–62):
```bash
write_valid_heif() {
  local path=$1
  {
    # ISO-BMFF: ftyp(heic + compatible mif1/heic), full-box meta, then an
    # mdat whose zero size extends exactly to EOF.
    printf '\x00\x00\x00\x18ftypheic\x00\x00\x00\x00mif1heic'
    printf '\x00\x00\x00\x0cmeta\x00\x00\x00\x00'
    printf '\x00\x00\x00\x00mdat'
    dd if=/dev/zero bs=1000 count=60 2>/dev/null
  } > "$path"
}

write_truncated_heif() {
  local path=$1
  {
    printf '\x00\x00\x00\x18ftypheic\x00\x00\x00\x00mif1heic'
    printf '\x00\x00\x00\x0cmeta\x00\x00\x00\x00'
    # Declares a 65,536-byte mdat but supplies only 60,008 bytes including
    # its header, so a front-of-file brand check alone would falsely pass it.
    printf '\x00\x01\x00\x00mdat'
    dd if=/dev/zero bs=1000 count=60 2>/dev/null
  } > "$path"
}
```

**New fixture to add** (from D-03):
- Same ftyp (24 bytes) and meta (12 bytes) as write_valid_heif
- mdat with EXPLICIT size of 60008 (printf `\x00\x00\xea\x68mdat`)
- Exactly 60 × 1000 = 60,000 bytes of zeros (dd count=60)
- Three trailing zero bytes (printf `\x00\x00\x00`)
- Total: 24 + 12 + 8 (mdat header) + 60,000 + 3 = 60,047 bytes (above 50,000 floor)

**Key detail:** The explicit mdat size (60008) matters: the existing valid fixture uses a zero-size mdat that extends to EOF and would consume the trailing pad bytes. The new fixture needs a bounded mdat so the pad bytes are truly separate.

---

### `tests/parallel-sort.sh::existing HEIF test case` — harness pattern to extend

**Location:** `/Users/rohan/Projects/FTP-Camera-Dropbox/tests/parallel-sort.sh`, lines 846–905

**Fixture writers** (already called at lines 846–849):
```bash
write_valid_heif "$TEST_ROOT/data/incoming/valid-camera.heic"
write_valid_heif "$TEST_ROOT/data/incoming/valid-camera.heif"
write_truncated_heif "$TEST_ROOT/data/incoming/truncated-camera.heic"
write_truncated_heif "$TEST_ROOT/data/incoming/truncated-camera.heif"
```

**Hash capture pattern** (lines 850–853):
```bash
valid_heic_hash=$(sha256sum "$TEST_ROOT/data/incoming/valid-camera.heic" | cut -d' ' -f1)
valid_heif_hash=$(sha256sum "$TEST_ROOT/data/incoming/valid-camera.heif" | cut -d' ' -f1)
truncated_heic_hash=$(sha256sum "$TEST_ROOT/data/incoming/truncated-camera.heic" | cut -d' ' -f1)
truncated_heif_hash=$(sha256sum "$TEST_ROOT/data/incoming/truncated-camera.heif" | cut -d' ' -f1)
```

**Sorter start pattern** (lines 857–869):
```bash
PATH="$ROOT/tests/fixtures/fast-metadata:$PATH" \
INCOMING="$TEST_ROOT/data/incoming" \
SORTED="$TEST_ROOT/data/sorted" \
QUARANTINE="$TEST_ROOT/data/quarantine" \
STABLE_WAIT=1 \
STABLE_SKIP_AGE=1 \
SORT_WORKERS=4 \
RECONCILE_IDLE=30 \
NOTIFY_INTERVAL=3600 \
RAW_FULL_VALIDATE=0 \
TG_CONFIG="$TEST_ROOT/telegram.json" \
  /bin/bash "$SORTER" > "$TEST_ROOT/sorter.log" 2>&1 &
SORTER_PID=$!
```

**Wait and assertion pattern** (lines 871–905):
```bash
wait_for_count "$TEST_ROOT/data/sorted" 2 30 \
  || fail "valid HEIC/HEIF fixtures did not sort"
wait_for_count "$TEST_ROOT/data/quarantine" 2 30 \
  || fail "truncated HEIC/HEIF fixtures were not quarantined"
wait_for_lines "$TEST_ROOT/data/.sort-locks/queues/notify-queue.tsv" 2 30 \
  || fail "valid HEIC/HEIF notification rows were lost"
wait_for_lines "$TEST_ROOT/data/.sort-locks/queues/quarantine-queue.tsv" 2 30 \
  || fail "invalid HEIC/HEIF quarantine rows were lost"

valid_heic_sorted=$(find "$TEST_ROOT/data/sorted" -type f \
  -path '*/heif/valid-camera.heic' -print -quit)
valid_heif_sorted=$(find "$TEST_ROOT/data/sorted" -type f \
  -path '*/heif/valid-camera.heif' -print -quit)
truncated_heic_quar=$(find "$TEST_ROOT/data/quarantine" -type f \
  -name truncated-camera.heic -print -quit)
truncated_heif_quar=$(find "$TEST_ROOT/data/quarantine" -type f \
  -name truncated-camera.heif -print -quit)
[[ -n "$valid_heic_sorted" && -n "$valid_heif_sorted" ]] \
  || fail "HEIC/HEIF outputs did not use their distinct heif type"
[[ -n "$truncated_heic_quar" && -n "$truncated_heif_quar" ]] \
  || fail "truncated HEIC/HEIF quarantine names were not preserved"
[[ $(sha256sum "$valid_heic_sorted" | cut -d' ' -f1) == "$valid_heic_hash" ]] \
  || fail "valid HEIC payload changed during sorting"
[[ $(sha256sum "$valid_heif_sorted" | cut -d' ' -f1) == "$valid_heif_hash" ]] \
  || fail "valid HEIF payload changed during sorting"
[[ $(sha256sum "$truncated_heic_quar" | cut -d' ' -f1) == "$truncated_heic_hash" ]] \
  || fail "truncated HEIC payload changed during quarantine"
[[ $(sha256sum "$truncated_heif_quar" | cut -d' ' -f1) == "$truncated_heif_hash" ]] \
  || fail "truncated HEIF payload changed during quarantine"
[[ $(find "$TEST_ROOT/data/incoming" -type f | wc -l) -eq 0 ]] \
  || fail "HEIC/HEIF batch did not drain incoming"
grep -q 'heif box overruns EOF' "$TEST_ROOT/sorter.log" \
  || fail "truncated HEIC/HEIF rejection was not explained"
```

**Cleanup** (lines 905, 907):
```bash
echo "PASS: HEIC and HEIF used bounded ISO-BMFF validation"

stop_sorter
```

**Key details:**
- Hash before/after to verify payload integrity
- `wait_for_count` for sorted/quarantine file counts (30s timeout)
- `wait_for_lines` for queue row counts (30s timeout)
- Path searches with `-path '*/heif/...'` for sorted, `-name` for quarantine
- Grep for specific error messages in the log
- Always ends with `echo "PASS: ..."` before `stop_sorter`

---

### `tests/parallel-sort.sh::existing RECONCILE_IDLE=1 cases` — pattern for STUCK test

**Location 1:** `/Users/rohan/Projects/FTP-Camera-Dropbox/tests/parallel-sort.sh`, lines 427–449 (held-directory case)

**Sorter start** (lines 420–432):
```bash
PATH="$ROOT/tests/fixtures/fast-metadata:$PATH" \
INCOMING="$TEST_ROOT/data/incoming" \
SORTED="$TEST_ROOT/data/sorted" \
QUARANTINE="$TEST_ROOT/data/quarantine" \
STABLE_WAIT=1 \
STABLE_SKIP_AGE=1 \
SORT_WORKERS=1 \
RECONCILE_IDLE=1 \
NOTIFY_INTERVAL=3600 \
RAW_FULL_VALIDATE=0 \
TG_CONFIG="$TEST_ROOT/telegram.json" \
  /bin/bash "$SORTER" > "$TEST_ROOT/sorter.log" 2>&1 &
SORTER_PID=$!
```

**Wait for reconcile scans** (lines 434–435):
```bash
wait_for_log_count 'reconcile scan' 3 20 \
  || fail "held-directory test did not exercise repeated reconciliation"
```

**Key detail:** `RECONCILE_IDLE=1` makes the sorter reconcile every 1 second, so you can observe multiple `reconcile scan` log lines in a short time. The timeout (20 seconds × TEST_TIMEOUT_SCALE) is generous.

**Location 2:** `/Users/rohan/Projects/FTP-Camera-Dropbox/tests/parallel-sort.sh`, lines 606–624 (leading-dash permission case)

**Sorter start** (lines 599–611):
```bash
PATH="$ROOT/tests/fixtures/fast-metadata:$PATH" \
INCOMING="$TEST_ROOT/data/incoming" \
SORTED="$TEST_ROOT/data/sorted" \
QUARANTINE="$TEST_ROOT/data/quarantine" \
STABLE_WAIT=1 \
STABLE_SKIP_AGE=1 \
SORT_WORKERS=1 \
RECONCILE_IDLE=1 \
NOTIFY_INTERVAL=3600 \
RAW_FULL_VALIDATE=0 \
TG_CONFIG="$TEST_ROOT/telegram.json" \
  /bin/bash "$SORTER" > "$TEST_ROOT/sorter.log" 2>&1 &
SORTER_PID=$!
```

**Wait for multiple reconcile scans and check deduplication** (lines 613–620):
```bash
wait_for_lines "$TEST_ROOT/data/.sort-locks/queues/perm-queue.tsv" 1 20 \
  || fail "leading-dash unreadable name was not queued"
wait_for_log_count 'reconcile scan' 4 20 \
  || fail "leading-dash permission test did not exercise repeated reconciliation"
[[ $(wc -l < "$TEST_ROOT/data/.sort-locks/queues/perm-queue.tsv") -eq 1 ]] \
  || fail "leading-dash unreadable name bypassed permission-queue deduplication"
[[ $(grep -c 'UNREADABLE (permissions): --permission-leading.dat' "$TEST_ROOT/sorter.log") -eq 1 ]] \
  || fail "leading-dash unreadable name was reported more than once"
[[ -f "$TEST_ROOT/data/incoming/--permission-leading.dat" ]] \
  || fail "leading-dash unreadable file did not remain in incoming"
```

**Key detail:** These cases wait for multiple `reconcile scan` entries in the log to verify the sorter is reconciling repeatedly with `RECONCILE_IDLE=1`.

---

### `tests/parallel-sort.sh::helper functions` — ready to use as-is

**wait_for_log** (lines 164–172):
```bash
wait_for_log() {
  local pattern=$1 timeout_seconds=$2
  local deadline=$((SECONDS + timeout_seconds * TEST_TIMEOUT_SCALE))
  while (( SECONDS < deadline )); do
    grep -q "$pattern" "$TEST_ROOT/sorter.log" 2>/dev/null && return 0
    sleep 0.1
  done
  return 1
}
```

**wait_for_log_count** (lines 189–198):
```bash
wait_for_log_count() {
  local pattern=$1 expected=$2 timeout_seconds=$3 count
  local deadline=$((SECONDS + timeout_seconds * TEST_TIMEOUT_SCALE))
  while (( SECONDS < deadline )); do
    count=$(grep -c "$pattern" "$TEST_ROOT/sorter.log" 2>/dev/null || true)
    (( count >= expected )) && return 0
    sleep 0.1
  done
  return 1
}
```

**assert_log_absent_for** (lines 200–208):
```bash
assert_log_absent_for() {
  local pattern=$1 duration_seconds=$2
  local deadline=$((SECONDS + duration_seconds))
  while (( SECONDS < deadline )); do
    grep -q "$pattern" "$TEST_ROOT/sorter.log" 2>/dev/null && return 1
    sleep 0.1
  done
  return 0
}
```

**fail** (lines 140–147):
```bash
fail() {
  echo "FAIL: $*" >&2
  if [[ -f "$TEST_ROOT/sorter.log" ]]; then
    echo "--- sorter log ---" >&2
    tail -80 "$TEST_ROOT/sorter.log" >&2
  fi
  exit 1
}
```

**stop_sorter** (lines 100–124):
```bash
stop_sorter() {
  local descendant descendant_cmd
  local -a descendants=()
  if [[ -n "$SORTER_PID" ]]; then
    stop_pid_bounded "$SORTER_PID"
  fi
  if [[ -n "$SECOND_SORTER_PID" ]]; then
    stop_pid_bounded "$SECOND_SORTER_PID"
  fi
  SORTER_PID=""
  SECOND_SORTER_PID=""

  # Defensively sweep only descendants whose argv contains the exact
  # sorter-under-test path. A prior case must never retain an old log fd or
  # process a later case's freshly recreated data tree.
  mapfile -t descendants < <(list_descendants "$$")
  for descendant in "${descendants[@]}"; do
    descendant_cmd=$({
      tr '\0' ' ' < "/proc/$descendant/cmdline"
    } 2>/dev/null || true)
    if [[ "$descendant_cmd" == *"$SORTER"* ]]; then
      stop_pid_bounded "$descendant"
    fi
  done
}
```

**Key detail:** All helpers accept timeouts scaled by `TEST_TIMEOUT_SCALE` (set at harness start); all sleep in 0.1s increments to avoid excessive CPU polling.

---

## Shared Patterns

### Guard pattern for box boundary checks

**Source:** `/Users/rohan/Projects/FTP-Camera-Dropbox/sort.sh`, lines 908–915

Used throughout heif_container_validate for catching overruns:

```bash
if (( box_size < header_size )); then
  log "validate: heif invalid box size $box_size at byte $offset"
  return 1
fi
if (( box_size > remaining )); then
  log "validate: heif box overruns EOF at byte $offset"
  return 1
fi
```

**Apply to:** The new guard in heif_container_validate will use the same `log` + `return 1` pattern.

---

### find + while read pattern for null-delimited processing

**Source:** `/Users/rohan/Projects/FTP-Camera-Dropbox/sort.sh`, lines 2070–2080 (reconcile)

```bash
while IFS= read -r -d '' f; do
  dispatch "$f"
done < <(find "$INCOMING" -type f -print0 2>/dev/null)
```

**Apply to:** The STUCK scan will replace the find operator but keep the same read pattern and loop variable `$f`.

---

### Log value safety pattern

**Source:** `/Users/rohan/Projects/FTP-Camera-Dropbox/sort.sh`, line 2079

```bash
log "STUCK >${STUCK_AGE_MIN}min: $(log_name "$f")"
```

**Apply to:** All log statements use `log_name "$f"` for file paths to prevent log injection.

---

### Config knob declaration pattern

**Source:** `/Users/rohan/Projects/FTP-Camera-Dropbox/sort.sh`, lines 32–36

```bash
RECONCILE_IDLE="${RECONCILE_IDLE:-300}"
STUCK_AGE_MIN="${STUCK_AGE_MIN:-60}"
STABLE_WAIT="${STABLE_WAIT:-60}"
STABLE_SKIP_AGE="${STABLE_SKIP_AGE:-3600}"  # skip the wait for files older than this (seconds)
```

**Apply to:** These knobs are already declared and do not change for this phase.

---

### Validator return contract

**Source:** `/Users/rohan/Projects/FTP-Camera-Dropbox/CONVENTIONS.md`, validator return contract

Validators return:
- **0** (accept) — file is valid
- **1** (quarantine) — file is invalid, move to quarantine
- **75** (source changed, retry later) — file is currently being written

**Apply to:** heif_container_validate stays compliant: all paths either return 0 or 1.

---

## No Analog Found

None. All modifications are to existing functions, and all test fixtures and helpers already exist in the codebase.

---

## Metadata

**Analog search scope:** 
- Full `/Users/rohan/Projects/FTP-Camera-Dropbox/sort.sh` (2100+ lines)
- Full `/Users/rohan/Projects/FTP-Camera-Dropbox/tests/parallel-sort.sh` (2600+ lines)
- `/Users/rohan/Projects/FTP-Camera-Dropbox/CONVENTIONS.md` and `/Users/rohan/Projects/FTP-Camera-Dropbox/.planning/codebase/TESTING.md` for harness idioms

**Files scanned:** 4

**Pattern extraction date:** 2026-09-01

---

*Phase: 02-sorter-correctness*
*Patterns extracted by gsd-pattern-mapper*
