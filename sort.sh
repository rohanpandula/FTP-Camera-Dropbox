#!/bin/bash
set -u

# Group-writable by default so files/dirs the sorter creates are deletable over
# SMB when the sorter and share clients use a common primary group.
umask 002

SORTER_UID=$EUID
SORTER_GID=$(id -g 2>/dev/null) || {
  echo "camera-sorter: cannot determine runtime primary GID" >&2
  exit 2
}
[[ "$SORTER_GID" =~ ^[0-9]+$ ]] || {
  echo "camera-sorter: invalid runtime primary GID '$SORTER_GID'" >&2
  exit 2
}

INCOMING="${INCOMING:-/data/incoming}"
SORTED="${SORTED:-/data/sorted}"
QUARANTINE="${QUARANTINE:-/data/quarantine}"
LOCK_ROOT="${LOCK_ROOT:-/var/lib/camera-sorter}"
NOTIFY_LOCK="${LOCK_ROOT}/notify.lock"
FLUSH_LOCK="${LOCK_ROOT}/flush.lock"
MOVE_LOCK="${LOCK_ROOT}/move.lock"
PROCESS_LOCK_DIR="${LOCK_ROOT}/process"
QUEUE_DIR="${LOCK_ROOT}/queues"
FLOCK_TEST_LOCK="${LOCK_ROOT}/flock-selftest.lock"
NOTIFY_QUEUE="${QUEUE_DIR}/notify-queue.tsv"
QUAR_QUEUE="${QUEUE_DIR}/quarantine-queue.tsv"
PERM_QUEUE="${QUEUE_DIR}/perm-queue.tsv"
TG_CONFIG="${TG_CONFIG:-/etc/telegram.json}"
RECONCILE_IDLE="${RECONCILE_IDLE:-300}"
WATCH_READY_TIMEOUT="${WATCH_READY_TIMEOUT:-30}"
STUCK_AGE_MIN="${STUCK_AGE_MIN:-60}"
STABLE_WAIT="${STABLE_WAIT:-60}"
STABLE_SKIP_AGE="${STABLE_SKIP_AGE:-3600}"  # skip the wait for files older than this (seconds)
DUPES_KEEP_DAYS="${DUPES_KEEP_DAYS:-7}"     # prune quarantine/_dupes entries older than this
SORT_WORKERS="${SORT_WORKERS:-4}"            # files processed concurrently
NOTIFY_INTERVAL="${NOTIFY_INTERVAL:-300}"   # 5 minutes
RAW_MIN_BYTES_DEFAULT="${RAW_MIN_BYTES_DEFAULT:-5000000}"
RAW_MIN_BYTES_NIKON_ZF="${RAW_MIN_BYTES_NIKON_ZF:-25000000}"
RAW_MIN_BYTES_SONY_A7CR="${RAW_MIN_BYTES_SONY_A7CR:-40000000}"
RAW_MIN_BYTES_GFX100="${RAW_MIN_BYTES_GFX100:-80000000}"
RAW_FULL_VALIDATE="${RAW_FULL_VALIDATE:-1}"
RAW_VALIDATE_TIMEOUT="${RAW_VALIDATE_TIMEOUT:-240}"
RAW_VALIDATE_TMPDIR="${RAW_VALIDATE_TMPDIR:-}"
RAW_VALIDATE_TMP_STALE_MIN="${RAW_VALIDATE_TMP_STALE_MIN:-15}"
NEF_LENS_MASSAGE="${NEF_LENS_MASSAGE:-0}"   # rewrite adapted-lens identity tags on sorted NEFs
NEF_QUEUE="${NEF_QUEUE:-}"                  # hard-link sorted NEFs here for the nef-watch renderer; empty disables
PANEL_CONFIG="${PANEL_CONFIG:-/data/.panel/config.json}"  # optional control-panel config; absent = current behavior

log_value() {
  local value=$1
  # Bash's reusable representation keeps every control character visible but
  # inert (for example newline becomes \n and ESC becomes \E). Limit only the
  # diagnostic copy; the original pathname remains untouched for file I/O.
  printf '%q' "${value:0:512}"
}

log_name() {
  local name=${1##*/}
  log_value "$name"
}

log() {
  local message=$*
  # Defense in depth for diagnostics not yet carrying a log_value field. No
  # log call may be able to inject a second record or terminal control.
  message=${message//$'\n'/\\n}
  message=${message//$'\r'/\\r}
  message=${message//$'\033'/\\E}
  message=$(printf '%s' "$message" | tr -d '\000-\010\013\014\016-\037\177')
  printf '[%s] %s\n' "$(date '+%F %T')" "$message" >&2
}

# Configured storage paths are security boundaries. Strip only redundant
# trailing slashes, then require an absolute, lexically-normal path. In
# particular, preserving a trailing slash makes Bash dereference a final
# symlink before `-L` can inspect it.
normalize_config_path() {
  local value=$1 label=$2
  while [[ "$value" != "/" && "$value" == */ ]]; do
    value=${value%/}
  done
  if [[ -z "$value" || "$value" != /* || "$value" == "/" ]]; then
    log "invalid $label path '$value' (expected an absolute path)"
    return 1
  fi
  case "/${value#/}/" in
    *'//'*) log "invalid $label path '$value' (duplicate slash)"; return 1 ;;
    *'/./'*|*'/../'*) log "invalid $label path '$value' (dot segment)"; return 1 ;;
  esac
  printf '%s\n' "$value"
}

INCOMING=$(normalize_config_path "$INCOMING" INCOMING) || exit 2
SORTED=$(normalize_config_path "$SORTED" SORTED) || exit 2
QUARANTINE=$(normalize_config_path "$QUARANTINE" QUARANTINE) || exit 2
LOCK_ROOT=$(normalize_config_path "$LOCK_ROOT" LOCK_ROOT) || exit 2
[[ -n "$RAW_VALIDATE_TMPDIR" ]] || RAW_VALIDATE_TMPDIR="${LOCK_ROOT}/raw-validate-tmp"
RAW_VALIDATE_TMPDIR=$(normalize_config_path "$RAW_VALIDATE_TMPDIR" RAW_VALIDATE_TMPDIR) || exit 2
case "$RAW_VALIDATE_TMPDIR" in
  "$LOCK_ROOT"/*) ;;
  *)
    log "invalid RAW_VALIDATE_TMPDIR='$RAW_VALIDATE_TMPDIR' (must be a strict descendant of LOCK_ROOT)"
    exit 2
    ;;
esac

# Derive child paths only after normalization, so no trailing slash can change
# the meaning of a later lstat-style check.
NOTIFY_LOCK="${LOCK_ROOT}/notify.lock"
FLUSH_LOCK="${LOCK_ROOT}/flush.lock"
MOVE_LOCK="${LOCK_ROOT}/move.lock"
PROCESS_LOCK_DIR="${LOCK_ROOT}/process"
QUEUE_DIR="${LOCK_ROOT}/queues"
FLOCK_TEST_LOCK="${LOCK_ROOT}/flock-selftest.lock"
NOTIFY_QUEUE="${QUEUE_DIR}/notify-queue.tsv"
QUAR_QUEUE="${QUEUE_DIR}/quarantine-queue.tsv"
PERM_QUEUE="${QUEUE_DIR}/perm-queue.tsv"
LEGACY_NOTIFY_QUEUE="${INCOMING%/*}/.notify-queue.tsv"
LEGACY_QUAR_QUEUE="${INCOMING%/*}/.quarantine-queue.tsv"
LEGACY_PERM_QUEUE="${INCOMING%/*}/.perm-queue.tsv"

for numeric_name in \
  SORT_WORKERS RECONCILE_IDLE WATCH_READY_TIMEOUT STUCK_AGE_MIN \
  STABLE_WAIT STABLE_SKIP_AGE NOTIFY_INTERVAL DUPES_KEEP_DAYS \
  RAW_MIN_BYTES_DEFAULT RAW_MIN_BYTES_NIKON_ZF RAW_MIN_BYTES_SONY_A7CR \
  RAW_MIN_BYTES_GFX100 RAW_VALIDATE_TIMEOUT RAW_VALIDATE_TMP_STALE_MIN; do
  numeric_value=${!numeric_name}
  if ! [[ "$numeric_value" =~ ^[1-9][0-9]*$ ]] \
    || (( ${#numeric_value} > 10 )) \
    || (( 10#$numeric_value > 2147483647 )); then
    log "invalid $numeric_name='$numeric_value' (expected a positive 32-bit integer)"
    exit 2
  fi
  if [[ "$numeric_name" == SORT_WORKERS ]] && (( 10#$numeric_value > 256 )); then
    log "invalid SORT_WORKERS='$numeric_value' (maximum is 256)"
    exit 2
  fi
done
unset numeric_name numeric_value

if (( 10#$RAW_VALIDATE_TMP_STALE_MIN * 60 <= 10#$RAW_VALIDATE_TIMEOUT + 2 )); then
  log "invalid RAW_VALIDATE_TMP_STALE_MIN='$RAW_VALIDATE_TMP_STALE_MIN' (must outlive RAW_VALIDATE_TIMEOUT='$RAW_VALIDATE_TIMEOUT' by more than 2 seconds)"
  exit 2
fi

case "${RAW_FULL_VALIDATE,,}" in
  1|true|yes|on|0|false|no|off) ;;
  *)
    log "invalid RAW_FULL_VALIDATE='$RAW_FULL_VALIDATE' (expected true or false)"
    exit 2
    ;;
esac

INCOMING_REAL=""
SORTED_REAL=""
QUARANTINE_REAL=""
SORTED_ID=""
QUARANTINE_ID=""
LOCK_ROOT_REAL=""
LOCK_ROOT_ID=""
SAFE_OUTPUT_DIR=""

paths_overlap() {
  local first=${1%/} second=${2%/}
  [[ "$first" == "$second" || "$first" == "$second/"* || "$second" == "$first/"* ]]
}

path_has_symlink_component() {
  local path=$1 lexical resolved
  lexical=$(realpath -ms -- "$path" 2>/dev/null) || return 0
  resolved=$(realpath -m -- "$path" 2>/dev/null) || return 0
  [[ "$lexical" != "$path" || "$resolved" != "$lexical" ]]
}

path_identity() {
  stat -c '%d:%i' -- "$1" 2>/dev/null
}

# An open file descriptor is exposed by procfs as a final symlink. GNU stat
# intentionally lstats that link unless -L is explicit; validation needs the
# identity and metadata of the already-open camera inode behind it.
path_target_identity() {
  stat -Lc '%d:%i' -- "$1" 2>/dev/null
}

ensure_directory_path() {
  local dir=$1 label=$2 creation_class=${3:-shared} current="" resolved segment
  local mkdir_rc
  local -a segments=()
  local IFS=/
  read -r -a segments <<< "${dir#/}"
  for segment in "${segments[@]}"; do
    [[ -n "$segment" ]] || {
      log "unsafe empty component in $label directory: $dir"
      return 1
    }
    current="$current/$segment"
    if [[ -L "$current" || ( -e "$current" && ! -d "$current" ) ]]; then
      log "unsafe $label directory component: $current"
      return 1
    fi
    if [[ ! -e "$current" ]]; then
      mkdir_rc=0
      if [[ "$creation_class" == private ]]; then
        (umask 077; mkdir -- "$current") 2>/dev/null || mkdir_rc=$?
      else
        mkdir -- "$current" 2>/dev/null || mkdir_rc=$?
      fi
      if (( mkdir_rc != 0 )) && [[ -L "$current" || ! -d "$current" ]]; then
        # Another sorter may have won the mkdir race. Accept only the exact
        # safe directory we would have accepted on the next loop iteration.
        log "cannot create $label directory component: $current"
        return 1
      fi
    fi
    if [[ -L "$current" || ! -d "$current" ]]; then
      log "unsafe $label directory component after creation: $current"
      return 1
    fi
    resolved=$(realpath -e -- "$current" 2>/dev/null) || return 1
    if [[ "$resolved" != "$current" ]]; then
      log "symlinked $label directory component: $current"
      return 1
    fi
  done
}

prepare_data_directory() {
  local dir=$1 label=$2
  ensure_directory_path "$dir" "$label" || return 1
  if path_has_symlink_component "$dir" || [[ -L "$dir" || ! -d "$dir" ]]; then
    log "unsafe $label directory after creation: $dir"
    return 1
  fi
}

prepare_data_roots() {
  local incoming_dev sorted_dev quarantine_dev
  prepare_data_directory "$INCOMING" incoming || return 1
  prepare_data_directory "$SORTED" sorted || return 1
  prepare_data_directory "$QUARANTINE" quarantine || return 1

  INCOMING_REAL=$(realpath -e -- "$INCOMING") || return 1
  SORTED_REAL=$(realpath -e -- "$SORTED") || return 1
  QUARANTINE_REAL=$(realpath -e -- "$QUARANTINE") || return 1
  SORTED_ID=$(path_identity "$SORTED_REAL") || return 1
  QUARANTINE_ID=$(path_identity "$QUARANTINE_REAL") || return 1
  if paths_overlap "$INCOMING_REAL" "$SORTED_REAL" \
    || paths_overlap "$INCOMING_REAL" "$QUARANTINE_REAL" \
    || paths_overlap "$SORTED_REAL" "$QUARANTINE_REAL"; then
    log "incoming, sorted, and quarantine must be distinct non-overlapping directories"
    return 1
  fi

  # Atomic no-clobber renames preserve the source inode only on one filesystem.
  # The standard layout keeps all three roots on the shared /data volume.
  incoming_dev=$(stat -c %d -- "$INCOMING_REAL") || return 1
  sorted_dev=$(stat -c %d -- "$SORTED_REAL") || return 1
  quarantine_dev=$(stat -c %d -- "$QUARANTINE_REAL") || return 1
  if [[ "$incoming_dev" != "$sorted_dev" ]] \
    || [[ "$incoming_dev" != "$quarantine_dev" ]]; then
    log "incoming, sorted, and quarantine must share one filesystem"
    return 1
  fi
}

prepare_output_subdir() {
  local root=$1 relative=$2 root_real root_id current next resolved segment
  local -a segments=()
  case "$root" in
    "$SORTED") root_real=$SORTED_REAL; root_id=$SORTED_ID ;;
    "$QUARANTINE") root_real=$QUARANTINE_REAL; root_id=$QUARANTINE_ID ;;
    *) log "unsafe output root: $root"; return 1 ;;
  esac
  if [[ -L "$root" || ! -d "$root" ]]; then
    log "unsafe output root: $root"
    return 1
  fi
  resolved=$(realpath -e -- "$root" 2>/dev/null) || return 1
  if [[ "$resolved" != "$root_real" ]]; then
    log "output root changed after startup: $root"
    return 1
  fi
  if [[ "$(path_identity "$root")" != "$root_id" ]]; then
    log "output root inode changed after startup: $root"
    return 1
  fi

  local IFS=/
  read -r -a segments <<< "$relative"
  current=$root_real
  for segment in "${segments[@]}"; do
    if [[ -z "$segment" || "$segment" == "." || "$segment" == ".." ]]; then
      log "unsafe output path segment: $relative"
      return 1
    fi
    next="$current/$segment"
    if [[ -L "$next" || ( -e "$next" && ! -d "$next" ) ]]; then
      log "unsafe output directory: $next"
      return 1
    fi
    if [[ ! -d "$next" ]] && ! mkdir -- "$next"; then
      if [[ -L "$next" || ! -d "$next" ]]; then
        log "cannot safely create output directory: $next"
        return 1
      fi
    fi
    if [[ -L "$next" || ! -d "$next" ]]; then
      log "unsafe output directory after creation: $next"
      return 1
    fi
    resolved=$(realpath -e -- "$next" 2>/dev/null) || return 1
    case "$resolved" in
      "$root_real"/*) ;;
      *) log "output directory escaped its root: $next"; return 1 ;;
    esac
    current=$resolved
  done
  SAFE_OUTPUT_DIR=$current
}

cwd_matches_output_path() {
  local root=$1 expected_dir=$2 root_real root_id cwd_real expected_real
  case "$root" in
    "$SORTED") root_real=$SORTED_REAL; root_id=$SORTED_ID ;;
    "$QUARANTINE") root_real=$QUARANTINE_REAL; root_id=$QUARANTINE_ID ;;
    *) return 1 ;;
  esac
  [[ "$(path_identity "$root")" == "$root_id" ]] || return 1
  path_has_symlink_component "$expected_dir" && return 1
  cwd_real=$(realpath -e -- "/proc/$BASHPID/cwd" 2>/dev/null) || return 1
  expected_real=$(realpath -e -- "$expected_dir" 2>/dev/null) || return 1
  [[ "$cwd_real" == "$expected_real" ]] || return 1
  case "$cwd_real" in
    "$root_real"/*) return 0 ;;
    *) return 1 ;;
  esac
}

pinned_source_parent_is_canonical() {
  local pinned_parent=$1 expected_parent=$2 pinned_real expected_real
  [[ -d "$expected_parent" && ! -L "$expected_parent" ]] || return 1
  path_has_symlink_component "$expected_parent" && return 1
  pinned_real=$(realpath -e -- "$pinned_parent" 2>/dev/null) || return 1
  expected_real=$(realpath -e -- "$expected_parent" 2>/dev/null) || return 1
  [[ "$pinned_real" == "$expected_real" ]] || return 1
  case "$pinned_real" in
    "$INCOMING_REAL"|"$INCOMING_REAL"/*) return 0 ;;
    *) return 1 ;;
  esac
}

pinned_source_parent_is_within_incoming() {
  local pinned_parent=$1 pinned_real
  pinned_real=$(realpath -e -- "$pinned_parent" 2>/dev/null) || return 1
  case "$pinned_real" in
    "$INCOMING_REAL"|"$INCOMING_REAL"/*) return 0 ;;
    *) return 1 ;;
  esac
}

ROLLBACK_RC=0
rollback_to_pinned_source() {
  local destination=$1 source=$2 expected_id=$3 pinned_parent=$4
  local returned_id="" destination_id=""
  ROLLBACK_RC=0

  if [[ -e "$destination" || -L "$destination" ]]; then
    destination_id=$(stat -c '%d:%i' -- "$destination" 2>/dev/null || true)
  fi
  [[ "$destination_id" == "$expected_id" ]] || return 1

  # If the original directory inode was itself moved outside incoming, putting
  # the camera inode back through its fd would hide the only sorter-controlled
  # copy outside both trees. Retain it in the pinned destination instead.
  pinned_source_parent_is_within_incoming "$pinned_parent" || return 3

  # No-clobber is essential here: an uploader may have already recreated the
  # source leaf. In that case the moved inode remains in the pinned output
  # directory for manual recovery rather than overwriting the new upload.
  if [[ -e "$source" || -L "$source" ]]; then
    return 2
  fi
  mv -n -T -- "$destination" "$source" || ROLLBACK_RC=$?

  if [[ -e "$source" || -L "$source" ]]; then
    returned_id=$(stat -c '%d:%i' -- "$source" 2>/dev/null || true)
  fi
  if [[ -e "$destination" || -L "$destination" ]]; then
    destination_id=$(stat -c '%d:%i' -- "$destination" 2>/dev/null || true)
  fi
  if [[ "$returned_id" == "$expected_id" \
    && ! -e "$destination" && ! -L "$destination" ]]; then
    if pinned_source_parent_is_within_incoming "$pinned_parent"; then
      return 0
    fi

    # The parent can cross the incoming boundary after the precheck but during
    # mv. Reverse that exact inode back into the still-pinned destination and
    # verify both sides before reporting it retained there.
    ROLLBACK_RC=0
    mv -n -T -- "$source" "$destination" || ROLLBACK_RC=$?
    returned_id=""
    destination_id=""
    if [[ -e "$source" || -L "$source" ]]; then
      returned_id=$(stat -c '%d:%i' -- "$source" 2>/dev/null || true)
    fi
    if [[ -e "$destination" || -L "$destination" ]]; then
      destination_id=$(stat -c '%d:%i' -- "$destination" 2>/dev/null || true)
    fi
    if [[ "$destination_id" == "$expected_id" \
      && ! -e "$source" && ! -L "$source" ]]; then
      return 3
    fi
    return 4
  fi
  if [[ ( -e "$source" || -L "$source" ) \
    && "$destination_id" == "$expected_id" ]]; then
    return 2
  fi
  return 1
}

prepare_lock_directory() {
  local dir=$1 label=${2:-lock} owner mode
  ensure_directory_path "$dir" "$label" private || return 1
  # LOCK_ROOT is a private shared control mount, separate from the SMB-exported
  # camera data. Mode 0700 protects lock and queue names from share clients.
  if path_has_symlink_component "$dir" || [[ -L "$dir" || ! -d "$dir" ]]; then
    log "unsafe $label directory after creation: $dir"
    return 1
  fi
  owner=$(stat -c %u -- "$dir" 2>/dev/null) || return 1
  mode=$(stat -c %a -- "$dir" 2>/dev/null) || return 1
  if [[ "$owner" != "$EUID" || "$mode" != 700 ]]; then
    log "unsafe $label directory ownership/mode: $dir (uid=$owner mode=$mode)"
    return 1
  fi
}

prepare_lock_file() {
  local path=$1 links owner mode
  if [[ -n "$LOCK_ROOT_ID" \
    && ( "$(path_identity "$LOCK_ROOT")" != "$LOCK_ROOT_ID" \
      || -L "$LOCK_ROOT" ) ]]; then
    log "shared lock root changed after startup: $LOCK_ROOT"
    return 1
  fi
  if [[ -L "$path" || ( -e "$path" && ! -f "$path" ) ]]; then
    log "unsafe lock file: $path"
    return 1
  fi
  # Create with the final permissions in one atomic O_EXCL operation. This
  # avoids a 0664 -> 0600 window in which a concurrently-starting sorter would
  # reject a legitimate new lock file.
  if [[ ! -e "$path" ]]; then
    if (umask 077; set -o noclobber; : > "$path") 2>/dev/null; then
      :
    elif [[ -L "$path" || ! -f "$path" ]]; then
      log "cannot create lock file: $path"
      return 1
    fi
  fi
  if [[ -L "$path" || ! -f "$path" ]]; then
    log "unsafe lock file after creation: $path"
    return 1
  fi
  links=$(stat -c %h -- "$path" 2>/dev/null) || {
    log "cannot inspect lock file: $path"
    return 1
  }
  if ! [[ "$links" =~ ^[0-9]+$ ]] || (( links != 1 )); then
    log "unsafe hard-linked lock file: $path"
    return 1
  fi
  owner=$(stat -c %u -- "$path" 2>/dev/null) || return 1
  mode=$(stat -c %a -- "$path" 2>/dev/null) || return 1
  if [[ "$owner" != "$EUID" || "$mode" != 600 ]]; then
    log "unsafe lock file ownership/mode: $path (uid=$owner mode=$mode)"
    return 1
  fi
}

prepare_lock_storage() {
  prepare_lock_directory "$LOCK_ROOT" || return 1
  LOCK_ROOT_REAL=$(realpath -e -- "$LOCK_ROOT") || return 1
  LOCK_ROOT_ID=$(path_identity "$LOCK_ROOT_REAL") || return 1
  if paths_overlap "$LOCK_ROOT_REAL" "$INCOMING_REAL" \
    || paths_overlap "$LOCK_ROOT_REAL" "$SORTED_REAL" \
    || paths_overlap "$LOCK_ROOT_REAL" "$QUARANTINE_REAL"; then
    log "lock root must be shared but outside incoming, sorted, and quarantine"
    return 1
  fi
  prepare_lock_directory "$PROCESS_LOCK_DIR" || return 1
  prepare_lock_directory "$QUEUE_DIR" queue || return 1
  prepare_lock_directory "$RAW_VALIDATE_TMPDIR" raw-validation-temp || return 1
  local raw_tmp_real
  raw_tmp_real=$(realpath -e -- "$RAW_VALIDATE_TMPDIR") || return 1
  case "$raw_tmp_real" in
    "$LOCK_ROOT_REAL"/*) ;;
    *) log "raw validation temp directory escaped LOCK_ROOT: $RAW_VALIDATE_TMPDIR"; return 1 ;;
  esac
  prepare_lock_file "$FLOCK_TEST_LOCK" || return 1
  prepare_lock_file "$MOVE_LOCK" || return 1
  prepare_lock_file "$NOTIFY_LOCK" || return 1
  prepare_lock_file "$FLUSH_LOCK" || return 1
}

prepare_state_file() {
  local path=$1 links owner mode
  if [[ -L "$path" || ( -e "$path" && ! -f "$path" ) ]]; then
    log "unsafe state file: $path"
    return 1
  fi
  if [[ ! -e "$path" ]]; then
    if (umask 077; set -o noclobber; : > "$path") 2>/dev/null; then
      :
    elif [[ -L "$path" || ! -f "$path" ]]; then
      log "cannot create state file: $path"
      return 1
    fi
  fi
  if [[ -L "$path" || ! -f "$path" ]]; then
    log "unsafe state file after creation: $path"
    return 1
  fi
  links=$(stat -c %h -- "$path" 2>/dev/null) || return 1
  if ! [[ "$links" =~ ^[0-9]+$ ]] || (( links != 1 )); then
    log "unsafe hard-linked state file: $path"
    return 1
  fi
  owner=$(stat -c %u -- "$path" 2>/dev/null) || return 1
  mode=$(stat -c %a -- "$path" 2>/dev/null) || return 1
  if [[ "$owner" != "$EUID" || "$mode" != 600 ]]; then
    log "unsafe state file ownership/mode: $path (uid=$owner mode=$mode)"
    return 1
  fi
}

reject_unsafe_legacy_queue_nodes() {
  local base path links
  local -a candidates=()
  for base in "$LEGACY_NOTIFY_QUEUE" "$LEGACY_QUAR_QUEUE" "$LEGACY_PERM_QUEUE"; do
    # Older sorters rotated the base queue beside the data tree. A crash could
    # leave either an in-flight `.flush.*` or failed-send `.failed.*` artifact;
    # treating only the base name as legacy would silently strand those rows.
    candidates=("$base" "$base".flush.* "$base".failed.*)
    for path in "${candidates[@]}"; do
      [[ -e "$path" || -L "$path" ]] || continue
      if [[ -L "$path" || ! -f "$path" ]]; then
        log "unsafe legacy queue file: $path"
        return 1
      fi
      links=$(stat -c %h -- "$path" 2>/dev/null) || return 1
      if ! [[ "$links" =~ ^[0-9]+$ ]] || (( links != 1 )); then
        log "unsafe hard-linked legacy queue file: $path"
        return 1
      fi
      if [[ -s "$path" ]]; then
        log "pending legacy queue requires migration with the older sorter stopped: $path"
        return 1
      fi
    done
  done
}

prepare_state_storage() {
  # Queue state shares the private control mount with the locks. This keeps it
  # persistent across container replacement and common to every sorter while
  # remaining outside the SMB-writable camera tree.
  reject_unsafe_legacy_queue_nodes || return 1
  prepare_state_file "$NOTIFY_QUEUE" || return 1
  prepare_state_file "$QUAR_QUEUE" || return 1
  prepare_state_file "$PERM_QUEUE" || return 1
}

recover_queue_snapshots() {
  {
    flock -x 202 || { log "cannot lock notification flush lifecycle"; return 1; }
    local kind queue snapshot
    local -a snapshots=()
    for kind in notify quarantine permission; do
      case "$kind" in
        notify) queue=$NOTIFY_QUEUE ;;
        quarantine) queue=$QUAR_QUEUE ;;
        permission) queue=$PERM_QUEUE ;;
      esac
      snapshots=("$QUEUE_DIR/.${kind}.pending."*)
      for snapshot in "${snapshots[@]}"; do
        [[ -e "$snapshot" || -L "$snapshot" ]] || continue
        prepare_state_file "$snapshot" || return 1
        {
          flock -x 200 || return 1
          cat -- "$snapshot" >> "$queue" || return 1
          rm -- "$snapshot" || return 1
        } 200>>"$NOTIFY_LOCK"
        log "recovered interrupted $kind notification batch"
      done
    done
  } 202>>"$FLUSH_LOCK"
}

verify_flock_exclusion() {
  local lock_fd
  exec {lock_fd}>>"$FLOCK_TEST_LOCK" || {
    log "filesystem lock self-test cannot open $FLOCK_TEST_LOCK"
    return 1
  }
  if ! flock -w 2 -x "$lock_fd"; then
    exec {lock_fd}>&-
    log "filesystem lock self-test cannot acquire $FLOCK_TEST_LOCK"
    return 1
  fi
  # This probe opens the same path independently. It must be rejected while the
  # parent fd holds the lock; otherwise destination overwrite protection is not
  # enforceable on this backing filesystem.
  if (flock -n 203) 203>>"$FLOCK_TEST_LOCK"; then
    exec {lock_fd}>&-
    log "filesystem does not enforce flock exclusion for $FLOCK_TEST_LOCK"
    return 1
  fi
  exec {lock_fd}>&-
  return 0
}

# --- Telegram credentials (loaded from mounted JSON, never echoed) ---
TG_TOKEN=""
TG_CHAT_ID=""
TELEGRAM_ENABLED=0
if [[ -f "$TG_CONFIG" ]]; then
  TG_TOKEN=$(jq -er '.bot_token | select(type == "string" and length > 0)' \
    "$TG_CONFIG" 2>/dev/null || true)
  TG_CHAT_ID=$(jq -er \
    '.chat_id | if type == "number" then tostring elif type == "string" and length > 0 then . else empty end' \
    "$TG_CONFIG" 2>/dev/null || true)
  if [[ -n "$TG_TOKEN" && -n "$TG_CHAT_ID" ]]; then
    TELEGRAM_ENABLED=1
  fi
fi

telegram_send() {
  local text=$1
  (( TELEGRAM_ENABLED )) || { log "telegram: no credentials, skipping"; return 1; }
  # Panel kill switch. Returning success keeps queue-flush logic draining
  # normally — messages are dropped, not retried forever.
  panel_flag telegram_notifications || return 0
  local resp http_code
  resp=$(curl -sS -m 15 -w '\n%{http_code}' -X POST "https://api.telegram.org/bot${TG_TOKEN}/sendMessage" \
    --data-urlencode "chat_id=${TG_CHAT_ID}" \
    --data-urlencode "text=${text}" 2>&1)
  http_code=$(echo "$resp" | tail -n1)
  if [[ "$http_code" == "200" ]]; then
    return 0
  else
    log "telegram send failed (http $http_code): $(echo "$resp" | head -n1 | cut -c1-200)"
    return 1
  fi
}

# --- File handling helpers ---
get_type() {
  case "${1,,}" in
    raf|arw|nef|cr2|cr3|dng|orf|rw2|pef|srw) echo raw ;;
    jpg|jpeg)                                 echo jpg ;;
    heic|heif|hif)                            echo heif ;;
    mp4|mov|m4v|mts|m2ts|avi|mkv)             echo video ;;
    *)                                        echo other ;;
  esac
}

# Strip control chars (tab/newline/CR/NUL/etc.) and cap length. EXIF strings and
# filenames are attacker-influenceable and flow into the TSV notify queue and
# Telegram messages — a stray tab/newline could forge rows or corrupt logs.
sanitize() {
  printf '%s' "$1" | tr -d '\000-\037\177' | cut -c1-100
}

exiftool_read() {
  timeout -k 2 "$RAW_VALIDATE_TIMEOUT" exiftool "$@" 2>/dev/null
}

camera_model() {
  local output rc
  output=$(exiftool_read -Model -s3 "$1")
  rc=$?
  if (( rc == 124 || rc == 137 )); then
    log "validate: raw camera model lookup timed out after ${RAW_VALIDATE_TIMEOUT}s"
    return 124
  fi
  (( rc == 0 )) || return "$rc"
  output=${output%%$'\n'*}
  sanitize "$output"
}

raw_min_bytes_for() {
  local model=$1 ext=${2,,}
  case "$model:$ext" in
    "NIKON Z f:nef") echo "$RAW_MIN_BYTES_NIKON_ZF" ;;
    "ILCE-7CR:arw") echo "$RAW_MIN_BYTES_SONY_A7CR" ;;
    "GFX100 II:raf"|"GFX100RF:raf") echo "$RAW_MIN_BYTES_GFX100" ;;
    *) echo "$RAW_MIN_BYTES_DEFAULT" ;;
  esac
}

truthy() {
  case "${1,,}" in
    1|true|yes|on) return 0 ;;
    *) return 1 ;;
  esac
}

raw_payload_validate() {
  local f=$1 ext=${2,,} tmp link output rc detail start_size end_size

  truthy "$RAW_FULL_VALIDATE" || return 0

  command -v raw-identify >/dev/null 2>&1 || {
    log "validate: raw-identify missing while RAW_FULL_VALIDATE=${RAW_FULL_VALIDATE}"
    return 1
  }
  command -v simple_dcraw >/dev/null 2>&1 || {
    log "validate: simple_dcraw missing while RAW_FULL_VALIDATE=${RAW_FULL_VALIDATE}"
    return 1
  }

  start_size=$(stat -Lc %s "$f" 2>/dev/null) || {
    log "validate: raw disappeared before decode"
    return 75
  }

  output=$(timeout -k 2 "$RAW_VALIDATE_TIMEOUT" raw-identify "$f" 2>&1)
  rc=$?
  if (( rc != 0 )); then
    detail=$(sanitize "$output")
    [[ -n "$detail" ]] || detail="exit $rc"
    if (( rc == 124 || rc == 137 )); then
      log "validate: raw-identify timed out after ${RAW_VALIDATE_TIMEOUT}s"
    else
      log "validate: raw-identify failed ($detail)"
    fi
    return 1
  fi

  mkdir -p "$RAW_VALIDATE_TMPDIR" || {
    log "validate: cannot create raw validation temp dir"
    return 1
  }
  tmp=$(mktemp -d "${RAW_VALIDATE_TMPDIR%/}/raw.XXXXXX") || {
    log "validate: cannot allocate raw validation temp dir"
    return 1
  }

  # simple_dcraw writes a large PPM next to the input. Use a symlink in a temp
  # directory on the private control mount so validation output never lands in
  # incoming or Docker overlay.
  link="$tmp/input.${ext}"
  if ! ln -s "$f" "$link"; then
    rm -rf "$tmp"
    log "validate: cannot stage raw validation input"
    return 1
  fi

  output=$(cd "$tmp" && timeout -k 2 "$RAW_VALIDATE_TIMEOUT" simple_dcraw -D -4 "$(basename "$link")" 2>&1)
  rc=$?
  rm -rf "$tmp"

  end_size=$(stat -Lc %s "$f" 2>/dev/null) || {
    log "validate: raw disappeared during decode"
    return 75
  }
  if [[ "$start_size" != "$end_size" ]]; then
    log "validate: raw changed during decode ($start_size B -> $end_size B)"
    return 75
  fi

  if (( rc != 0 )); then
    detail=$(sanitize "$output")
    [[ -n "$detail" ]] || detail="exit $rc"
    if (( rc == 124 || rc == 137 )); then
      log "validate: raw decode timed out after ${RAW_VALIDATE_TIMEOUT}s"
    else
      log "validate: raw decode failed ($detail)"
    fi
    return 1
  fi

  return 0
}

raw_container_validate() {
  local f=$1 output rc severe

  output=$(timeout -k 2 "$RAW_VALIDATE_TIMEOUT" exiftool -validate -warning -error -a "$f" 2>&1)
  rc=$?
  if (( rc == 124 || rc == 137 )); then
    log "validate: raw container check timed out after ${RAW_VALIDATE_TIMEOUT}s"
    return 1
  fi

  severe=$(printf '%s\n' "$output" \
    | grep -Ei 'runs past end of file|unexpected end of file|truncated|file format error|corrupt|error reading|bad offset|invalid offset' \
    | head -n1 || true)
  if [[ -n "$severe" ]]; then
    log "validate: raw container failed ($(sanitize "$severe"))"
    return 1
  fi

  if (( rc != 0 )); then
    log "validate: raw container check failed ($(sanitize "$output"))"
    return 1
  fi

  return 0
}

read_hex_word() {
  local f=$1 offset=$2 hex
  hex=$(dd if="$f" bs=1 skip="$offset" count=4 2>/dev/null \
    | od -An -tx1 | tr -d ' \n')
  [[ "$hex" =~ ^[0-9a-fA-F]{8}$ ]] || return 1
  printf '%s\n' "${hex,,}"
}

read_be_u32() {
  local hex
  hex=$(read_hex_word "$1" "$2") || return 1
  printf '%u\n' "$((16#$hex))"
}

is_heif_brand() {
  case "$1" in
    68656963|68656978|6865696d|68656973|\
    68657663|68657678|6865766d|68657673|\
    6d696631|6d736631) return 0 ;;
    *) return 1 ;;
  esac
}

heif_container_validate() {
  local f=$1 ext=${2,,} file_size offset=0 remaining size32 type_hex
  local header_size box_size size_high size_low max_high max_low
  local box_count=0 ftyp_seen=0 meta_seen=0 brand_hex brand_offset brand_end

  case "$ext" in
    heic|heif|hif) ;;
    *) log "validate: unsupported heif extension ($ext)"; return 1 ;;
  esac
  file_size=$(stat -Lc %s "$f" 2>/dev/null) || {
    log "validate: heif stat failed"
    return 1
  }
  (( file_size > 50000 )) || {
    log "validate: heif too small ($file_size B)"
    return 1
  }

  # Walk every top-level ISO-BMFF box to EOF. Checking only the leading ftyp
  # brand accepts cut-off camera uploads whose final mdat/meta box overruns the
  # bytes actually received. Extended-size boxes are range-checked before any
  # 64-bit arithmetic so a hostile header cannot wrap Bash's signed integer.
  while (( offset < file_size )); do
    (( box_count < 4096 )) || {
      log "validate: heif has too many top-level boxes"
      return 1
    }
    remaining=$((file_size - offset))
    (( remaining >= 8 )) || {
      log "validate: heif truncated box header at byte $offset"
      return 1
    }
    size32=$(read_be_u32 "$f" "$offset") || {
      log "validate: heif unreadable box size at byte $offset"
      return 1
    }
    type_hex=$(read_hex_word "$f" "$((offset + 4))") || {
      log "validate: heif unreadable box type at byte $offset"
      return 1
    }
    header_size=8
    case "$size32" in
      0)
        box_size=$remaining
        ;;
      1)
        (( remaining >= 16 )) || {
          log "validate: heif truncated extended box header at byte $offset"
          return 1
        }
        size_high=$(read_be_u32 "$f" "$((offset + 8))") || return 1
        size_low=$(read_be_u32 "$f" "$((offset + 12))") || return 1
        max_high=$((remaining / 4294967296))
        max_low=$((remaining % 4294967296))
        if (( size_high > max_high \
          || (size_high == max_high && size_low > max_low) )); then
          log "validate: heif box overruns EOF at byte $offset"
          return 1
        fi
        box_size=$((size_high * 4294967296 + size_low))
        header_size=16
        ;;
      *)
        box_size=$size32
        ;;
    esac
    if (( box_size < header_size )); then
      log "validate: heif invalid box size $box_size at byte $offset"
      return 1
    fi
    if (( box_size > remaining )); then
      log "validate: heif box overruns EOF at byte $offset"
      return 1
    fi
    if (( box_count == 0 )) && [[ "$type_hex" != 66747970 ]]; then
      log "validate: heif first box is not ftyp"
      return 1
    fi

    case "$type_hex" in
      66747970)
        (( ftyp_seen == 0 )) || {
          log "validate: heif has duplicate ftyp boxes"
          return 1
        }
        (( box_size >= header_size + 8 \
          && (box_size - header_size - 8) % 4 == 0 )) || {
          log "validate: heif malformed ftyp box"
          return 1
        }
        brand_offset=$((offset + header_size))
        brand_end=$((offset + box_size))
        brand_hex=$(read_hex_word "$f" "$brand_offset") || return 1
        is_heif_brand "$brand_hex" && ftyp_seen=1
        brand_offset=$((brand_offset + 8))
        while (( brand_offset < brand_end )); do
          brand_hex=$(read_hex_word "$f" "$brand_offset") || return 1
          is_heif_brand "$brand_hex" && ftyp_seen=1
          brand_offset=$((brand_offset + 4))
        done
        (( ftyp_seen == 1 )) || {
          log "validate: ftyp has no HEIF-compatible brand"
          return 1
        }
        ;;
      6d657461)
        (( box_size >= header_size + 4 )) || {
          log "validate: heif malformed meta box"
          return 1
        }
        meta_seen=1
        ;;
    esac
    offset=$((offset + box_size))
    box_count=$((box_count + 1))
  done

  (( ftyp_seen == 1 )) || { log "validate: heif missing ftyp box"; return 1; }
  (( meta_seen == 1 )) || { log "validate: heif missing meta box"; return 1; }
  return 0
}

get_date() {
  local f=$1 d rc
  d=$(exiftool_read -d '%Y-%m-%d' -DateTimeOriginal -CreateDate -ModifyDate -s3 "$f")
  rc=$?
  if (( rc == 124 || rc == 137 )); then
    log "exif date lookup timed out after ${RAW_VALIDATE_TIMEOUT}s — using mtime"
    d=""
  elif (( rc != 0 )); then
    d=""
  else
    d=${d%%$'\n'*}
  fi
  # Accept ONLY a strict YYYY-MM-DD with plausible components, else fall back to
  # mtime. Prevents a malformed/attacker EXIF date (e.g. "2024-13-99" or text with
  # a leading year) from becoming a bogus path component.
  if [[ "$d" =~ ^([0-9]{4})-([0-9]{2})-([0-9]{2})$ ]]; then
    local y=${BASH_REMATCH[1]} mo=${BASH_REMATCH[2]} da=${BASH_REMATCH[3]}
    if (( y >= 1990 && y <= 2100 && 10#$mo >= 1 && 10#$mo <= 12 && 10#$da >= 1 && 10#$da <= 31 )); then
      echo "$d"; return
    fi
    log "exif date out-of-range '$(log_value "$d")' for $(log_name "$f") — using mtime"
  elif [[ -n "$d" && "$d" != "-" ]]; then
    log "exif date malformed '$(log_value "$d")' for $(log_name "$f") — using mtime"
  else
    log "no exif date for $(log_name "$f") — using mtime"
  fi
  stat -Lc %y "$f" | cut -d' ' -f1
}

get_camera() {
  local f=$1 make model output rc
  output=$(exiftool_read -Make -s3 "$f")
  rc=$?
  if (( rc == 124 || rc == 137 )); then
    log "camera Make lookup timed out after ${RAW_VALIDATE_TIMEOUT}s — using Unknown"
    echo "Unknown"
    return 0
  fi
  (( rc == 0 )) || output=""
  output=${output%%$'\n'*}
  make=$(sanitize "$output")

  output=$(exiftool_read -Model -s3 "$f")
  rc=$?
  if (( rc == 124 || rc == 137 )); then
    log "camera Model lookup timed out after ${RAW_VALIDATE_TIMEOUT}s — using available metadata"
    output=""
  elif (( rc != 0 )); then
    output=""
  fi
  output=${output%%$'\n'*}
  model=$(sanitize "$output")
  # collapse redundant words (NIKON CORPORATION NIKON Z 9 -> NIKON Z 9).
  # Compare against the make's FIRST word: Nikon writes Make="NIKON
  # CORPORATION" but prefixes models with plain "NIKON", so a full-make
  # prefix test never fired. The panel's camera scanner mirrors this
  # composition exactly — keep them in lockstep.
  local make_head=${make%% *}
  if [[ -n "$make" && -n "$model" && "$model" == "$make_head"* ]]; then
    echo "$model"
  elif [[ -n "$make" && -n "$model" ]]; then
    echo "$make $model"
  elif [[ -n "$model" ]]; then
    echo "$model"
  else
    echo "Unknown"
  fi
}

# --- NEF post-sort hooks (adapted-lens identity fix + render queue) ---

exiftool_write() {
  timeout "$RAW_VALIDATE_TIMEOUT" exiftool -q -q -overwrite_original "$@" 2>/dev/null
}

panel_flag() {
  # panel_flag <feature> -> 0 when enabled. The panel writes config.json
  # atomically (tmp + rename), so jq always parses a complete file. A missing,
  # corrupt, or hand-mangled config fails OPEN to current behavior — the
  # pipeline must never depend on the panel existing.
  local name=$1 v
  [[ -f "$PANEL_CONFIG" ]] || return 0
  # No `//` anywhere in this filter: jq's alternative operator treats false
  # like null, which would turn every OFF switch back into ON. `?` alone
  # suppresses type errors (non-object features -> null -> "on").
  v=$(jq -r --arg k "$name" \
    'if .features[$k]? == false then "off" else "on" end' \
    "$PANEL_CONFIG" 2>/dev/null) || return 0
  [[ "$v" != "off" ]]
}

apply_lens_writes() {
  # Build the exiftool arg list from rule fields, re-validating shape here so
  # a mangled config can never smuggle arbitrary exiftool switches: every
  # value lands AFTER a fixed "-TAG=" prefix and must match a tight charset.
  # Identity tags only — FNumber/exposure are never written.
  local f=$1 base=$2 model=$3 info=$4 focal=$5
  local model_re='^[A-Za-z0-9][A-Za-z0-9 ./-]{0,62}$'
  local info_re='^[0-9][0-9. ]{0,30}$'
  local focal_re='^[0-9]{1,4}(\.[0-9])?$'
  local -a args=()
  if [[ -n "$model" && "$model" =~ $model_re ]]; then
    args+=("-EXIF:LensModel=$model")
  fi
  if [[ -n "$info" && "$info" =~ $info_re ]]; then
    args+=("-EXIF:LensInfo=$info")
  fi
  if [[ -n "$focal" && "$focal" =~ $focal_re ]]; then
    args+=("-EXIF:FocalLength=$focal" "-EXIF:FocalLengthIn35mmFormat=$focal")
  fi
  (( ${#args[@]} )) || return 0
  if exiftool_write "${args[@]}" "$f"; then
    log "lens: $base -> ${model:-focal ${focal}mm}"
  else
    log "lens massage failed (kept original tags): $base"
  fi
}

massage_nef_lens() {
  # Sony glass adapted onto the Nikon Zf reports its identity wrong — either
  # a bare focal/aperture pair or the adapter's alias (Samyang VAF / Megadap
  # strings for what is physically a GM). Rewrite lens IDENTITY tags only,
  # never FNumber/exposure, so Lightroom names the real lens. Tag shape
  # mirrors a native Sony body's own files (LensModel + LensInfo, no
  # LensMake). Runs post-move on the sorted copy — a failed write leaves a
  # valid, unmassaged file.
  #
  # Rules come from the panel config when present (matched on the Lens
  # signature, first hit wins); the built-in case below is the fallback when
  # no config exists, so the pipeline works identically without the panel.
  # Rules may scope to camera bodies: match_camera includes (any entry a
  # case-insensitive substring of the body name), exclude_camera carves out
  # of that set; both may combine. Camera comes from the caller's already-
  # sanitized get_camera value — no extra EXIF read.
  local f=$1 base=$2 camera=${3:-} lens lensid rule idre
  panel_flag lens_massage || return 0
  lens=$(exiftool_read -Lens -s3 "$f") || lens=""
  lens=${lens%%$'\n'*}
  [[ -n "$lens" ]] || return 0

  if [[ -f "$PANEL_CONFIG" ]]; then
    rule=$(jq -c --arg lens "$lens" --arg cam "$camera" '
      ($cam | ascii_downcase) as $c |
      [.lens_rules[]? | select(
        (.match_lens | type) == "array" and (.match_lens | index($lens))
        and (((.match_camera? // null) | type) != "array"
             or any(.match_camera[]? | strings; . as $m | $c | contains($m | ascii_downcase)))
        and (((.exclude_camera? // null) | type) != "array"
             or (any(.exclude_camera[]? | strings; . as $m | $c | contains($m | ascii_downcase)) | not))
      )][0] // empty' \
      "$PANEL_CONFIG" 2>/dev/null) || rule=""
    if [[ -n "$rule" ]]; then
      idre=$(jq -r '.match_lens_id_regex // empty' <<<"$rule" 2>/dev/null) || idre=""
      if [[ -n "$idre" ]]; then
        lensid=$(exiftool_read -LensID -s3 "$f") || lensid=""
        lensid=${lensid%%$'\n'*}
        # User regex meets camera-supplied input: cap the subject and bound
        # the match with a timeout so a pathological ERE can't wedge a sort
        # worker (this is the one spot user config drives a regex engine).
        # Invalid regex, no match, or timeout all skip the rule safely.
        lensid=${lensid:0:64}
        timeout 1 bash -c '[[ "$1" =~ $2 ]]' _ "$lensid" "$idre" 2>/dev/null || return 0
      fi
      apply_lens_writes "$f" "$base" \
        "$(jq -r '.lens_model // empty' <<<"$rule" 2>/dev/null)" \
        "$(jq -r '.lens_info // empty' <<<"$rule" 2>/dev/null)" \
        "$(jq -r '.set_focal_length // empty | tostring' <<<"$rule" 2>/dev/null)"
      return 0
    fi
    # A parseable config with no matching rule is authoritative: no fallback,
    # so deleting a rule in the panel really turns that rewrite off. Unknown
    # non-native glass gets queued for an interactive decision instead.
    if jq -e '.lens_rules | type == "array"' "$PANEL_CONFIG" >/dev/null 2>&1; then
      queue_lens_question "$f" "$base" "$lens" "$camera"
      return 0
    fi
  fi

  case "$lens" in
    "35mm f/1.4")
      apply_lens_writes "$f" "$base" "FE 35mm F1.4 GM" "35 35 1.4 1.4" ""
      ;;
    "50mm f/1.2"|"50mm f/1.3")
      apply_lens_writes "$f" "$base" "FE 50mm F1.2 GM" "50 50 1.2 1.2" ""
      ;;
    "0mm f/0")
      # Fully-manual adapted glass. The Zf menu's non-CPU focal length is not
      # landing in EXIF; the only such lens in use is the Leica 35mm.
      lensid=$(exiftool_read -LensID -s3 "$f") || lensid=""
      case "$lensid" in
        *Leica*35*|*Summicron*35*)
          apply_lens_writes "$f" "$base" "" "" "35"
          ;;
      esac
      ;;
  esac
  return 0
}

queue_lens_question() {
  # Unmatched, non-native glass (dumb M-mount adapters report nothing; smart
  # E-mount adapters sometimes report their own name): hand the decision to
  # the panel, which asks over Telegram with an inline lens menu and applies
  # the answer — or leaves the file untouched after the configured timeout.
  # Native NIKKOR glass never asks. The file is already sorted; this never
  # blocks or delays the pipeline.
  local f=$1 base=$2 lens=$3 camera=${4:-} lensid pending id
  panel_flag ask_on_unknown || return 0
  lensid=$(exiftool_read -LensID -s3 "$f") || lensid=""
  lensid=${lensid%%$'\n'*}
  case "$lensid" in *NIKKOR*|*Nikkor*) return 0 ;; esac
  # Camera-supplied strings: strip control chars and cap length (same
  # treatment as every other EXIF string here) so an oversized value can't
  # wedge the panel's Telegram send into a retry loop.
  lens=$(sanitize "$lens")
  lensid=$(sanitize "$lensid")
  pending="${PANEL_CONFIG%/*}/pending"
  mkdir -p "$pending" 2>/dev/null || return 0
  id=$(printf '%s' "$f" | sha256sum | cut -c1-16)
  if jq -n --arg rel "${f#"$SORTED"/}" --arg lens "$lens" --arg lensid "$lensid" \
       --arg camera "$camera" --arg ts "$(date +%s)" \
       '{rel: $rel, lens: $lens, lensid: $lensid, camera: $camera, ts: ($ts | tonumber)}' \
       > "$pending/.tmp.$id" 2>/dev/null \
     && mv -f -- "$pending/.tmp.$id" "$pending/$id.json" 2>/dev/null; then
    log "lens: unknown signature '$(log_value "$lens")' — queued decision for panel: $base"
  else
    rm -f -- "$pending/.tmp.$id" 2>/dev/null
  fi
  return 0
}

queue_nef_for_render() {
  # Hard-link the sorted NEF into the render queue that the nef-watch
  # container watches. Links cost no space and keep sorted/ as the only real
  # home; nef-watch mirrors the queue's relative path into its --out tree, so
  # the TIFF lands next to the NEF in sorted/. Only NEW files are linked —
  # the historical library never re-renders.
  local f=$1 relative=$2 base=$3
  [[ -n "$NEF_QUEUE" ]] || return 0
  panel_flag nef_render_queue || return 0
  if mkdir -p "$NEF_QUEUE/$relative" 2>/dev/null \
    && ln -f "$f" "$NEF_QUEUE/$relative/$base" 2>/dev/null; then
    :
  else
    log "nef-queue link failed: $base"
  fi
  return 0
}

prune_nef_queue() {
  [[ -n "$NEF_QUEUE" && -d "$NEF_QUEUE" ]] || return 0
  # ctime, not mtime: SMB drops preserve month-old mtimes, and a fresh hard
  # link only updates ctime. A week is ample for nef-watch to render; pruning
  # unpins inodes the user has since deleted from sorted/.
  find "$NEF_QUEUE" -type f -ctime +7 -delete 2>/dev/null
  find "$NEF_QUEUE" -mindepth 1 -type d -empty -delete 2>/dev/null
}

wait_stable() {
  local f=$1 a b start_id end_id now mtime
  [[ -f "$f" && ! -L "$f" ]] || return 1
  a=$(stat -c %s "$f" 2>/dev/null) || return 1
  start_id=$(path_identity "$f") || return 1
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
  sleep "$STABLE_WAIT"
  [[ -f "$f" && ! -L "$f" ]] || return 1
  b=$(stat -c %s "$f" 2>/dev/null) || return 1
  end_id=$(path_identity "$f") || return 1
  [[ "$a" == "$b" && "$start_id" == "$end_id" ]]
}

validate_file() {
  local f=$1 type=$2
  local original_ext=${3:-${f##*.}} size head tail ext model min_size vmeta rc
  size=$(stat -Lc %s "$f" 2>/dev/null) || { log "validate: stat failed"; return 1; }
  case "$type" in
    raw)
      ext=$original_ext
      model=$(camera_model "$f")
      rc=$?
      if (( rc == 124 || rc == 137 )); then
        return 1
      fi
      (( rc == 0 )) || model=""
      min_size=$(raw_min_bytes_for "$model" "$ext")
      (( size >= min_size )) || {
        log "validate: raw too small for ${model:-Unknown} ($size B < $min_size B)"
        return 1
      }
      vmeta=$(exiftool_read -Make -Model -s3 "$f")
      rc=$?
      if (( rc == 124 || rc == 137 )); then
        log "validate: raw Make/Model lookup timed out after ${RAW_VALIDATE_TIMEOUT}s"
        return 1
      fi
      if (( rc != 0 )) || ! grep -q '[^[:space:]]' <<<"$vmeta"; then
        log "validate: raw exif unreadable"
        return 1
      fi
      raw_container_validate "$f" || return 1
      raw_payload_validate "$f" "${ext,,}" || return $?
      ;;
    jpg)
      (( size > 50000 )) || { log "validate: jpg too small ($size B)"; return 1; }
      head=$(dd if="$f" bs=2 count=1 2>/dev/null | od -An -tx1 | tr -d ' \n')
      tail=$(tail -c 2 "$f" | od -An -tx1 | tr -d ' \n')
      [[ "$head" == "ffd8" ]] || { log "validate: jpg bad SOI ($head)"; return 1; }
      [[ "$tail" == "ffd9" ]] || { log "validate: jpg truncated (no EOI)"; return 1; }
      ;;
    heif)
      heif_container_validate "$f" "$original_ext" || return 1
      ;;
    video)
      (( size > 500000 )) || { log "validate: video too small ($size B)"; return 1; }
      vmeta=$(exiftool_read -FileType -s3 "$f")
      rc=$?
      if (( rc == 124 || rc == 137 )); then
        log "validate: video FileType lookup timed out after ${RAW_VALIDATE_TIMEOUT}s"
        return 1
      fi
      if (( rc != 0 )) || ! grep -q '[^[:space:]]' <<<"$vmeta"; then
        log "validate: video unreadable"
        return 1
      fi
      # FileType reads the ftyp box at the FRONT of the file, so a truncated
      # upload still passes it. Camera QuickTime variants (Sony XAVC-S MP4,
      # Fuji MOV) write the moov index at the END, so a cut-off transfer has
      # no Duration and exiftool flags truncated mdat. Require an intact tail
      # before blessing — same idea as the RAW EOF checks.
      vmeta=$(exiftool_read -S -Duration -Warning -api largefilesupport=1 "$f")
      rc=$?
      if (( rc == 124 || rc == 137 )); then
        log "validate: video Duration lookup timed out after ${RAW_VALIDATE_TIMEOUT}s"
        return 1
      fi
      (( rc == 0 )) || { log "validate: video metadata unreadable"; return 1; }
      if grep -qi 'truncated' <<<"$vmeta"; then
        log "validate: video truncated ($(grep -im1 '^Warning' <<<"$vmeta"))"
        return 1
      fi
      ext=$original_ext
      case "${ext,,}" in
        mp4|mov|m4v)
          grep -q '^Duration' <<<"$vmeta" || { log "validate: video missing Duration (no moov atom — truncated upload?)"; return 1; }
          ;;
      esac
      ;;
    other) ;;
  esac
  return 0
}

# An incoming file whose name already exists in sorted/ with identical bytes is
# a re-send (camera retry, SD-card drag of shots that already uploaded). It is
# staged under quarantine/_dupes/<date>/ instead of becoming name_2.ext, and
# pruned after DUPES_KEEP_DAYS. Staging instead of deleting is what makes the
# compare-then-act race harmless: if an SMB writer swaps the sorted leaf between
# the compare and the move, the incoming bytes still exist on disk. The source
# is the pinned /proc fd from process(); the leaf identity is re-read after the
# compare so a swapped destination falls back to the _N path.
# ponytail: runs outside the move lock — a concurrent same-name move simply
# ends up on the _N path, never in data loss.
exact_duplicate() {
  local src=$1 dst=$2 before after
  [[ -f "$dst" && ! -L "$dst" ]] || return 1
  before=$(path_identity "$dst") || return 1
  [[ "$(stat -Lc %s -- "$src" 2>/dev/null)" == "$(stat -c %s -- "$dst" 2>/dev/null)" ]] || return 1
  cmp -s -- "$src" "$dst" || return 1
  after=$(path_identity "$dst") || return 1
  [[ "$before" == "$after" ]]
}

MOVED_DEST=""
move_with_suffix() {
  local f=$1 root=$2 relative=$3 base=$4 name=$5 ext=$6 expected_source_id=$7
  local log_base
  log_base=$(log_name "$base")
  # Destination selection and the move must be one critical section. Without
  # this lock, parallel workers with the same basename can both observe an
  # unused path and mv will silently overwrite whichever one arrived first.
  {
    flock -x 201 || { log "FAIL cannot lock destination moves"; return 1; }
    [[ -f "$f" && ! -L "$f" ]] || return 1

    # Hold the source directory itself before changing cwd to pin the output
    # directory. Every later source operation goes through this descriptor, so
    # replacing a nested incoming ancestor with a symlink cannot redirect the
    # move or its recovery outside the original source directory.
    local source_parent=${f%/*} source_leaf=${f##*/} source_dir_fd
    local source_parent_fd source_ref source_parent_real source_id
    if [[ -z "$source_parent" || "$source_parent" == "$f" \
      || -z "$source_leaf" || "$source_leaf" == "." || "$source_leaf" == ".." ]]; then
      log "FAIL unsafe source path for $log_base"
      return 1
    fi
    if path_has_symlink_component "$source_parent" \
      || [[ -L "$source_parent" || ! -d "$source_parent" ]]; then
      log "FAIL unsafe source parent for $log_base"
      return 1
    fi
    if ! exec {source_dir_fd}<"$source_parent"; then
      log "FAIL cannot pin source parent for $log_base"
      return 1
    fi
    source_parent_fd="/proc/$BASHPID/fd/$source_dir_fd"
    source_parent_real=$(realpath -e -- "$source_parent_fd" 2>/dev/null || true)
    if [[ -z "$source_parent_real" ]] \
      || ! pinned_source_parent_is_canonical "$source_parent_fd" "$source_parent"; then
      log "FAIL source parent changed while pinning $log_base"
      exec {source_dir_fd}>&-
      return 1
    fi
    source_ref="$source_parent_fd/$source_leaf"
    if [[ ! -f "$source_ref" || -L "$source_ref" ]]; then
      exec {source_dir_fd}>&-
      return 1
    fi
    source_id=$(stat -c '%d:%i' -- "$source_ref" 2>/dev/null) || {
      exec {source_dir_fd}>&-
      return 1
    }
    if [[ "$source_id" != "$expected_source_id" ]]; then
      log "FAIL source changed after validation; left for revalidation: $log_base"
      exec {source_dir_fd}>&-
      return 1
    fi

    if ! prepare_output_subdir "$root" "$relative"; then
      exec {source_dir_fd}>&-
      return 1
    fi
    local dir=$SAFE_OUTPUT_DIR
    local original_pwd=$PWD leaf=$base n=2 result=1
    local dest_id move_rc rollback_status moved_id pinned_destination_real
    local source_parent_recovery_real
    local output_path_changed source_parent_changed

    # Pin the validated output directory as this worker's cwd. Pathname-based
    # `mv` would otherwise re-resolve an ancestor that an SMB client replaced
    # with a symlink after prepare_output_subdir(). The cwd is a kernel-held
    # directory reference; every leaf operation below is relative to it.
    if ! cd -P -- "$dir"; then
      log "FAIL cannot pin output directory for $log_base: $(log_value "$dir")"
      exec {source_dir_fd}>&-
      return 1
    fi

    if ! cwd_matches_output_path "$root" "$dir"; then
      log "FAIL output directory changed before moving $log_base: $(log_value "$dir")"
    else
      while true; do
        if ! cwd_matches_output_path "$root" "$dir"; then
          log "FAIL output directory changed during collision handling for $log_base: $(log_value "$dir")"
          break
        fi
        if ! pinned_source_parent_is_canonical "$source_parent_fd" "$source_parent"; then
          log "FAIL source parent changed during collision handling for $log_base"
          break
        fi
        if [[ -L "./$leaf" ]]; then
          log "FAIL unsafe destination symlink for $log_base: $(log_value "$dir/$leaf")"
          break
        fi
        if [[ -e "./$leaf" ]]; then
          if [[ ! -f "./$leaf" ]]; then
            log "FAIL unsafe non-file destination for $log_base: $(log_value "$dir/$leaf")"
            break
          fi
          # Never delete an incoming file merely because an existing path has
          # matching bytes: a same-UID SMB writer can swap that leaf between a
          # compare and an unlink. Byte-identical re-sends are *staged* under
          # quarantine/_dupes by process() before it ever calls this function;
          # anything that reaches here keeps both copies with a suffix.
          leaf="${name}_${n}.${ext}"
          n=$((n+1))
          if (( n > 999 )); then
            log "FAIL too many collisions: $log_base"
            break
          fi
          continue
        fi

        move_rc=0
        mv -n -T -- "$source_ref" "./$leaf" || move_rc=$?

        dest_id=""
        if [[ -e "./$leaf" || -L "./$leaf" ]]; then
          dest_id=$(stat -c '%d:%i' -- "./$leaf" 2>/dev/null || true)
        fi

        # If either pathname boundary moved while mv ran, the descriptors still
        # point at the exact safe directories. Return the just-moved inode
        # through those pinned references before reporting failure. Never claim
        # recovery unless the exact inode returned and disappeared from output.
        output_path_changed=0
        source_parent_changed=0
        cwd_matches_output_path "$root" "$dir" || output_path_changed=1
        pinned_source_parent_is_canonical "$source_parent_fd" "$source_parent" \
          || source_parent_changed=1
        if (( output_path_changed || source_parent_changed )); then
          if [[ -n "$dest_id" && ! -e "$source_ref" && ! -L "$source_ref" ]]; then
            moved_id=$dest_id
            rollback_status=0
            rollback_to_pinned_source "./$leaf" "$source_ref" "$moved_id" "$source_parent_fd" \
              || rollback_status=$?
            if (( rollback_status == 0 )); then
              if [[ "$moved_id" != "$source_id" ]]; then
                log "FAIL source changed during move; replacement recovered through pinned source parent for revalidation: $log_base"
              elif (( source_parent_changed && output_path_changed )); then
                log "FAIL source and output parents changed; validated inode recovered through pinned original source parent: $(log_value "$source_parent/$source_leaf")"
              elif (( source_parent_changed )); then
                log "FAIL source parent changed; validated inode recovered through pinned original parent: $(log_value "$source_parent/$source_leaf")"
              elif pinned_source_parent_is_canonical "$source_parent_fd" "$source_parent"; then
                log "FAIL output directory changed; incoming source recovered: $log_base"
              else
                log "FAIL output directory changed; source recovered through pinned original parent (incoming path changed): $(log_value "$source_parent/$source_leaf")"
              fi
            elif (( rollback_status == 2 )); then
              log "FAIL output directory changed and pinned source leaf is occupied; moved inode retained in pinned destination: $(log_value "$dir/$leaf")"
            elif (( rollback_status == 3 )); then
              pinned_destination_real=$(realpath -e -- "/proc/$BASHPID/cwd" 2>/dev/null || true)
              [[ -n "$pinned_destination_real" ]] || pinned_destination_real="/proc/$BASHPID/cwd"
              log "FAIL source parent left incoming during move; moved inode retained for recovery at: $(log_value "$pinned_destination_real/$leaf")"
            elif (( rollback_status == 4 )); then
              pinned_destination_real=$(realpath -e -- "/proc/$BASHPID/cwd" 2>/dev/null || true)
              source_parent_recovery_real=$(realpath -e -- "$source_parent_fd" 2>/dev/null || true)
              log "FAIL source parent escaped during recovery and exact-inode return failed (rc=$ROLLBACK_RC); inspect source=$(log_value "${source_parent_recovery_real:-unknown}/$source_leaf") destination=$(log_value "${pinned_destination_real:-unknown}/$leaf")"
            else
              log "FAIL output directory changed and pinned recovery failed (rc=$ROLLBACK_RC): $(log_value "$source_parent/$source_leaf")"
            fi
          else
            log "FAIL output directory changed before a verified move: $log_base"
          fi
          break
        fi

        if [[ ! -e "$source_ref" && ! -L "$source_ref" \
          && -f "./$leaf" && ! -L "./$leaf" \
          && -n "$dest_id" && "$dest_id" == "$source_id" ]]; then
          MOVED_DEST="$dir/$leaf"
          result=0
          break
        fi

        # The source leaf can be replaced after its inode was captured but
        # before mv opens it. If that replacement reached the destination,
        # return that exact inode to the pinned source parent and fail this
        # attempt so a later reconcile performs the full validation pipeline.
        if [[ ! -e "$source_ref" && ! -L "$source_ref" \
          && -n "$dest_id" && "$dest_id" != "$source_id" ]]; then
          moved_id=$dest_id
          rollback_status=0
          rollback_to_pinned_source "./$leaf" "$source_ref" "$moved_id" "$source_parent_fd" \
            || rollback_status=$?
          if (( rollback_status == 0 )); then
            log "FAIL source changed during move; replacement recovered through pinned source parent for revalidation: $log_base"
          elif (( rollback_status == 2 )); then
            log "FAIL source changed during move and pinned source leaf is occupied; moved inode retained in pinned destination: $(log_value "$dir/$leaf")"
          elif (( rollback_status == 3 )); then
            pinned_destination_real=$(realpath -e -- "/proc/$BASHPID/cwd" 2>/dev/null || true)
            [[ -n "$pinned_destination_real" ]] || pinned_destination_real="/proc/$BASHPID/cwd"
            log "FAIL source parent left incoming during source swap; moved replacement retained for recovery at: $(log_value "$pinned_destination_real/$leaf")"
          elif (( rollback_status == 4 )); then
            pinned_destination_real=$(realpath -e -- "/proc/$BASHPID/cwd" 2>/dev/null || true)
            source_parent_recovery_real=$(realpath -e -- "$source_parent_fd" 2>/dev/null || true)
            log "FAIL source parent escaped during source-swap recovery and exact-inode return failed (rc=$ROLLBACK_RC); inspect source=$(log_value "${source_parent_recovery_real:-unknown}/$source_leaf") destination=$(log_value "${pinned_destination_real:-unknown}/$leaf")"
          else
            log "FAIL source changed during move and pinned recovery failed (rc=$ROLLBACK_RC): $(log_value "$source_parent/$source_leaf")"
          fi
          break
        fi

        # GNU mv -n returns success when another writer wins the leaf. Treat a
        # regular-file collision as a suffix retry, but a symlink as unsafe.
        if [[ -f "$source_ref" && ! -L "$source_ref" ]]; then
          if [[ -L "./$leaf" ]]; then
            log "FAIL unsafe destination symlink won move race for $log_base: $(log_value "$dir/$leaf")"
            break
          fi
          if [[ -e "./$leaf" ]]; then
            if [[ ! -f "./$leaf" ]]; then
              log "FAIL unsafe non-file destination won move race for $log_base: $(log_value "$dir/$leaf")"
              break
            fi
            leaf="${name}_${n}.${ext}"
            n=$((n+1))
            if (( n > 999 )); then
              log "FAIL too many collisions: $log_base"
              break
            fi
            continue
          fi
        fi
        log "FAIL mv (rc=$move_rc) for $log_base -> $(log_value "$dir/$leaf")"
        break
      done
    fi

    if ! cd -P -- "$original_pwd"; then
      log "FAIL cannot restore worker directory: $(log_value "$original_pwd")"
      exec {source_dir_fd}>&-
      return 1
    fi
    exec {source_dir_fd}>&-
    return "$result"
  } 201>>"$MOVE_LOCK"
}

# --- Notification queue (append per successful sort, flush every NOTIFY_INTERVAL seconds) ---
QUEUE_SNAPSHOT=""
snapshot_queue() {
  local queue=$1 kind=$2
  QUEUE_SNAPSHOT=$(mktemp "$QUEUE_DIR/.${kind}.pending.XXXXXX") || {
    log "cannot allocate $kind queue snapshot"
    return 1
  }
  chmod 0600 -- "$QUEUE_SNAPSHOT" || { rm -- "$QUEUE_SNAPSHOT"; return 1; }
  {
    flock -x 200 || return 1
    if [[ ! -s "$queue" ]]; then
      rm -- "$QUEUE_SNAPSHOT"
      QUEUE_SNAPSHOT=""
      return 1
    fi
    cp -- "$queue" "$QUEUE_SNAPSHOT" || return 1
    : > "$queue" || return 1
  } 200>>"$NOTIFY_LOCK"
}

restore_queue_snapshot() {
  local queue=$1 snapshot=$2
  [[ -f "$snapshot" && ! -L "$snapshot" ]] || return 1
  {
    flock -x 200 || return 1
    cat -- "$snapshot" >> "$queue" || return 1
    rm -- "$snapshot"
  } 200>>"$NOTIFY_LOCK"
}

enqueue_notify() {
  local camera type basename
  (( TELEGRAM_ENABLED )) || return 0
  camera=$(sanitize "$1"); type=$(sanitize "$2"); basename=$(sanitize "$3")
  {
    flock -x 200 || {
      log "cannot lock upload notification queue"
      return 1
    }
    printf '%s\t%s\t%s\t%s\n' "$(date '+%H:%M:%S')" "$camera" "$type" "$basename" >> "$NOTIFY_QUEUE"
  } 200>>"$NOTIFY_LOCK"
}

flush_notify() {
  {
    flock -x 202 || { log "cannot lock notification flush lifecycle"; return 1; }
    [[ -s "$NOTIFY_QUEUE" ]] || return 0
    snapshot_queue "$NOTIFY_QUEUE" notify || return 0
    local rotated=$QUEUE_SNAPSHOT

    local total per_camera msg
    total=$(wc -l < "$rotated")
    per_camera=$(awk -F'\t' '{c[$2]++} END {for (k in c) printf "%d\t%s\n", c[k], k}' "$rotated" \
      | sort -rn | awk -F'\t' '{printf "• %d × %s\n", $1, $2}')
    msg=$(printf "📸 %d file(s) uploaded in last 5 min:\n%s" "$total" "$per_camera")

    if telegram_send "$msg"; then
      rm -- "$rotated"
    else
      restore_queue_snapshot "$NOTIFY_QUEUE" "$rotated" \
        || log "notification snapshot retained for startup recovery: $rotated"
    fi
  } 202>>"$FLUSH_LOCK"
}

# Quarantines get their own batched alert. Usually a quarantined file is a
# partial from an aborted FTP transfer and the camera re-sends a good copy
# minutes later — the message says so, so a ping isn't a panic. A name that
# never shows up in a later "uploaded" batch is the one to go pull from card.
enqueue_quar() {
  local basename reason
  (( TELEGRAM_ENABLED )) || return 0
  basename=$(sanitize "$1"); reason=$(sanitize "$2")
  {
    flock -x 200 || {
      log "cannot lock quarantine notification queue"
      return 1
    }
    printf '%s\t%s\t%s\n' "$(date '+%H:%M:%S')" "$basename" "$reason" >> "$QUAR_QUEUE"
  } 200>>"$NOTIFY_LOCK"
}

flush_quar() {
  {
    flock -x 202 || { log "cannot lock notification flush lifecycle"; return 1; }
    [[ -s "$QUAR_QUEUE" ]] || return 0
    snapshot_queue "$QUAR_QUEUE" quarantine || return 0
    local rotated=$QUEUE_SNAPSHOT

    local total names msg
    total=$(wc -l < "$rotated")
    names=$(awk -F'\t' '{print "• " $2 " (" $3 ")"}' "$rotated" | head -10)
    (( total > 10 )) && names="$names
…and $((total-10)) more"
    msg=$(printf "⚠️ %d file(s) quarantined:\n%s\nUsually aborted transfers — the camera normally re-sends a good copy. If a name never lands in sorted/, recover it from the SD card." "$total" "$names")

    if telegram_send "$msg"; then
      rm -- "$rotated"
    else
      restore_queue_snapshot "$QUAR_QUEUE" "$rotated" \
        || log "quarantine snapshot retained for startup recovery: $rotated"
    fi
  } 202>>"$FLUSH_LOCK"
}

# Permission-problem queue. Separate from quarantine because the file is NOT
# bad — it's just unreadable by our UID and sitting in incoming. Dedup by
# filename (enqueue_perm returns 1 if already queued) so a file that survives
# multiple reconcile passes only logs/alerts once per flush window.
enqueue_perm() {
  local basename; basename=$(sanitize "$1")
  (( TELEGRAM_ENABLED )) || return 0
  {
    flock -x 200 || {
      log "cannot lock permission notification queue"
      return 1
    }
    if grep -qxF -- "$basename" "$PERM_QUEUE" 2>/dev/null; then
      return 1
    fi
    printf '%s\n' "$basename" >> "$PERM_QUEUE"
  } 200>>"$NOTIFY_LOCK"
}

flush_perm() {
  {
    flock -x 202 || { log "cannot lock notification flush lifecycle"; return 1; }
    [[ -s "$PERM_QUEUE" ]] || return 0
    snapshot_queue "$PERM_QUEUE" permission || return 0
    local rotated=$QUEUE_SNAPSHOT

    local total names msg
    total=$(wc -l < "$rotated")
    names=$(sed 's/^/• /' "$rotated" | head -8)
    (( total > 8 )) && names="$names
…and $((total-8)) more"
    msg=$(printf "🔒 %d file(s) in incoming are UNREADABLE (wrong ownership, not corrupt):\n%s\nThey are safe but won't sort until fixed. On the Tower run the root idle-file helper:\nbash /boot/config/scripts/ftpdropbox-fixperms.sh\nIt repairs only idle files and required ancestor directories to %s:%s. Do not recursively change ownership while uploads are active." "$total" "$names" "$SORTER_UID" "$SORTER_GID")

    if telegram_send "$msg"; then
      rm -- "$rotated"
    else
      restore_queue_snapshot "$PERM_QUEUE" "$rotated" \
        || log "permission snapshot retained for startup recovery: $rotated"
    fi
  } 202>>"$FLUSH_LOCK"
}

notifier_loop() {
  while true; do
    sleep "$NOTIFY_INTERVAL"
    flush_notify
    flush_quar
    flush_perm
  done
}

# --- Main process pipeline ---
process() {
  local f=$1 source_fd source_ref expected_source_id current_source_id
  [[ -f "$f" && ! -L "$f" ]] || return 0
  local base log_base moved_log
  base=$(basename "$f")
  log_base=$(log_name "$base")
  case "$base" in .*|*.tmp|*.part|*.filepart|Thumbs.db) return 0 ;; esac
  # Readability guard: a file dropped in via SMB/scp as another UID with
  # owner-only perms (e.g. 700 502:games) is invisible to our UID. Without
  # this check every unreadable file fails EXIF validation and gets
  # quarantined as "corrupt" — mixing perfectly good files into quarantine.
  # Instead, leave it in incoming and raise a distinct, throttled alert so the
  # user fixes ownership for this runtime UID/GID. The stuck scan keeps it visible.
  if [[ ! -r "$f" ]]; then
    if enqueue_perm "$base"; then
      log "UNREADABLE (permissions): $log_base — left in incoming; run /boot/config/scripts/ftpdropbox-fixperms.sh or repair only this idle file and required ancestor directories to ${SORTER_UID}:${SORTER_GID}"
    fi
    return 0
  fi
  wait_stable "$f" || { log "skip unstable: $log_base"; return 0; }

  local ext="${base##*.}" name="${base%.*}"
  local type; type=$(get_type "$ext")
  # Validate through an open descriptor, then require the incoming leaf to
  # still name that exact inode before moving it. This prevents a same-name
  # replacement between validation and mv from being sorted or quarantined
  # under the first file's verdict.
  if ! exec {source_fd}<"$f"; then
    log "skip unstable: $log_base disappeared before validation"
    return 0
  fi
  source_ref="/proc/$BASHPID/fd/$source_fd"
  expected_source_id=$(path_target_identity "$source_ref" 2>/dev/null || true)
  current_source_id=$(path_identity "$f" 2>/dev/null || true)
  if [[ -z "$expected_source_id" || "$current_source_id" != "$expected_source_id" \
    || ! -f "$f" || -L "$f" ]]; then
    exec {source_fd}<&-
    log "skip unstable: $log_base changed before validation"
    return 0
  fi

  local date; date=$(get_date "$source_ref")

  if validate_file "$source_ref" "$type" "$ext"; then
    :
  else
    local validation_rc=$?
    if (( validation_rc == 75 )); then
      exec {source_fd}<&-
      log "skip unstable: $log_base changed during validation"
      return 0
    fi
    if move_with_suffix "$f" "$QUARANTINE" "$date" "$base" "$name" "$ext" "$expected_source_id"; then
      moved_log=$(log_name "$MOVED_DEST")
      log "QUARANTINE: $log_base -> $date/$moved_log"
      enqueue_quar "$base" "failed validation"
    fi
    exec {source_fd}<&-
    return 0
  fi

  # Capture metadata while the source is still held by its process claim. Once
  # moved, an SMB client may legitimately rename output folders; notification
  # generation must not re-open a path whose ancestry can change independently.
  local camera; camera=$(get_camera "$source_ref")
  if exact_duplicate "$source_ref" "$SORTED/$date/$type/$base"; then
    if move_with_suffix "$f" "$QUARANTINE" "_dupes/$date" "$base" "$name" "$ext" "$expected_source_id"; then
      moved_log=$(log_name "$MOVED_DEST")
      log "DUPLICATE: $log_base == $date/$type/$log_base -> _dupes/$date/$moved_log (pruned after ${DUPES_KEEP_DAYS}d)"
      enqueue_notify "duplicate (already in sorted)" "$type" "$base"
    fi
    exec {source_fd}<&-
    return 0
  fi
  if move_with_suffix "$f" "$SORTED" "$date/$type" "$base" "$name" "$ext" "$expected_source_id"; then
    moved_log=$(log_name "$MOVED_DEST")
    log "ok: $log_base -> $date/$type/$moved_log"
    enqueue_notify "$camera" "$type" "$base"
    case "${ext,,}" in
      nef|nrw)
        # MOVED_DEST is the absolute final path (suffix included). Massage
        # BEFORE queueing so nef-watch copies the corrected EXIF onto the
        # TIFF it renders.
        if truthy "$NEF_LENS_MASSAGE"; then
          massage_nef_lens "$MOVED_DEST" "$moved_log" "$camera"
        fi
        queue_nef_for_render "$MOVED_DEST" "$date/$type" "${MOVED_DEST##*/}"
        ;;
    esac
  fi
  exec {source_fd}<&-
}

# inotify can emit several close events for one path, and an idle reconcile can
# overlap an event worker. Hash paths into a fixed 256-file sidecar lock table:
# the table stays bounded, while an occasional collision only serializes two
# unrelated paths. Lock files stay in place because unlinking a live lock could
# let two workers hold different inodes for the same bucket.
process_claimed() {
  local f=$1 key claim_fd rc log_base
  [[ -f "$f" && ! -L "$f" ]] || return 0
  log_base=$(log_name "$f")
  key=$(printf '%s' "$f" | sha256sum | cut -c1-2)
  if [[ -z "$key" ]]; then
    log "FAIL cannot create process claim for $log_base"
    return 1
  fi
  prepare_lock_file "$PROCESS_LOCK_DIR/$key.lock" || return 1
  exec {claim_fd}>>"$PROCESS_LOCK_DIR/$key.lock" || {
    log "FAIL cannot open process claim for $log_base"
    return 1
  }
  # Bucket collisions must wait, not discard an event. process() rechecks that
  # the source still exists after acquiring the lock, so duplicate events for a
  # path that was already moved become cheap no-ops.
  if ! flock -x "$claim_fd"; then
    exec {claim_fd}>&-
    log "FAIL cannot acquire process claim for $log_base"
    return 1
  fi
  process "$f"
  rc=$?
  exec {claim_fd}>&-
  return "$rc"
}

# Keep file processing bounded: RAW validation is CPU-, memory-, and
# temporary-disk-heavy, so an unbounded background job per inotify event can
# overwhelm the host during a large camera dump.
WORKER_PIDS=()
NOTIFIER_PID=""
INOTIFY_PID=""
WATCH_PROBE_DIR=""
WATCH_PROBE=""
NEXT_RECONCILE_AT=0

remove_worker_pid() {
  local completed=$1 pid
  local -a remaining=()
  for pid in "${WORKER_PIDS[@]}"; do
    [[ "$pid" == "$completed" ]] || remaining+=("$pid")
  done
  WORKER_PIDS=("${remaining[@]}")
}

wait_for_worker_slot() {
  local completed first
  while (( ${#WORKER_PIDS[@]} >= SORT_WORKERS )); do
    completed=""
    wait -n -p completed "${WORKER_PIDS[@]}" 2>/dev/null || true
    if [[ -z "$completed" ]]; then
      # Defensive fallback if Bash cannot identify the completed child.
      first=${WORKER_PIDS[0]}
      wait "$first" 2>/dev/null || true
      completed=$first
    fi
    remove_worker_pid "$completed"
  done
}

dispatch() {
  local f=$1
  [[ -f "$f" && ! -L "$f" ]] || return 0
  wait_for_worker_slot
  process_claimed "$f" &
  WORKER_PIDS+=("$!")
}

wait_for_workers() {
  local pid
  for pid in "${WORKER_PIDS[@]}"; do
    wait "$pid" 2>/dev/null || true
  done
  WORKER_PIDS=()
}

terminate_process_tree() {
  local pid=$1 children="" child
  # A SIGTERM can interrupt `IFS= read` in the event loop and invoke this trap
  # while IFS is temporarily empty. Always split procfs/ps child lists with an
  # explicit local whitespace definition.
  local IFS=$' \t\n'
  [[ "$pid" =~ ^[0-9]+$ ]] && (( pid > 1 )) || return 0
  # Freeze the parent first so it cannot spawn another external command while
  # we walk /proc and terminate its descendants.
  kill -STOP "$pid" 2>/dev/null || return 0
  if [[ -r "/proc/$pid/task/$pid/children" ]]; then
    children=$(<"/proc/$pid/task/$pid/children")
  else
    # Some NAS kernels omit the procfs children file. BusyBox ps is present in
    # the image and gives us the same direct-child relation.
    children=$(ps -eo pid,ppid 2>/dev/null | awk -v parent="$pid" '$2 == parent {print $1}')
  fi
  if [[ -n "$children" ]]; then
    for child in $children; do
      terminate_process_tree "$child"
    done
  fi
  kill -KILL "$pid" 2>/dev/null || true
}

cleanup_watch_probe() {
  if [[ -n "$WATCH_PROBE" ]]; then
    rm -- "$WATCH_PROBE" 2>/dev/null || true
    WATCH_PROBE=""
  fi
  if [[ -n "$WATCH_PROBE_DIR" ]]; then
    rmdir -- "$WATCH_PROBE_DIR" 2>/dev/null || true
    WATCH_PROBE_DIR=""
  fi
}

shutdown() {
  local exit_code=${1:-0}
  trap - SIGTERM SIGINT
  log "shutdown requested — stopping intake and active workers"
  [[ -z "$INOTIFY_PID" ]] || terminate_process_tree "$INOTIFY_PID"
  [[ -z "$NOTIFIER_PID" ]] || terminate_process_tree "$NOTIFIER_PID"
  local pid
  for pid in "${WORKER_PIDS[@]}"; do
    terminate_process_tree "$pid"
  done
  wait_for_workers
  [[ -z "$NOTIFIER_PID" ]] || wait "$NOTIFIER_PID" 2>/dev/null || true
  [[ -z "$INOTIFY_PID" ]] || wait "$INOTIFY_PID" 2>/dev/null || true
  cleanup_watch_probe
  exit "$exit_code"
}

start_inotify_watcher() {
  local watch_root=${INCOMING%/} event read_rc deadline
  [[ -n "$watch_root" ]] || watch_root=/
  WATCH_PROBE_DIR=$(mktemp -d /tmp/camera-sorter-watch-ready.XXXXXX) || {
    log "cannot create private inotify readiness directory"
    return 1
  }
  WATCH_PROBE=$(mktemp "$WATCH_PROBE_DIR/.event.XXXXXX") || {
    log "cannot create private inotify readiness probe"
    cleanup_watch_probe
    return 1
  }

  # `create` too: the panel's no-clobber funnel enters files as hard links
  # (link+unlink), which emit CREATE, not MOVED_TO — without it those files
  # sit until the next reconcile. Early CREATEs for in-progress writes are
  # harmless: wait_stable holds them until the size settles.
  exec 3< <(inotifywait -m -r -q -e close_write -e moved_to -e create --format '%w%f' \
    "$watch_root" "$WATCH_PROBE_DIR")
  INOTIFY_PID=$!

  # A process-substitution fd can exist before inotifywait has installed its
  # watches. Generate a close_write event in a private, unpredictable directory
  # and do not announce readiness until it comes back through the actual event
  # pipe. Any unrelated incoming events consumed here are safe: the startup
  # reconcile immediately follows.
  printf '.' >> "$WATCH_PROBE" || {
    log "cannot write private inotify readiness probe"
    return 1
  }
  deadline=$((SECONDS + WATCH_READY_TIMEOUT))
  while (( SECONDS < deadline )); do
    IFS= read -t 1 -u 3 -r event
    read_rc=$?
    if (( read_rc == 0 )); then
      if [[ "$event" == "$WATCH_PROBE" ]]; then
        if ! rm -- "$WATCH_PROBE"; then
          log "cannot remove private inotify readiness probe"
          return 1
        fi
        WATCH_PROBE=""
        return 0
      fi
      continue
    fi
    if (( read_rc == 1 )); then
      log "inotifywait exited before watcher readiness"
      return 1
    fi
    # The first probe may have been written before watches were established.
    printf '.' >> "$WATCH_PROBE" || {
      log "cannot refresh private inotify readiness probe"
      return 1
    }
  done
  log "inotifywait did not establish watches within ${WATCH_READY_TIMEOUT}s"
  return 1
}

prune_stale_raw_tmp() {
  [[ -d "$RAW_VALIDATE_TMPDIR" ]] || return 0
  # raw_payload_validate creates only raw.* directories here. A validation is
  # bounded to four minutes by default, so 15-minute-old entries are abandoned
  # scratch from a hard stop and can be removed safely.
  find "$RAW_VALIDATE_TMPDIR" -mindepth 1 -maxdepth 1 -type d \
    -name 'raw.*' -mmin +"$RAW_VALIDATE_TMP_STALE_MIN" \
    -exec rm -rf -- {} + 2>/dev/null
}

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

prune_stale_dupes() {
  # Staged duplicates are byte-identical to a file still in sorted/; the stage
  # is only an undo window. ctime, not mtime: the move keeps the camera's
  # capture-time mtime (possibly weeks old) but bumps ctime.
  [[ -d "$QUARANTINE/_dupes" ]] || return 0
  find "$QUARANTINE/_dupes" -type f -ctime +"$DUPES_KEEP_DAYS" -delete 2>/dev/null
  find "$QUARANTINE/_dupes" -mindepth 1 -type d -empty -delete 2>/dev/null
}

reconcile() {
  log "reconcile scan"
  # -type f recurses the whole tree: a true dropbox processes files at any depth,
  # not just the top level. process() handles arbitrary source paths (spaces,
  # colons, nested dirs) — it sorts by EXIF date regardless of folder layout.
  while IFS= read -r -d '' f; do
    dispatch "$f"
  done < <(find "$INCOMING" -type f -print0 2>/dev/null)
  wait_for_workers
  prune_stale_raw_tmp
  prune_stale_ftp_tmp
  prune_stale_dupes
  prune_nef_queue
  find "$INCOMING" -type f -mmin +"$STUCK_AGE_MIN" -print0 2>/dev/null | while IFS= read -r -d '' f; do
    log "STUCK >${STUCK_AGE_MIN}min: $(log_name "$f")"
  done
  NEXT_RECONCILE_AT=$((SECONDS + RECONCILE_IDLE))
}

trap shutdown SIGTERM SIGINT
prepare_data_roots || exit 2
prepare_lock_storage || exit 2
prepare_state_storage || exit 2
verify_flock_exclusion || exit 2
recover_queue_snapshots || exit 2
# Reclaim abandoned decode output only after its private root has passed every
# symlink and ownership check. reconcile() also prunes after joining workers.
prune_stale_raw_tmp
start_inotify_watcher || shutdown 1
log "startup drain of $INCOMING"
reconcile

# Online ping
if (( TELEGRAM_ENABLED )); then
  telegram_send "🟢 camera-sorter online (aggregating every ${NOTIFY_INTERVAL}s)" || log "startup ping failed"
  notifier_loop &
  NOTIFIER_PID=$!
else
  log "no telegram config at $TG_CONFIG — notifications disabled"
fi

log "watching $INCOMING (workers=${SORT_WORKERS}, stable_wait=${STABLE_WAIT}s, raw_full_validate=${RAW_FULL_VALIDATE}, collision_policy=preserve, notify=${NOTIFY_INTERVAL}s)"
# -r watches the whole tree, so files dropped into subfolders fire live events
# too. inotifywait auto-adds watches on new subdirectories as they appear.
# SORTED/QUARANTINE/tmp all live OUTSIDE incoming (siblings under /data), so the
# recursive watch never sees our own output — no feedback loop.
while true; do
  reconcile_timeout=$((NEXT_RECONCILE_AT - SECONDS))
  if (( reconcile_timeout <= 0 )); then
    reconcile
    continue
  fi
  if IFS= read -t "$reconcile_timeout" -u 3 -r f; then
    if [[ -d "$f" ]]; then
      # A whole folder was moved/created in one operation — inotify reports the
      # directory, not the files already inside it. Sweep its contents now
      # instead of waiting for the next reconcile.
      while IFS= read -r -d '' sub; do
        dispatch "$sub"
      done < <(find "$f" -type f -print0 2>/dev/null)
      wait_for_workers
    else
      dispatch "$f"
    fi
  else
    read_rc=$?
    if (( read_rc == 1 )); then
      # EOF means inotifywait died. Exiting nonzero lets Docker's restart policy
      # recreate the watcher and the startup reconcile closes the event gap.
      log "inotifywait exited — exiting for container restart"
      shutdown 1
    fi
    reconcile
  fi
done
