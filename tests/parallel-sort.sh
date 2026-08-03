#!/bin/bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SORTER="${SORTER_UNDER_TEST:-$ROOT/sort.sh}"
TEST_ROOT=$(mktemp -d /tmp/camera-sorter-parallel.XXXXXX)
export LOCK_ROOT="$TEST_ROOT/data/.sort-locks"
SORTER_PID=""
SECOND_SORTER_PID=""
LOCK_HOLDER_PID=""
TRAFFIC_PID=""
LAST_STOP_ESCALATED=0
TEST_TIMEOUT_SCALE=${TEST_TIMEOUT_SCALE:-3}

# Keep notification-enabled cases hermetic. The sorter sees syntactically valid
# credentials, while this exported Bash function replaces Telegram's external
# HTTP boundary in every child sorter process.
curl() {
  local arg is_batch=1 marker
  if [[ -n "${TEST_CURL_ARGS_LOG:-}" ]]; then
    printf '%s\n' "$@" >> "$TEST_CURL_ARGS_LOG"
  fi
  for arg in "$@"; do
    case "$arg" in
      *'camera-sorter online'*) is_batch=0 ;;
    esac
  done
  if (( is_batch )) && [[ -n "${TEST_TELEGRAM_GATE_DIR:-}" ]]; then
    mkdir -p -- "$TEST_TELEGRAM_GATE_DIR"
    marker="$TEST_TELEGRAM_GATE_DIR/send.$BASHPID"
    : > "$marker"
    while [[ ! -e "$TEST_TELEGRAM_GATE_DIR/release" ]]; do
      /bin/sleep 0.05
    done
  fi
  printf '{}\n200\n'
}
export -f curl

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

cleanup() {
  stop_traffic
  stop_sorter
  stop_lock_holder
  case "$TEST_ROOT" in
    /tmp/camera-sorter-parallel.*) rm -rf "$TEST_ROOT" ;;
  esac
}
trap cleanup EXIT

printf '{"bot_token":"test-token","chat_id":-1001234567890}\n' \
  > "$TEST_ROOT/telegram.json"
: > "$TEST_ROOT/curl-args.log"
export TEST_CURL_ARGS_LOG="$TEST_ROOT/curl-args.log"

stop_pid_bounded() {
  local pid=$1 deadline state
  LAST_STOP_ESCALATED=0
  [[ "$pid" =~ ^[0-9]+$ ]] && (( pid > 1 )) || return 0
  if kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null || true
    deadline=$((SECONDS + 10))
    while kill -0 "$pid" 2>/dev/null && (( SECONDS < deadline )); do
      state=$(awk '{print $3}' "/proc/$pid/stat" 2>/dev/null || echo missing)
      [[ "$state" == "Z" || "$state" == "missing" ]] && break
      /bin/sleep 0.1
    done
    state=$(awk '{print $3}' "/proc/$pid/stat" 2>/dev/null || echo missing)
    if [[ "$state" != "Z" && "$state" != "missing" ]]; then
      LAST_STOP_ESCALATED=1
      kill -KILL "$pid" 2>/dev/null || true
    fi
  fi
  wait "$pid" 2>/dev/null || true
}

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

stop_lock_holder() {
  if [[ -n "$LOCK_HOLDER_PID" ]]; then
    stop_pid_bounded "$LOCK_HOLDER_PID"
  fi
  LOCK_HOLDER_PID=""
}

stop_traffic() {
  if [[ -n "$TRAFFIC_PID" ]]; then
    stop_pid_bounded "$TRAFFIC_PID"
  fi
  TRAFFIC_PID=""
}

fail() {
  echo "FAIL: $*" >&2
  if [[ -f "$TEST_ROOT/sorter.log" ]]; then
    echo "--- sorter log ---" >&2
    tail -80 "$TEST_ROOT/sorter.log" >&2
  fi
  exit 1
}

wait_for_count() {
  local dir=$1 expected=$2 timeout_seconds=$3
  local deadline=$((SECONDS + timeout_seconds * TEST_TIMEOUT_SCALE)) count
  while (( SECONDS < deadline )); do
    count=$(find "$dir" -type f 2>/dev/null | wc -l)
    if (( expected == 0 )); then
      [[ "$count" -eq 0 ]] && return 0
    elif (( count >= expected )); then
      return 0
    fi
    sleep 0.1
  done
  return 1
}

wait_for_log() {
  local pattern=$1 timeout_seconds=$2
  local deadline=$((SECONDS + timeout_seconds * TEST_TIMEOUT_SCALE))
  while (( SECONDS < deadline )); do
    grep -q "$pattern" "$TEST_ROOT/sorter.log" 2>/dev/null && return 0
    sleep 0.1
  done
  return 1
}

wait_for_lines() {
  local file=$1 expected=$2 timeout_seconds=$3
  local deadline=$((SECONDS + timeout_seconds * TEST_TIMEOUT_SCALE)) count
  while (( SECONDS < deadline )); do
    if [[ -f "$file" ]]; then
      count=$(wc -l < "$file")
    else
      count=0
    fi
    (( count >= expected )) && return 0
    sleep 0.1
  done
  return 1
}

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

assert_log_absent_for() {
  local pattern=$1 duration_seconds=$2
  local deadline=$((SECONDS + duration_seconds))
  while (( SECONDS < deadline )); do
    grep -q "$pattern" "$TEST_ROOT/sorter.log" 2>/dev/null && return 1
    sleep 0.1
  done
  return 0
}

wait_for_value_at_least() {
  local file=$1 expected=$2 timeout_seconds=$3 value
  local deadline=$((SECONDS + timeout_seconds * TEST_TIMEOUT_SCALE))
  while (( SECONDS < deadline )); do
    if [[ -f "$file" ]]; then
      value=$(<"$file")
      if [[ "$value" =~ ^[0-9]+$ ]] && (( value >= expected )); then
        return 0
      fi
    fi
    sleep 0.1
  done
  return 1
}

assert_count_below_for() {
  local dir=$1 limit=$2 duration_seconds=$3 count
  local deadline=$((SECONDS + duration_seconds * TEST_TIMEOUT_SCALE))
  while (( SECONDS < deadline )); do
    count=$(find "$dir" -type f 2>/dev/null | wc -l)
    (( count < limit )) || return 1
    sleep 0.1
  done
  return 0
}

list_descendants() {
  local parent=$1 children="" child
  local IFS=$' \t\n'
  [[ -r "/proc/$parent/task/$parent/children" ]] || return 0
  children=$(<"/proc/$parent/task/$parent/children")
  for child in $children; do
    printf '%s\n' "$child"
    list_descendants "$child"
  done
}

assert_pid_stopped() {
  local pid=$1 label=$2 state
  if kill -0 "$pid" 2>/dev/null; then
    state=$(awk '{print $3}' "/proc/$pid/stat" 2>/dev/null || echo missing)
    [[ "$state" == "Z" || "$state" == "missing" ]] \
      || fail "shutdown left $label $pid running (state=$state)"
  fi
}

wait_for_claim_release() {
  local path=$1 lock_root=$2 timeout_seconds=$3 key claim_path claim_fd
  key=$(printf '%s' "$path" | sha256sum | cut -c1-2) || return 1
  claim_path="$lock_root/process/$key.lock"
  [[ -f "$claim_path" && ! -L "$claim_path" ]] || return 1
  exec {claim_fd}>>"$claim_path" || return 1
  if ! flock -w "$((timeout_seconds * TEST_TIMEOUT_SCALE))" -x "$claim_fd"; then
    exec {claim_fd}>&-
    return 1
  fi
  flock -u "$claim_fd"
  exec {claim_fd}>&-
}

# These values feed sleep, timeout, find, and Bash arithmetic. Every one must
# be a strictly-positive decimal integer: accepting zero can create busy loops,
# while accepting arithmetic expressions lets configuration become code.
for numeric_knob in \
  STABLE_WAIT STABLE_SKIP_AGE NOTIFY_INTERVAL RAW_VALIDATE_TIMEOUT STUCK_AGE_MIN; do
  for invalid_value in 0 01 '1+1'; do
    rm -rf "$TEST_ROOT/data"
    mkdir -p "$TEST_ROOT/data/incoming"
    : > "$TEST_ROOT/sorter.log"

    set +e
    env \
      INCOMING="$TEST_ROOT/data/incoming" \
      SORTED="$TEST_ROOT/data/sorted" \
      QUARANTINE="$TEST_ROOT/data/quarantine" \
      LOCK_ROOT="$TEST_ROOT/data/.sort-locks" \
      STABLE_WAIT=1 \
      STABLE_SKIP_AGE=1 \
      SORT_WORKERS=1 \
      RECONCILE_IDLE=30 \
      NOTIFY_INTERVAL=3600 \
      RAW_VALIDATE_TIMEOUT=60 \
      STUCK_AGE_MIN=60 \
      RAW_FULL_VALIDATE=0 \
      TG_CONFIG="$TEST_ROOT/telegram.json" \
      "$numeric_knob=$invalid_value" \
      timeout -k 1 5 /bin/bash "$SORTER" > "$TEST_ROOT/sorter.log" 2>&1
    sorter_rc=$?
    set -e

    [[ "$sorter_rc" -eq 2 ]] \
      || fail "$numeric_knob=$invalid_value exited $sorter_rc instead of rejecting configuration"
    grep -q "invalid $numeric_knob='$invalid_value'" "$TEST_ROOT/sorter.log" \
      || fail "$numeric_knob=$invalid_value was rejected without the expected explanation"
  done
done

echo "PASS: timing and age knobs rejected unsafe numeric forms"

for invalid_config in \
  'RAW_FULL_VALIDATE=tru' \
  'SORT_WORKERS=257' \
  'RAW_VALIDATE_TMP_STALE_MIN=1' \
  'STABLE_WAIT=999999999999999999999'; do
  rm -rf "$TEST_ROOT/data"
  mkdir -p "$TEST_ROOT/data/incoming"
  : > "$TEST_ROOT/sorter.log"
  config_name=${invalid_config%%=*}
  config_value=${invalid_config#*=}

  set +e
  env \
    INCOMING="$TEST_ROOT/data/incoming" \
    SORTED="$TEST_ROOT/data/sorted" \
    QUARANTINE="$TEST_ROOT/data/quarantine" \
    LOCK_ROOT="$TEST_ROOT/data/.sort-locks" \
    STABLE_WAIT=1 \
    STABLE_SKIP_AGE=1 \
    SORT_WORKERS=1 \
    RECONCILE_IDLE=30 \
    NOTIFY_INTERVAL=3600 \
    RAW_VALIDATE_TIMEOUT=60 \
    STUCK_AGE_MIN=60 \
    RAW_FULL_VALIDATE=0 \
    TG_CONFIG="$TEST_ROOT/telegram.json" \
    "$invalid_config" \
    timeout -k 1 5 /bin/bash "$SORTER" > "$TEST_ROOT/sorter.log" 2>&1
  sorter_rc=$?
  set -e

  [[ "$sorter_rc" -eq 2 ]] \
    || fail "$invalid_config exited $sorter_rc instead of rejecting configuration"
  grep -q "invalid $config_name='$config_value'" "$TEST_ROOT/sorter.log" \
    || fail "$invalid_config was rejected without the expected explanation"
done

echo "PASS: RAW safety toggle and bounded numeric configuration failed closed"

rm -rf "$TEST_ROOT/data"
mkdir -p "$TEST_ROOT/data/incoming/private-raw-tmp"
chmod 0700 "$TEST_ROOT/data/incoming/private-raw-tmp"
printf 'RAW TMP SENTINEL — KEEP\n' \
  > "$TEST_ROOT/data/incoming/private-raw-tmp/sentinel"
: > "$TEST_ROOT/sorter.log"

set +e
INCOMING="$TEST_ROOT/data/incoming" \
SORTED="$TEST_ROOT/data/sorted" \
QUARANTINE="$TEST_ROOT/data/quarantine" \
LOCK_ROOT="$TEST_ROOT/data/.sort-locks" \
RAW_VALIDATE_TMPDIR="$TEST_ROOT/data/incoming/private-raw-tmp" \
STABLE_WAIT=1 \
STABLE_SKIP_AGE=1 \
SORT_WORKERS=1 \
RECONCILE_IDLE=30 \
NOTIFY_INTERVAL=3600 \
RAW_FULL_VALIDATE=0 \
TG_CONFIG="$TEST_ROOT/telegram.json" \
  timeout -k 1 10 /bin/bash "$SORTER" > "$TEST_ROOT/sorter.log" 2>&1
sorter_rc=$?
set -e

[[ "$sorter_rc" -eq 2 ]] \
  || fail "RAW temp under incoming exited $sorter_rc instead of rejecting configuration"
[[ "$(cat "$TEST_ROOT/data/incoming/private-raw-tmp/sentinel")" == "RAW TMP SENTINEL — KEEP" ]] \
  || fail "RAW temp under incoming modified its sentinel"
[[ "$(stat -c %a "$TEST_ROOT/data/incoming/private-raw-tmp")" == 700 ]] \
  || fail "RAW temp under incoming changed its directory mode"
[[ ! -e "$TEST_ROOT/data/.sort-locks" ]] \
  || fail "RAW temp lexical rejection created lock storage before failing"
grep -q 'must be a strict descendant of LOCK_ROOT' "$TEST_ROOT/sorter.log" \
  || fail "RAW temp under incoming was rejected without the containment explanation"

echo "PASS: RAW validation temp outside LOCK_ROOT was rejected before touching data"

# A camera/SMB process can enter or open a new directory just before its first
# file is created. Removing that apparently-empty directory unlinks the active
# upload location. Reconciliation must leave even empty incoming directories
# alone; stale empty folders are harmless and can be cleaned administratively.
stop_sorter
rm -rf "$TEST_ROOT/data"
rm -f "$TEST_ROOT/held-dir-ready" "$TEST_ROOT/held-dir-release"
mkdir -p "$TEST_ROOT/data/incoming/held-open-upload"
(
  cd "$TEST_ROOT/data/incoming/held-open-upload"
  : > "$TEST_ROOT/held-dir-ready"
  while [[ ! -e "$TEST_ROOT/held-dir-release" ]]; do
    /bin/sleep 0.05
  done
  printf 'arrived after held directory reconcile\n' > held-open-camera.dat
) &
TRAFFIC_PID=$!
held_deadline=$((SECONDS + 10 * TEST_TIMEOUT_SCALE))
while (( SECONDS < held_deadline )); do
  [[ -e "$TEST_ROOT/held-dir-ready" ]] && break
  /bin/sleep 0.05
done
[[ -e "$TEST_ROOT/held-dir-ready" ]] \
  || fail "held-directory writer did not enter its incoming directory"
: > "$TEST_ROOT/sorter.log"

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

wait_for_log_count 'reconcile scan' 3 20 \
  || fail "held-directory test did not exercise repeated reconciliation"
[[ -d "$TEST_ROOT/data/incoming/held-open-upload" ]] \
  || fail "reconciliation removed a held-open empty incoming directory"
: > "$TEST_ROOT/held-dir-release"
if ! wait "$TRAFFIC_PID"; then
  TRAFFIC_PID=""
  fail "writer could not create a file in its held incoming directory"
fi
TRAFFIC_PID=""
wait_for_count "$TEST_ROOT/data/sorted" 1 30 \
  || fail "file created after held-directory reconcile did not remain reachable"
[[ -d "$TEST_ROOT/data/incoming/held-open-upload" ]] \
  || fail "sorter removed the held incoming directory after processing"

echo "PASS: reconciliation preserved a held-open incoming upload directory"

# Two instances may cold-start together after an orchestrator restart. Their
# private directories and zero-length lock/queue files must appear with final
# permissions atomically; neither instance may reject a harmless mkdir/create
# race, and shared claims must still make every upload exactly-once.
rm -rf "$TEST_ROOT/data"
mkdir -p "$TEST_ROOT/data/incoming"
for n in $(seq 1 8); do
  printf 'dual sorter payload %s\n' "$n" \
    > "$TEST_ROOT/data/incoming/dual-sorter-$n.dat"
done
touch -d '2 minutes ago' "$TEST_ROOT/data/incoming/"*.dat
: > "$TEST_ROOT/sorter-a.log"
: > "$TEST_ROOT/sorter-b.log"

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
  /bin/bash "$SORTER" > "$TEST_ROOT/sorter-a.log" 2>&1 &
SORTER_PID=$!
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
  /bin/bash "$SORTER" > "$TEST_ROOT/sorter-b.log" 2>&1 &
SECOND_SORTER_PID=$!

wait_for_count "$TEST_ROOT/data/sorted" 8 45 \
  || fail "two cold-started sorters did not drain the shared incoming tree"
wait_for_lines "$TEST_ROOT/data/.sort-locks/queues/notify-queue.tsv" 8 45 \
  || fail "two cold-started sorters lost a shared notification row"
dual_deadline=$((SECONDS + 30 * TEST_TIMEOUT_SCALE))
while (( SECONDS < dual_deadline )); do
  grep -q 'watching ' "$TEST_ROOT/sorter-a.log" 2>/dev/null \
    && grep -q 'watching ' "$TEST_ROOT/sorter-b.log" 2>/dev/null \
    && break
  /bin/sleep 0.1
done
grep -q 'watching ' "$TEST_ROOT/sorter-a.log" \
  || fail "first cold-started sorter did not become ready"
grep -q 'watching ' "$TEST_ROOT/sorter-b.log" \
  || fail "second cold-started sorter did not become ready"
kill -0 "$SORTER_PID" 2>/dev/null \
  || fail "first cold-started sorter exited during shared processing"
kill -0 "$SECOND_SORTER_PID" 2>/dev/null \
  || fail "second cold-started sorter exited during shared processing"
[[ $(find "$TEST_ROOT/data/sorted" -type f | wc -l) -eq 8 ]] \
  || fail "two cold-started sorters produced duplicate output files"
[[ $(wc -l < "$TEST_ROOT/data/.sort-locks/queues/notify-queue.tsv") -eq 8 ]] \
  || fail "two cold-started sorters produced duplicate notification rows"
grep -qx 'chat_id=-1001234567890' "$TEST_ROOT/curl-args.log" \
  || fail "numeric Telegram chat_id was not enabled and stringified for curl"

echo "PASS: two sorters cold-started and shared claims/state safely"

stop_sorter

# Missing, partial, JSON-null, boolean, and object credentials all mean
# notifications are disabled. The suite's default numeric chat_id proves that
# Telegram's documented numeric form remains enabled and is stringified.
printf '{"bot_token":"test-token"}\n' > "$TEST_ROOT/telegram-partial.json"
printf '{"bot_token":null,"chat_id":null}\n' > "$TEST_ROOT/telegram-null.json"
printf '{"bot_token":"test-token","chat_id":true}\n' > "$TEST_ROOT/telegram-bool.json"
printf '{"bot_token":"test-token","chat_id":{"id":123}}\n' > "$TEST_ROOT/telegram-object.json"
for disabled_config in \
  "$TEST_ROOT/missing-telegram.json" \
  "$TEST_ROOT/telegram-partial.json" \
  "$TEST_ROOT/telegram-null.json" \
  "$TEST_ROOT/telegram-bool.json" \
  "$TEST_ROOT/telegram-object.json"; do
  rm -rf "$TEST_ROOT/data"
  mkdir -p "$TEST_ROOT/data/incoming"
  printf 'valid payload\n' > "$TEST_ROOT/data/incoming/notify-disabled.dat"
  printf 'tiny invalid jpeg\n' > "$TEST_ROOT/data/incoming/quarantine-disabled.jpg"
  printf 'unreadable payload\n' > "$TEST_ROOT/data/incoming/permission-disabled.dat"
  chmod 000 "$TEST_ROOT/data/incoming/permission-disabled.dat"
  touch -d '2 minutes ago' "$TEST_ROOT/data/incoming/"*
  : > "$TEST_ROOT/sorter.log"

  PATH="$ROOT/tests/fixtures/fast-metadata:$PATH" \
  INCOMING="$TEST_ROOT/data/incoming" \
  SORTED="$TEST_ROOT/data/sorted" \
  QUARANTINE="$TEST_ROOT/data/quarantine" \
  STABLE_WAIT=1 \
  STABLE_SKIP_AGE=1 \
  SORT_WORKERS=3 \
  RECONCILE_IDLE=30 \
  NOTIFY_INTERVAL=37 \
  RAW_FULL_VALIDATE=0 \
  TG_CONFIG="$disabled_config" \
    /bin/bash "$SORTER" > "$TEST_ROOT/sorter.log" 2>&1 &
  SORTER_PID=$!

  wait_for_log 'watching ' 30 \
    || fail "notification-disabled sorter did not start for $disabled_config"
  [[ $(find "$TEST_ROOT/data/sorted" -type f -name notify-disabled.dat | wc -l) -eq 1 ]] \
    || fail "notification-disabled valid file did not sort for $disabled_config"
  [[ $(find "$TEST_ROOT/data/quarantine" -type f -name quarantine-disabled.jpg | wc -l) -eq 1 ]] \
    || fail "notification-disabled invalid file was not quarantined for $disabled_config"
  [[ -f "$TEST_ROOT/data/incoming/permission-disabled.dat" ]] \
    || fail "notification-disabled unreadable file did not remain incoming for $disabled_config"
  for disabled_queue in notify-queue.tsv quarantine-queue.tsv perm-queue.tsv; do
    [[ ! -s "$TEST_ROOT/data/.sort-locks/queues/$disabled_queue" ]] \
      || fail "notification-disabled run appended $disabled_queue for $disabled_config"
  done
  /bin/sleep 1
  notifier_child=""
  while IFS= read -r descendant; do
    descendant_cmd=$(tr '\0' ' ' < "/proc/$descendant/cmdline" 2>/dev/null || true)
    if [[ "$descendant_cmd" == *'sleep 37'* ]]; then
      notifier_child=$descendant
      break
    fi
  done < <(list_descendants "$SORTER_PID")
  [[ -z "$notifier_child" ]] \
    || fail "notification-disabled sorter started notifier child $notifier_child for $disabled_config"
  grep -q 'notifications disabled' "$TEST_ROOT/sorter.log" \
    || fail "notification-disabled sorter did not report disabled state for $disabled_config"
  grep -q "repair only this idle file and required ancestor directories to $(id -u):$(id -g)" "$TEST_ROOT/sorter.log" \
    || fail "unreadable-file guidance did not use the sorter's runtime UID/GID"
  stop_sorter
done

echo "PASS: absent, partial, null, boolean, and object Telegram credentials stayed disabled"

stop_sorter
rm -rf "$TEST_ROOT/data"
mkdir -p "$TEST_ROOT/data/incoming"
printf 'leading dash permission payload\n' \
  > "$TEST_ROOT/data/incoming/--permission-leading.dat"
chmod 000 "$TEST_ROOT/data/incoming/--permission-leading.dat"
touch -d '2 minutes ago' "$TEST_ROOT/data/incoming/--permission-leading.dat"
: > "$TEST_ROOT/sorter.log"

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

echo "PASS: leading-dash unreadable filename was safely deduplicated"

stop_sorter
rm -rf "$TEST_ROOT/data"
mkdir -p "$TEST_ROOT/data/incoming"
printf 'valid lock failure payload\n' \
  > "$TEST_ROOT/data/incoming/flock-notify.dat"
printf 'invalid lock failure jpeg\n' \
  > "$TEST_ROOT/data/incoming/flock-quarantine.jpg"
printf 'unreadable lock failure payload\n' \
  > "$TEST_ROOT/data/incoming/flock-permission.dat"
chmod 000 "$TEST_ROOT/data/incoming/flock-permission.dat"
touch -d '2 minutes ago' "$TEST_ROOT/data/incoming/"*
: > "$TEST_ROOT/failed-notify-flock.log"
: > "$TEST_ROOT/sorter.log"

PATH="$ROOT/tests/fixtures/failed-notify-flock:$ROOT/tests/fixtures/fast-metadata:$PATH" \
TEST_FAIL_NOTIFY_FLOCK=1 \
TEST_FAILED_FLOCK_LOG="$TEST_ROOT/failed-notify-flock.log" \
INCOMING="$TEST_ROOT/data/incoming" \
SORTED="$TEST_ROOT/data/sorted" \
QUARANTINE="$TEST_ROOT/data/quarantine" \
STABLE_WAIT=1 \
STABLE_SKIP_AGE=1 \
SORT_WORKERS=3 \
RECONCILE_IDLE=30 \
NOTIFY_INTERVAL=3600 \
RAW_FULL_VALIDATE=0 \
TG_CONFIG="$TEST_ROOT/telegram.json" \
  /bin/bash "$SORTER" > "$TEST_ROOT/sorter.log" 2>&1 &
SORTER_PID=$!

wait_for_count "$TEST_ROOT/data/sorted" 1 30 \
  || fail "notification-lock failure valid fixture did not finish sorting"
wait_for_count "$TEST_ROOT/data/quarantine" 1 30 \
  || fail "notification-lock failure invalid fixture did not finish quarantine"
wait_for_log 'cannot lock permission notification queue' 30 \
  || fail "permission enqueue did not report its lock failure"
wait_for_log 'cannot lock upload notification queue' 30 \
  || fail "upload enqueue did not report its lock failure"
wait_for_log 'cannot lock quarantine notification queue' 30 \
  || fail "quarantine enqueue did not report its lock failure"
for failed_queue in notify-queue.tsv quarantine-queue.tsv perm-queue.tsv; do
  [[ ! -s "$TEST_ROOT/data/.sort-locks/queues/$failed_queue" ]] \
    || fail "enqueue wrote $failed_queue without its notification lock"
done
[[ $(wc -l < "$TEST_ROOT/failed-notify-flock.log") -ge 3 ]] \
  || fail "failed-flock fixture did not exercise all three enqueue paths"

echo "PASS: all notification enqueues failed closed when flock failed"

stop_sorter
rm -rf "$TEST_ROOT/data"
mkdir -p "$TEST_ROOT/data/incoming"
printf 'permission guidance payload\n' \
  > "$TEST_ROOT/data/incoming/permission-guidance.dat"
chmod 000 "$TEST_ROOT/data/incoming/permission-guidance.dat"
touch -d '2 minutes ago' "$TEST_ROOT/data/incoming/permission-guidance.dat"
: > "$TEST_ROOT/curl-args.log"
: > "$TEST_ROOT/sorter.log"

PATH="$ROOT/tests/fixtures/fast-metadata:$PATH" \
INCOMING="$TEST_ROOT/data/incoming" \
SORTED="$TEST_ROOT/data/sorted" \
QUARANTINE="$TEST_ROOT/data/quarantine" \
STABLE_WAIT=1 \
STABLE_SKIP_AGE=1 \
SORT_WORKERS=1 \
RECONCILE_IDLE=30 \
NOTIFY_INTERVAL=1 \
RAW_FULL_VALIDATE=0 \
TG_CONFIG="$TEST_ROOT/telegram.json" \
  /bin/bash "$SORTER" > "$TEST_ROOT/sorter.log" 2>&1 &
SORTER_PID=$!

guidance_deadline=$((SECONDS + 30 * TEST_TIMEOUT_SCALE))
while (( SECONDS < guidance_deadline )); do
  grep -q '/boot/config/scripts/ftpdropbox-fixperms.sh' \
    "$TEST_ROOT/curl-args.log" 2>/dev/null && break
  /bin/sleep 0.1
done
grep -q '/boot/config/scripts/ftpdropbox-fixperms.sh' "$TEST_ROOT/curl-args.log" \
  || fail "permission alert did not point to the idle-file root helper"
grep -q "only idle files and required ancestor directories to $(id -u):$(id -g)" \
  "$TEST_ROOT/curl-args.log" \
  || fail "permission alert did not retain runtime UID/GID guidance"
! grep -q 'chown -R' "$TEST_ROOT/curl-args.log" \
  || fail "permission alert suggested recursive ownership changes during uploads"
[[ -f "$TEST_ROOT/data/incoming/permission-guidance.dat" ]] \
  || fail "permission-guidance file did not remain in incoming"

echo "PASS: permission alert recommended only the idle-file repair helper"

stop_sorter
rm -rf "$TEST_ROOT/data" "$TEST_ROOT/telegram-gate"
mkdir -p "$TEST_ROOT/data/incoming" "$TEST_ROOT/telegram-gate"
: > "$TEST_ROOT/sorter-a.log"
: > "$TEST_ROOT/sorter-b.log"

TEST_TELEGRAM_GATE_DIR="$TEST_ROOT/telegram-gate" \
INCOMING="$TEST_ROOT/data/incoming" \
SORTED="$TEST_ROOT/data/sorted" \
QUARANTINE="$TEST_ROOT/data/quarantine" \
STABLE_WAIT=1 \
STABLE_SKIP_AGE=1 \
SORT_WORKERS=1 \
RECONCILE_IDLE=30 \
NOTIFY_INTERVAL=1 \
RAW_FULL_VALIDATE=0 \
TG_CONFIG="$TEST_ROOT/telegram.json" \
  /bin/bash "$SORTER" > "$TEST_ROOT/sorter-a.log" 2>&1 &
SORTER_PID=$!

dual_deadline=$((SECONDS + 30 * TEST_TIMEOUT_SCALE))
while (( SECONDS < dual_deadline )); do
  grep -q 'watching ' "$TEST_ROOT/sorter-a.log" 2>/dev/null && break
  /bin/sleep 0.1
done
grep -q 'watching ' "$TEST_ROOT/sorter-a.log" \
  || fail "flush-lifecycle first sorter did not become ready"
{
  flock -x 200
  printf '01:02:03\tLifecycle Camera\traw\tonce.arw\n' \
    >> "$TEST_ROOT/data/.sort-locks/queues/notify-queue.tsv"
} 200>>"$TEST_ROOT/data/.sort-locks/notify.lock"
wait_for_count "$TEST_ROOT/telegram-gate" 1 20 \
  || fail "flush-lifecycle first sorter did not enter its gated send"
[[ $(find "$TEST_ROOT/data/.sort-locks/queues" -maxdepth 1 \
  -name '.notify.pending.*' -type f | wc -l) -eq 1 ]] \
  || fail "flush-lifecycle send did not retain exactly one in-flight snapshot"

# A second sorter starting during the send must block before snapshot recovery.
# Without a lifecycle lock it requeues the sender's in-flight snapshot and the
# same row is delivered again after the first sender deletes/restores it.
TEST_TELEGRAM_GATE_DIR="$TEST_ROOT/telegram-gate" \
INCOMING="$TEST_ROOT/data/incoming" \
SORTED="$TEST_ROOT/data/sorted" \
QUARANTINE="$TEST_ROOT/data/quarantine" \
STABLE_WAIT=1 \
STABLE_SKIP_AGE=1 \
SORT_WORKERS=1 \
RECONCILE_IDLE=30 \
NOTIFY_INTERVAL=1 \
RAW_FULL_VALIDATE=0 \
TG_CONFIG="$TEST_ROOT/telegram.json" \
  /bin/bash "$SORTER" > "$TEST_ROOT/sorter-b.log" 2>&1 &
SECOND_SORTER_PID=$!

/bin/sleep 10
kill -0 "$SECOND_SORTER_PID" 2>/dev/null \
  || fail "flush-lifecycle second sorter exited while waiting for the lease"
! grep -q 'watching ' "$TEST_ROOT/sorter-b.log" \
  || fail "second sorter recovered an in-flight snapshot before send completion"
: > "$TEST_ROOT/telegram-gate/release"

dual_deadline=$((SECONDS + 30 * TEST_TIMEOUT_SCALE))
while (( SECONDS < dual_deadline )); do
  grep -q 'watching ' "$TEST_ROOT/sorter-b.log" 2>/dev/null && break
  /bin/sleep 0.1
done
grep -q 'watching ' "$TEST_ROOT/sorter-b.log" \
  || fail "flush-lifecycle second sorter did not resume after send completion"
/bin/sleep 2
[[ $(find "$TEST_ROOT/telegram-gate" -maxdepth 1 -name 'send.*' -type f | wc -l) -eq 1 ]] \
  || fail "one notification batch was sent more than once"
[[ ! -s "$TEST_ROOT/data/.sort-locks/queues/notify-queue.tsv" ]] \
  || fail "flush-lifecycle left a successfully sent row queued"
if find "$TEST_ROOT/data/.sort-locks/queues" -maxdepth 1 \
  -name '.*.pending.*' -print -quit | grep -q .; then
  fail "flush-lifecycle left a completed snapshot behind"
fi
! grep -q 'recovered interrupted notify notification batch' "$TEST_ROOT/sorter-b.log" \
  || fail "second sorter recovered an active sender's snapshot"

echo "PASS: shared flush lifecycle prevented recovery and duplicate send of an in-flight snapshot"

stop_sorter
rm -rf "$TEST_ROOT/data"
mkdir -p "$TEST_ROOT/data/incoming" "$TEST_ROOT/parallel-sleep-state"
for n in 1 2 3 4; do
  printf 'parallel fixture %s\n' "$n" > "$TEST_ROOT/data/incoming/photo-$n.txt"
done

started=$SECONDS
PATH="$ROOT/tests/fixtures/fast-metadata:$ROOT/tests/fixtures/bin:$PATH" \
TEST_SLEEP_STATE_DIR="$TEST_ROOT/parallel-sleep-state" \
TEST_SLEEP_RELEASE_FILE="$TEST_ROOT/parallel-sleep-release" \
TEST_STABLE_WAIT=2 \
INCOMING="$TEST_ROOT/data/incoming" \
SORTED="$TEST_ROOT/data/sorted" \
QUARANTINE="$TEST_ROOT/data/quarantine" \
STABLE_WAIT=2 \
STABLE_SKIP_AGE=3600 \
SORT_WORKERS=4 \
RECONCILE_IDLE=30 \
NOTIFY_INTERVAL=3600 \
RAW_FULL_VALIDATE=0 \
TG_CONFIG="$TEST_ROOT/telegram.json" \
  /bin/bash "$SORTER" > "$TEST_ROOT/sorter.log" 2>&1 &
SORTER_PID=$!

wait_for_value_at_least "$TEST_ROOT/parallel-sleep-state/max" 4 20 \
  || fail "four workers never entered the stability check concurrently"
: > "$TEST_ROOT/parallel-sleep-release"
wait_for_count "$TEST_ROOT/data/sorted" 4 30 || fail "four-file batch did not sort"
elapsed=$((SECONDS - started))
wait_for_lines "$TEST_ROOT/data/.sort-locks/queues/notify-queue.tsv" 4 30 || fail "parallel notification queue lost a row"

peak_workers=$(<"$TEST_ROOT/parallel-sleep-state/max")
[[ "$peak_workers" -eq 4 ]] \
  || fail "four-worker batch observed peak concurrency $peak_workers"
[[ $(find "$TEST_ROOT/data/sorted" -type f | wc -l) -eq 4 ]] \
  || fail "four-file batch produced an unexpected output count"
[[ $(wc -l < "$TEST_ROOT/data/.sort-locks/queues/notify-queue.tsv") -eq 4 ]] \
  || fail "parallel notification queue produced an unexpected row count"
[[ $(find "$TEST_ROOT/data/incoming" -type f | wc -l) -eq 0 ]] || fail "incoming was not drained"

echo "PASS: four fresh files sorted in ${elapsed}s with SORT_WORKERS=4"

stop_sorter
rm -rf "$TEST_ROOT/data"
mkdir -p "$TEST_ROOT/data/incoming"
write_valid_heif "$TEST_ROOT/data/incoming/valid-camera.heic"
write_valid_heif "$TEST_ROOT/data/incoming/valid-camera.heif"
write_truncated_heif "$TEST_ROOT/data/incoming/truncated-camera.heic"
write_truncated_heif "$TEST_ROOT/data/incoming/truncated-camera.heif"
valid_heic_hash=$(sha256sum "$TEST_ROOT/data/incoming/valid-camera.heic" | cut -d' ' -f1)
valid_heif_hash=$(sha256sum "$TEST_ROOT/data/incoming/valid-camera.heif" | cut -d' ' -f1)
truncated_heic_hash=$(sha256sum "$TEST_ROOT/data/incoming/truncated-camera.heic" | cut -d' ' -f1)
truncated_heif_hash=$(sha256sum "$TEST_ROOT/data/incoming/truncated-camera.heif" | cut -d' ' -f1)
touch -d '2 minutes ago' "$TEST_ROOT/data/incoming/"*
: > "$TEST_ROOT/sorter.log"

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

echo "PASS: HEIC and HEIF used bounded ISO-BMFF validation"

stop_sorter
rm -rf "$TEST_ROOT/data"
mkdir -p "$TEST_ROOT/data/incoming"
control_name=$'camera\nFORGED-LINE\r\e[31m.dat'
printf 'control filename payload\n' \
  > "$TEST_ROOT/data/incoming/$control_name"
touch -d '2 minutes ago' "$TEST_ROOT/data/incoming/$control_name"
: > "$TEST_ROOT/sorter.log"

PATH="$ROOT/tests/fixtures/fast-metadata:$PATH" \
INCOMING="$TEST_ROOT/data/incoming" \
SORTED="$TEST_ROOT/data/sorted" \
QUARANTINE="$TEST_ROOT/data/quarantine" \
STABLE_WAIT=1 \
STABLE_SKIP_AGE=1 \
SORT_WORKERS=1 \
RECONCILE_IDLE=30 \
NOTIFY_INTERVAL=3600 \
RAW_FULL_VALIDATE=0 \
TG_CONFIG="$TEST_ROOT/telegram.json" \
  /bin/bash "$SORTER" > "$TEST_ROOT/sorter.log" 2>&1 &
SORTER_PID=$!

wait_for_count "$TEST_ROOT/data/sorted" 1 30 \
  || fail "control-character filename did not sort"
wait_for_log 'FORGED-LINE' 30 \
  || fail "control-character filename did not reach its escaped success log"
mapfile -d '' -t control_outputs \
  < <(find "$TEST_ROOT/data/sorted" -type f -print0)
[[ ${#control_outputs[@]} -eq 1 \
  && ${control_outputs[0]##*/} == "$control_name" ]] \
  || fail "control-character filename was not preserved as an operand"
[[ $(grep -c 'FORGED-LINE' "$TEST_ROOT/sorter.log") -eq 1 ]] \
  || fail "control-character filename forged additional log lines"
! grep -q '^FORGED-LINE' "$TEST_ROOT/sorter.log" \
  || fail "newline in filename forged a standalone log record"
if LC_ALL=C grep -q "$(printf '[\r\033]')" "$TEST_ROOT/sorter.log"; then
  fail "filename emitted raw CR/ESC terminal controls into logs"
fi
grep -Fq '\n' "$TEST_ROOT/sorter.log" \
  || fail "filename newline was not visibly escaped in its log record"
grep -Fq '\r' "$TEST_ROOT/sorter.log" \
  || fail "filename carriage return was not visibly escaped in its log record"
grep -Eq '\\(E|033)' "$TEST_ROOT/sorter.log" \
  || fail "filename escape byte was not visibly escaped in its log record"

echo "PASS: control-character filename stayed a one-line escaped log field"

stop_sorter
rm -rf "$TEST_ROOT/data"
mkdir -p "$TEST_ROOT/data/incoming" "$TEST_ROOT/validator-state"
for n in 1 2 3 4; do
  printf 'raw validation fixture %s\n' "$n" > "$TEST_ROOT/data/incoming/validation-$n.dng"
done
touch -d '2 minutes ago' "$TEST_ROOT/data/incoming"/*.dng
: > "$TEST_ROOT/sorter.log"

PATH="$ROOT/tests/fixtures/concurrent-validator:$PATH" \
TEST_VALIDATOR_STATE_DIR="$TEST_ROOT/validator-state" \
TEST_VALIDATOR_RELEASE_FILE="$TEST_ROOT/validator-release" \
INCOMING="$TEST_ROOT/data/incoming" \
SORTED="$TEST_ROOT/data/sorted" \
QUARANTINE="$TEST_ROOT/data/quarantine" \
STABLE_WAIT=1 \
STABLE_SKIP_AGE=1 \
SORT_WORKERS=4 \
RECONCILE_IDLE=30 \
NOTIFY_INTERVAL=3600 \
RAW_MIN_BYTES_DEFAULT=1 \
RAW_VALIDATE_TIMEOUT=60 \
RAW_FULL_VALIDATE=1 \
TG_CONFIG="$TEST_ROOT/telegram.json" \
  /bin/bash "$SORTER" > "$TEST_ROOT/sorter.log" 2>&1 &
SORTER_PID=$!

wait_for_count "$TEST_ROOT/validator-state" 4 30 \
  || fail "four RAW validators never reached the decode gate concurrently"
: > "$TEST_ROOT/validator-release"
wait_for_count "$TEST_ROOT/data/sorted" 4 90 \
  || fail "concurrent RAW validation batch did not sort"
wait_for_lines "$TEST_ROOT/data/.sort-locks/queues/notify-queue.tsv" 4 90 \
  || fail "concurrent RAW validation notification queue lost a row"
[[ $(find "$TEST_ROOT/data/sorted" -type f | wc -l) -eq 4 ]] \
  || fail "concurrent RAW validation produced an unexpected output count"
[[ $(wc -l < "$TEST_ROOT/data/.sort-locks/queues/notify-queue.tsv") -eq 4 ]] \
  || fail "concurrent RAW validation produced an unexpected notification count"

echo "PASS: four CPU-heavy RAW validators ran concurrently"

stop_sorter
rm -rf "$TEST_ROOT/data"
mkdir -p "$TEST_ROOT/data/incoming" "$TEST_ROOT/bounded-validator-state"
for n in $(seq 1 9); do
  printf 'bounded raw validation fixture %s\n' "$n" \
    > "$TEST_ROOT/data/incoming/bounded-validation-$n.dng"
done
touch -d '2 minutes ago' "$TEST_ROOT/data/incoming"/*.dng
: > "$TEST_ROOT/sorter.log"

PATH="$ROOT/tests/fixtures/concurrent-validator:$PATH" \
TEST_VALIDATOR_STATE_DIR="$TEST_ROOT/bounded-validator-state" \
TEST_VALIDATOR_RELEASE_FILE="$TEST_ROOT/bounded-validator-release" \
INCOMING="$TEST_ROOT/data/incoming" \
SORTED="$TEST_ROOT/data/sorted" \
QUARANTINE="$TEST_ROOT/data/quarantine" \
STABLE_WAIT=1 \
STABLE_SKIP_AGE=1 \
SORT_WORKERS=3 \
RECONCILE_IDLE=30 \
NOTIFY_INTERVAL=3600 \
RAW_MIN_BYTES_DEFAULT=1 \
RAW_VALIDATE_TIMEOUT=60 \
RAW_FULL_VALIDATE=1 \
TG_CONFIG="$TEST_ROOT/telegram.json" \
  /bin/bash "$SORTER" > "$TEST_ROOT/sorter.log" 2>&1 &
SORTER_PID=$!

wait_for_count "$TEST_ROOT/bounded-validator-state" 3 30 \
  || fail "three RAW validators never reached the bounded gate"
assert_count_below_for "$TEST_ROOT/bounded-validator-state" 4 5 \
  || fail "a fourth RAW validator exceeded SORT_WORKERS=3"
: > "$TEST_ROOT/bounded-validator-release"
wait_for_count "$TEST_ROOT/data/sorted" 9 120 \
  || fail "bounded RAW validation batch did not sort"
wait_for_lines "$TEST_ROOT/data/.sort-locks/queues/notify-queue.tsv" 9 120 \
  || fail "bounded RAW validation notification queue lost a row"
[[ $(find "$TEST_ROOT/data/sorted" -type f | wc -l) -eq 9 ]] \
  || fail "bounded RAW validation produced an unexpected output count"
[[ $(wc -l < "$TEST_ROOT/data/.sort-locks/queues/notify-queue.tsv") -eq 9 ]] \
  || fail "bounded RAW validation produced an unexpected notification count"

echo "PASS: CPU-heavy RAW validation respected SORT_WORKERS=3"

stop_sorter
rm -rf "$TEST_ROOT/data"
mkdir -p "$TEST_ROOT/data/incoming" "$TEST_ROOT/move-gate"
: > "$TEST_ROOT/expected-hashes"
for n in 1 2 3 4 5 6 7 8; do
  mkdir -p "$TEST_ROOT/data/incoming/source-$n"
  printf 'collision fixture %02d\n' "$n" > "$TEST_ROOT/data/incoming/source-$n/collision.dat"
  sha256sum "$TEST_ROOT/data/incoming/source-$n/collision.dat" | awk '{print $1}' >> "$TEST_ROOT/expected-hashes"
done
sort -o "$TEST_ROOT/expected-hashes" "$TEST_ROOT/expected-hashes"

PATH="$ROOT/tests/fixtures/fast-metadata:$ROOT/tests/fixtures/bin:$PATH" \
TEST_MV_GATE_DIR="$TEST_ROOT/move-gate" \
INCOMING="$TEST_ROOT/data/incoming" \
SORTED="$TEST_ROOT/data/sorted" \
QUARANTINE="$TEST_ROOT/data/quarantine" \
STABLE_WAIT=1 \
STABLE_SKIP_AGE=3600 \
SORT_WORKERS=8 \
RECONCILE_IDLE=30 \
NOTIFY_INTERVAL=3600 \
RAW_FULL_VALIDATE=0 \
TG_CONFIG="$TEST_ROOT/telegram.json" \
  /bin/bash "$SORTER" > "$TEST_ROOT/sorter.log" 2>&1 &
SORTER_PID=$!

wait_for_count "$TEST_ROOT/data/incoming" 0 90 || fail "same-name inputs did not finish processing"
wait_for_lines "$TEST_ROOT/data/.sort-locks/queues/notify-queue.tsv" 8 90 || fail "same-name notification queue lost a row"
[[ $(wc -l < "$TEST_ROOT/data/.sort-locks/queues/notify-queue.tsv") -eq 8 ]] \
  || fail "same-name notification queue produced an unexpected row count"
output_count=$(find "$TEST_ROOT/data/sorted" -type f | wc -l)
[[ "$output_count" -eq 8 ]] || fail "same-name race preserved $output_count of 8 files"

find "$TEST_ROOT/data/sorted" -type f -exec sha256sum {} + \
  | awk '{print $1}' | sort > "$TEST_ROOT/actual-hashes"
cmp -s "$TEST_ROOT/expected-hashes" "$TEST_ROOT/actual-hashes" \
  || fail "same-name race changed or lost file contents"

echo "PASS: concurrent same-name inputs were all preserved"

stop_sorter
rm -rf "$TEST_ROOT/data"
mkdir -p "$TEST_ROOT/data/incoming"
identical_source="$TEST_ROOT/data/incoming/identical-collision.dat"
printf 'BYTE-IDENTICAL CAMERA PAYLOAD\n' > "$identical_source"
touch -d '2 minutes ago' "$identical_source"
fixture_date=$(stat -c %y "$identical_source" | cut -d' ' -f1)
identical_dir="$TEST_ROOT/data/sorted/$fixture_date/other"
mkdir -p "$identical_dir"
cp -- "$identical_source" "$identical_dir/identical-collision.dat"
: > "$TEST_ROOT/sorter.log"

PATH="$ROOT/tests/fixtures/fast-metadata:$PATH" \
INCOMING="$TEST_ROOT/data/incoming" \
SORTED="$TEST_ROOT/data/sorted" \
QUARANTINE="$TEST_ROOT/data/quarantine" \
STABLE_WAIT=1 \
STABLE_SKIP_AGE=1 \
SORT_WORKERS=1 \
RECONCILE_IDLE=30 \
NOTIFY_INTERVAL=3600 \
RAW_FULL_VALIDATE=0 \
TG_CONFIG="$TEST_ROOT/telegram.json" \
  /bin/bash "$SORTER" > "$TEST_ROOT/sorter.log" 2>&1 &
SORTER_PID=$!

wait_for_count "$TEST_ROOT/data/incoming" 0 30 \
  || fail "byte-identical collision input did not finish processing"
[[ -f "$identical_dir/identical-collision.dat" \
  && -f "$identical_dir/identical-collision_2.dat" ]] \
  || fail "byte-identical collision did not preserve both base and suffix copies"
cmp -s "$identical_dir/identical-collision.dat" \
  "$identical_dir/identical-collision_2.dat" \
  || fail "byte-identical collision changed one of the preserved copies"
[[ "$(cat "$identical_dir/identical-collision.dat")" \
  == "BYTE-IDENTICAL CAMERA PAYLOAD" ]] \
  || fail "byte-identical collision did not preserve the expected payload"
[[ $(find "$TEST_ROOT/data/sorted" -type f | wc -l) -eq 2 ]] \
  || fail "byte-identical collision produced an unexpected output count"

echo "PASS: byte-identical destination collision preserved base and _2 copies"

stop_sorter
for destination_case in leaf_symlink date_symlink; do
  rm -rf "$TEST_ROOT/data"
  mkdir -p "$TEST_ROOT/data/incoming" "$TEST_ROOT/data/sorted"
  source_path="$TEST_ROOT/data/incoming/destination-safety.dat"
  printf 'ONLY CAMERA COPY — KEEP\n' > "$source_path"
  fixture_date=$(stat -c %y "$source_path" | cut -d' ' -f1)
  if [[ "$destination_case" == "leaf_symlink" ]]; then
    mkdir -p "$TEST_ROOT/data/sorted/$fixture_date/other"
    ln -s "$source_path" \
      "$TEST_ROOT/data/sorted/$fixture_date/other/destination-safety.dat"
    expected_destination_log='FAIL unsafe destination symlink'
  else
    ln -s "$TEST_ROOT/data/incoming" "$TEST_ROOT/data/sorted/$fixture_date"
    expected_destination_log='unsafe output directory'
  fi
  : > "$TEST_ROOT/sorter.log"

  PATH="$ROOT/tests/fixtures/fast-metadata:$PATH" \
  INCOMING="$TEST_ROOT/data/incoming" \
  SORTED="$TEST_ROOT/data/sorted" \
  QUARANTINE="$TEST_ROOT/data/quarantine" \
  STABLE_WAIT=1 \
  STABLE_SKIP_AGE=3600 \
  SORT_WORKERS=1 \
  RECONCILE_IDLE=30 \
  NOTIFY_INTERVAL=3600 \
  RAW_FULL_VALIDATE=0 \
  TG_CONFIG="$TEST_ROOT/telegram.json" \
    /bin/bash "$SORTER" > "$TEST_ROOT/sorter.log" 2>&1 &
  SORTER_PID=$!

  wait_for_log "$expected_destination_log" 30 \
    || fail "$destination_case was not rejected"
  [[ "$(cat "$source_path")" == "ONLY CAMERA COPY — KEEP" ]] \
    || fail "$destination_case deleted or modified the only incoming copy"
  stop_sorter
done

rm -rf "$TEST_ROOT/data"
mkdir -p "$TEST_ROOT/data/incoming"
printf 'ROOT SENTINEL — KEEP\n' > "$TEST_ROOT/data/incoming/root-sentinel.dat"
ln -s incoming "$TEST_ROOT/data/sorted"
: > "$TEST_ROOT/sorter.log"

INCOMING="$TEST_ROOT/data/incoming" \
SORTED="$TEST_ROOT/data/sorted" \
QUARANTINE="$TEST_ROOT/data/quarantine" \
STABLE_WAIT=1 \
SORT_WORKERS=1 \
RECONCILE_IDLE=30 \
NOTIFY_INTERVAL=3600 \
RAW_FULL_VALIDATE=0 \
TG_CONFIG="$TEST_ROOT/telegram.json" \
  /bin/bash "$SORTER" > "$TEST_ROOT/sorter.log" 2>&1 &
SORTER_PID=$!
for _ in $(seq 1 150); do
  kill -0 "$SORTER_PID" 2>/dev/null || break
  /bin/sleep 0.1
done
if kill -0 "$SORTER_PID" 2>/dev/null; then
  fail "sorter started with a symlinked sorted root"
fi
set +e
wait "$SORTER_PID"
sorter_rc=$?
set -e
SORTER_PID=""
[[ "$sorter_rc" -eq 2 ]] || fail "symlinked sorted root exited $sorter_rc instead of 2"
[[ "$(cat "$TEST_ROOT/data/incoming/root-sentinel.dat")" == "ROOT SENTINEL — KEEP" ]] \
  || fail "symlinked sorted root modified the incoming sentinel"

echo "PASS: unsafe destination symlinks failed closed without deleting input"

stop_sorter
for trailing_root_case in incoming sorted quarantine; do
  rm -rf "$TEST_ROOT/data"
  mkdir -p \
    "$TEST_ROOT/data/real-incoming" \
    "$TEST_ROOT/data/real-sorted" \
    "$TEST_ROOT/data/real-quarantine"
  ln -s "real-$trailing_root_case" "$TEST_ROOT/data/$trailing_root_case-link"
  printf 'ROOT SENTINEL — KEEP\n' > "$TEST_ROOT/data/real-incoming/.root-sentinel"

  incoming_config="$TEST_ROOT/data/real-incoming"
  sorted_config="$TEST_ROOT/data/real-sorted"
  quarantine_config="$TEST_ROOT/data/real-quarantine"
  case "$trailing_root_case" in
    incoming) incoming_config="$TEST_ROOT/data/incoming-link/" ;;
    sorted) sorted_config="$TEST_ROOT/data/sorted-link/" ;;
    quarantine) quarantine_config="$TEST_ROOT/data/quarantine-link/" ;;
  esac
  : > "$TEST_ROOT/sorter.log"

  INCOMING="$incoming_config" \
  SORTED="$sorted_config" \
  QUARANTINE="$quarantine_config" \
  LOCK_ROOT="$TEST_ROOT/data/real-locks" \
  STABLE_WAIT=1 \
  SORT_WORKERS=1 \
  RECONCILE_IDLE=30 \
  NOTIFY_INTERVAL=3600 \
  RAW_FULL_VALIDATE=0 \
  TG_CONFIG="$TEST_ROOT/telegram.json" \
    /bin/bash "$SORTER" > "$TEST_ROOT/sorter.log" 2>&1 &
  SORTER_PID=$!

  for _ in $(seq 1 150); do
    kill -0 "$SORTER_PID" 2>/dev/null || break
    /bin/sleep 0.1
  done
  if kill -0 "$SORTER_PID" 2>/dev/null; then
    fail "sorter accepted a trailing-slash $trailing_root_case root symlink"
  fi
  set +e
  wait "$SORTER_PID"
  sorter_rc=$?
  set -e
  SORTER_PID=""
  [[ "$sorter_rc" -eq 2 ]] \
    || fail "trailing-slash $trailing_root_case root symlink exited $sorter_rc instead of 2"
  [[ "$(cat "$TEST_ROOT/data/real-incoming/.root-sentinel")" == "ROOT SENTINEL — KEEP" ]] \
    || fail "trailing-slash $trailing_root_case root symlink modified incoming data"
done

echo "PASS: trailing-slash data-root symlinks were rejected"

stop_sorter
rm -rf "$TEST_ROOT/data"
mkdir -p \
  "$TEST_ROOT/data/incoming" \
  "$TEST_ROOT/data/sorted" \
  "$TEST_ROOT/data/quarantine" \
  "$TEST_ROOT/data/control-locks" \
  "$TEST_ROOT/data/control-locks/raw-tmp"
chmod 0700 "$TEST_ROOT/data/control-locks" "$TEST_ROOT/data/control-locks/raw-tmp"
printf 'TRAILING SLASH CAMERA PAYLOAD\n' > "$TEST_ROOT/data/incoming/trailing-slash.dat"
touch -d '2 minutes ago' "$TEST_ROOT/data/incoming/trailing-slash.dat"
: > "$TEST_ROOT/sorter.log"

PATH="$ROOT/tests/fixtures/fast-metadata:$PATH" \
INCOMING="$TEST_ROOT/data/incoming/" \
SORTED="$TEST_ROOT/data/sorted/" \
QUARANTINE="$TEST_ROOT/data/quarantine/" \
LOCK_ROOT="$TEST_ROOT/data/control-locks/" \
RAW_VALIDATE_TMPDIR="$TEST_ROOT/data/control-locks/raw-tmp/" \
STABLE_WAIT=1 \
STABLE_SKIP_AGE=1 \
SORT_WORKERS=1 \
RECONCILE_IDLE=30 \
NOTIFY_INTERVAL=3600 \
RAW_FULL_VALIDATE=0 \
TG_CONFIG="$TEST_ROOT/telegram.json" \
  /bin/bash "$SORTER" > "$TEST_ROOT/sorter.log" 2>&1 &
SORTER_PID=$!

wait_for_count "$TEST_ROOT/data/sorted" 1 30 \
  || fail "real directory roots with trailing slashes did not sort"
[[ ! -f "$TEST_ROOT/data/incoming/trailing-slash.dat" ]] \
  || fail "positive trailing-slash roots left their input behind"

echo "PASS: trailing slashes on real data and control roots were accepted"

stop_sorter
for control_root_case in lock_root raw_tmp; do
  rm -rf "$TEST_ROOT/data"
  mkdir -p \
    "$TEST_ROOT/data/incoming" \
    "$TEST_ROOT/data/real-control-target" \
    "$TEST_ROOT/data/control-locks"
  chmod 0700 "$TEST_ROOT/data/control-locks"
  printf 'CONTROL TARGET — KEEP\n' > "$TEST_ROOT/data/real-control-target/sentinel"

  lock_config="$TEST_ROOT/data/control-locks"
  raw_tmp_config="$TEST_ROOT/data/control-locks/raw-tmp"
  if [[ "$control_root_case" == "lock_root" ]]; then
    rm -rf "$TEST_ROOT/data/control-locks"
    ln -s real-control-target "$TEST_ROOT/data/control-locks-link"
    lock_config="$TEST_ROOT/data/control-locks-link/"
    raw_tmp_config=""
  else
    ln -s real-control-target "$TEST_ROOT/data/raw-tmp-link"
    raw_tmp_config="$TEST_ROOT/data/raw-tmp-link/"
  fi
  : > "$TEST_ROOT/sorter.log"

  set +e
  INCOMING="$TEST_ROOT/data/incoming" \
  SORTED="$TEST_ROOT/data/sorted" \
  QUARANTINE="$TEST_ROOT/data/quarantine" \
  LOCK_ROOT="$lock_config" \
  RAW_VALIDATE_TMPDIR="$raw_tmp_config" \
  STABLE_WAIT=1 \
  STABLE_SKIP_AGE=1 \
  SORT_WORKERS=1 \
  RECONCILE_IDLE=30 \
  NOTIFY_INTERVAL=3600 \
  RAW_FULL_VALIDATE=0 \
  TG_CONFIG="$TEST_ROOT/telegram.json" \
    timeout -k 1 10 /bin/bash "$SORTER" > "$TEST_ROOT/sorter.log" 2>&1
  sorter_rc=$?
  set -e

  [[ "$sorter_rc" -eq 2 ]] \
    || fail "trailing-slash $control_root_case symlink exited $sorter_rc instead of 2"
  [[ "$(cat "$TEST_ROOT/data/real-control-target/sentinel")" == "CONTROL TARGET — KEEP" ]] \
    || fail "trailing-slash $control_root_case symlink modified its target"
done

echo "PASS: trailing-slash lock and RAW-temp symlinks were rejected"

stop_sorter
rm -rf "$TEST_ROOT/data" "$TEST_ROOT/mv-inject-state"
mkdir -p "$TEST_ROOT/data/incoming"
printf 'incoming camera payload that must survive\n' \
  > "$TEST_ROOT/data/incoming/atomic-collision.dat"
: > "$TEST_ROOT/sorter.log"

PATH="$ROOT/tests/fixtures/fast-metadata:$ROOT/tests/fixtures/bin:$PATH" \
TEST_MV_INJECT_STATE_DIR="$TEST_ROOT/mv-inject-state" \
TEST_MV_INJECT_CONTENT='external writer payload' \
INCOMING="$TEST_ROOT/data/incoming" \
SORTED="$TEST_ROOT/data/sorted" \
QUARANTINE="$TEST_ROOT/data/quarantine" \
STABLE_WAIT=1 \
STABLE_SKIP_AGE=3600 \
SORT_WORKERS=1 \
RECONCILE_IDLE=30 \
NOTIFY_INTERVAL=3600 \
RAW_FULL_VALIDATE=0 \
TG_CONFIG="$TEST_ROOT/telegram.json" \
  /bin/bash "$SORTER" > "$TEST_ROOT/sorter.log" 2>&1 &
SORTER_PID=$!

wait_for_count "$TEST_ROOT/data/incoming" 0 60 \
  || fail "atomic collision input did not finish processing"
fixture_date=$(find "$TEST_ROOT/data/sorted" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | head -n1)
atomic_dir="$TEST_ROOT/data/sorted/$fixture_date/other"
[[ "$(cat "$atomic_dir/atomic-collision.dat")" == "external writer payload" ]] \
  || fail "no-clobber move overwrote the external writer's destination"
[[ "$(cat "$atomic_dir/atomic-collision_2.dat")" == "incoming camera payload that must survive" ]] \
  || fail "no-clobber retry did not preserve the incoming camera file"

echo "PASS: atomic no-clobber move preserved an external destination collision"

stop_sorter
rm -rf "$TEST_ROOT/data" "$TEST_ROOT/mv-symlink-state"
mkdir -p "$TEST_ROOT/data/incoming"
symlink_race_source="$TEST_ROOT/data/incoming/leaf-symlink-race.dat"
printf 'ONLY CAMERA COPY — LEAF RACE\n' > "$symlink_race_source"
touch -d '2 minutes ago' "$symlink_race_source"
: > "$TEST_ROOT/sorter.log"

PATH="$ROOT/tests/fixtures/fast-metadata:$ROOT/tests/fixtures/bin:$PATH" \
TEST_MV_INJECT_STATE_DIR="$TEST_ROOT/mv-symlink-state" \
TEST_MV_INJECT_SYMLINK_TO_SOURCE=1 \
INCOMING="$TEST_ROOT/data/incoming" \
SORTED="$TEST_ROOT/data/sorted" \
QUARANTINE="$TEST_ROOT/data/quarantine" \
STABLE_WAIT=1 \
STABLE_SKIP_AGE=1 \
SORT_WORKERS=1 \
RECONCILE_IDLE=30 \
NOTIFY_INTERVAL=3600 \
RAW_FULL_VALIDATE=0 \
TG_CONFIG="$TEST_ROOT/telegram.json" \
  /bin/bash "$SORTER" > "$TEST_ROOT/sorter.log" 2>&1 &
SORTER_PID=$!

wait_for_count "$TEST_ROOT/mv-symlink-state" 2 30 \
  || fail "destination symlink race did not reach and return from mv"
wait_for_claim_release "$symlink_race_source" "$TEST_ROOT/data/.sort-locks" 30 \
  || fail "destination symlink race worker did not release its process claim"
stop_sorter
[[ -f "$symlink_race_source" && ! -L "$symlink_race_source" ]] \
  || fail "destination symlink race lost the incoming source"
[[ "$(cat "$symlink_race_source")" == "ONLY CAMERA COPY — LEAF RACE" ]] \
  || fail "destination symlink race modified the incoming source"
[[ ! -s "$TEST_ROOT/data/.sort-locks/queues/notify-queue.tsv" ]] \
  || fail "destination symlink race queued a false success notification"
! grep -q 'ok: leaf-symlink-race.dat ->' "$TEST_ROOT/sorter.log" \
  || fail "destination symlink race falsely logged a successful move"

echo "PASS: destination symlink injected at mv stayed fail-closed"

rm -rf "$TEST_ROOT/data" "$TEST_ROOT/mv-ancestor-state" "$TEST_ROOT/escape-target"
mkdir -p "$TEST_ROOT/data/incoming" "$TEST_ROOT/escape-target"
ancestor_race_source="$TEST_ROOT/data/incoming/ancestor-swap-race.dat"
printf 'ONLY CAMERA COPY — ANCESTOR RACE\n' > "$ancestor_race_source"
touch -d '2 minutes ago' "$ancestor_race_source"
: > "$TEST_ROOT/sorter.log"

PATH="$ROOT/tests/fixtures/fast-metadata:$ROOT/tests/fixtures/bin:$PATH" \
TEST_MV_INJECT_STATE_DIR="$TEST_ROOT/mv-ancestor-state" \
TEST_MV_SWAP_ANCESTOR_TARGET="$TEST_ROOT/escape-target" \
INCOMING="$TEST_ROOT/data/incoming" \
SORTED="$TEST_ROOT/data/sorted" \
QUARANTINE="$TEST_ROOT/data/quarantine" \
STABLE_WAIT=1 \
STABLE_SKIP_AGE=1 \
SORT_WORKERS=1 \
RECONCILE_IDLE=30 \
NOTIFY_INTERVAL=3600 \
RAW_FULL_VALIDATE=0 \
TG_CONFIG="$TEST_ROOT/telegram.json" \
  /bin/bash "$SORTER" > "$TEST_ROOT/sorter.log" 2>&1 &
SORTER_PID=$!

wait_for_count "$TEST_ROOT/mv-ancestor-state" 2 30 \
  || fail "output ancestor race did not reach and return from mv"
wait_for_claim_release "$ancestor_race_source" "$TEST_ROOT/data/.sort-locks" 30 \
  || fail "output ancestor race worker did not release its process claim"
stop_sorter
[[ -f "$ancestor_race_source" && ! -L "$ancestor_race_source" ]] \
  || fail "output ancestor swap did not preserve or recover the incoming source"
[[ "$(cat "$ancestor_race_source")" == "ONLY CAMERA COPY — ANCESTOR RACE" ]] \
  || fail "output ancestor swap changed the recovered source"
[[ ! -e "$TEST_ROOT/escape-target/ancestor-swap-race.dat" ]] \
  || fail "output ancestor swap escaped the sorted root"
[[ ! -s "$TEST_ROOT/data/.sort-locks/queues/notify-queue.tsv" ]] \
  || fail "output ancestor swap queued a false success notification"
! grep -q 'ok: ancestor-swap-race.dat ->' "$TEST_ROOT/sorter.log" \
  || fail "output ancestor swap falsely logged a successful move"

echo "PASS: output ancestor swap could not escape the sorted root"

stop_sorter
rm -rf \
  "$TEST_ROOT/data" \
  "$TEST_ROOT/mv-source-parent-state" \
  "$TEST_ROOT/source-parent-attacker" \
  "$TEST_ROOT/source-parent-displaced"
mkdir -p \
  "$TEST_ROOT/data/incoming/nested-upload" \
  "$TEST_ROOT/source-parent-attacker"
source_parent_race="$TEST_ROOT/data/incoming/nested-upload/source-parent-race.dat"
printf 'ONLY CAMERA COPY — SOURCE PARENT RACE\n' > "$source_parent_race"
printf 'ATTACKER REPLACEMENT — NEVER SORT\n' \
  > "$TEST_ROOT/source-parent-attacker/source-parent-race.dat"
touch -d '2 minutes ago' "$source_parent_race"
: > "$TEST_ROOT/sorter.log"

PATH="$ROOT/tests/fixtures/fast-metadata:$ROOT/tests/fixtures/bin:$PATH" \
TEST_MV_INJECT_STATE_DIR="$TEST_ROOT/mv-source-parent-state" \
TEST_MV_SWAP_SOURCE_PARENT_TARGET="$TEST_ROOT/source-parent-attacker" \
TEST_MV_SWAP_SOURCE_PARENT_PATH="$TEST_ROOT/data/incoming/nested-upload" \
TEST_MV_SOURCE_DISPLACED_DIR="$TEST_ROOT/source-parent-displaced" \
INCOMING="$TEST_ROOT/data/incoming" \
SORTED="$TEST_ROOT/data/sorted" \
QUARANTINE="$TEST_ROOT/data/quarantine" \
STABLE_WAIT=1 \
STABLE_SKIP_AGE=1 \
SORT_WORKERS=1 \
RECONCILE_IDLE=30 \
NOTIFY_INTERVAL=3600 \
RAW_FULL_VALIDATE=0 \
TG_CONFIG="$TEST_ROOT/telegram.json" \
  /bin/bash "$SORTER" > "$TEST_ROOT/sorter.log" 2>&1 &
SORTER_PID=$!

wait_for_count "$TEST_ROOT/mv-source-parent-state" 2 30 \
  || fail "nested source-parent race did not reach and return from mv"
wait_for_claim_release "$source_parent_race" "$TEST_ROOT/data/.sort-locks" 30 \
  || fail "nested source-parent race worker did not release its process claim"
stop_sorter
[[ ! -e "$TEST_ROOT/source-parent-displaced/source-parent-race.dat" ]] \
  || fail "nested source-parent swap rolled the camera file outside incoming"
retained_source_parent_race=$(find "$TEST_ROOT/data/sorted" -type f \
  -name source-parent-race.dat -print -quit)
[[ -n "$retained_source_parent_race" ]] \
  || fail "nested source-parent swap lost the retained camera file"
[[ "$(cat "$retained_source_parent_race")" \
  == "ONLY CAMERA COPY — SOURCE PARENT RACE" ]] \
  || fail "nested source-parent swap changed the retained camera payload"
[[ -f "$TEST_ROOT/source-parent-attacker/source-parent-race.dat" ]] \
  || fail "nested source-parent swap did not restore the replacement payload"
[[ "$(cat "$TEST_ROOT/source-parent-attacker/source-parent-race.dat")" \
  == "ATTACKER REPLACEMENT — NEVER SORT" ]] \
  || fail "nested source-parent swap changed the replacement payload"
[[ $(find "$TEST_ROOT/data/sorted" -type f 2>/dev/null | wc -l) -eq 1 ]] \
  || fail "nested source-parent swap retained an unexpected output count"
[[ ! -s "$TEST_ROOT/data/.sort-locks/queues/notify-queue.tsv" ]] \
  || fail "nested source-parent swap queued a false success notification"
! grep -q 'ok: source-parent-race.dat ->' "$TEST_ROOT/sorter.log" \
  || fail "nested source-parent swap falsely logged a successful move"
grep -q 'source parent left incoming during move; moved inode retained for recovery at:' \
  "$TEST_ROOT/sorter.log" \
  || fail "nested source-parent swap did not report its retained recovery copy"

echo "PASS: nested source-parent swap retained the camera inode without escaping rollback"

stop_sorter
rm -rf \
  "$TEST_ROOT/data" \
  "$TEST_ROOT/mv-source-rollback-state" \
  "$TEST_ROOT/rollback-output-escape" \
  "$TEST_ROOT/rollback-source-attacker" \
  "$TEST_ROOT/rollback-source-displaced"
mkdir -p \
  "$TEST_ROOT/data/incoming/nested-upload" \
  "$TEST_ROOT/rollback-output-escape" \
  "$TEST_ROOT/rollback-source-attacker"
rollback_window_source="$TEST_ROOT/data/incoming/nested-upload/rollback-window.dat"
printf 'ONLY CAMERA COPY — ROLLBACK WINDOW\n' > "$rollback_window_source"
touch -d '2 minutes ago' "$rollback_window_source"
: > "$TEST_ROOT/sorter.log"

PATH="$ROOT/tests/fixtures/fast-metadata:$ROOT/tests/fixtures/bin:$PATH" \
TEST_MV_INJECT_STATE_DIR="$TEST_ROOT/mv-source-rollback-state" \
TEST_MV_SWAP_SOURCE_PARENT_ON_ROLLBACK=1 \
TEST_MV_SWAP_ANCESTOR_TARGET="$TEST_ROOT/rollback-output-escape" \
TEST_MV_SWAP_SOURCE_PARENT_TARGET="$TEST_ROOT/rollback-source-attacker" \
TEST_MV_SWAP_SOURCE_PARENT_PATH="$TEST_ROOT/data/incoming/nested-upload" \
TEST_MV_SOURCE_DISPLACED_DIR="$TEST_ROOT/rollback-source-displaced" \
INCOMING="$TEST_ROOT/data/incoming" \
SORTED="$TEST_ROOT/data/sorted" \
QUARANTINE="$TEST_ROOT/data/quarantine" \
STABLE_WAIT=1 \
STABLE_SKIP_AGE=1 \
SORT_WORKERS=1 \
RECONCILE_IDLE=30 \
NOTIFY_INTERVAL=3600 \
RAW_FULL_VALIDATE=0 \
TG_CONFIG="$TEST_ROOT/telegram.json" \
  /bin/bash "$SORTER" > "$TEST_ROOT/sorter.log" 2>&1 &
SORTER_PID=$!

rollback_deadline=$((SECONDS + 30 * TEST_TIMEOUT_SCALE))
while [[ ! -e "$TEST_ROOT/mv-source-rollback-state/mv-returned-3" \
  && $SECONDS -lt $rollback_deadline ]]; do
  /bin/sleep 0.1
done
[[ -e "$TEST_ROOT/mv-source-rollback-state/mv-returned-3" ]] \
  || fail "source parent did not move during the rollback mv and reverse recovery"
wait_for_claim_release "$rollback_window_source" "$TEST_ROOT/data/.sort-locks" 30 \
  || fail "rollback-window worker did not release its process claim"
stop_sorter
[[ $(find "$TEST_ROOT/rollback-source-displaced" -type f 2>/dev/null | wc -l) -eq 0 ]] \
  || fail "rollback-window left the camera inode outside incoming"
[[ $(find "$TEST_ROOT/rollback-source-attacker" -type f 2>/dev/null | wc -l) -eq 0 ]] \
  || fail "rollback-window moved the camera inode through the replacement symlink"
[[ $(find "$TEST_ROOT/rollback-output-escape" -type f 2>/dev/null | wc -l) -eq 0 ]] \
  || fail "rollback-window escaped through the replaced output path"
rollback_window_retained=$(find "$TEST_ROOT/data/sorted" -type f \
  -path '*/other.displaced/rollback-window.dat' -print -quit)
[[ -n "$rollback_window_retained" ]] \
  || fail "rollback-window reverse recovery did not retain the camera inode in pinned output"
[[ "$(cat "$rollback_window_retained")" == "ONLY CAMERA COPY — ROLLBACK WINDOW" ]] \
  || fail "rollback-window reverse recovery changed the camera payload"
[[ ! -s "$TEST_ROOT/data/.sort-locks/queues/notify-queue.tsv" ]] \
  || fail "rollback-window reverse recovery queued a false success notification"
! grep -q 'ok: rollback-window.dat ->' "$TEST_ROOT/sorter.log" \
  || fail "rollback-window reverse recovery falsely logged success"
grep -q 'source parent left incoming during move; moved inode retained for recovery at:.*other.displaced/rollback-window.dat' \
  "$TEST_ROOT/sorter.log" \
  || fail "rollback-window reverse recovery did not log its exact retained location"

echo "PASS: source parent move on rollback triggered exact-inode reverse recovery without notification"

for source_node_kind in regular symlink fifo; do
  stop_sorter
  rm -rf "$TEST_ROOT/data" "$TEST_ROOT/mv-source-node-state" "$TEST_ROOT/source-node-target"
  mkdir -p "$TEST_ROOT/data/incoming/nested-upload" "$TEST_ROOT/source-node-target"
  source_node_path="$TEST_ROOT/data/incoming/nested-upload/source-node-$source_node_kind.dat"
  printf 'ORIGINAL VALIDATED CAMERA PAYLOAD — %s\n' "$source_node_kind" > "$source_node_path"
  printf 'SYMLINK TARGET — KEEP\n' > "$TEST_ROOT/source-node-target/sentinel"
  touch -d '2 minutes ago' "$source_node_path"
  : > "$TEST_ROOT/sorter.log"

  PATH="$ROOT/tests/fixtures/fast-metadata:$ROOT/tests/fixtures/bin:$PATH" \
  TEST_MV_INJECT_STATE_DIR="$TEST_ROOT/mv-source-node-state" \
  TEST_MV_SWAP_SOURCE_LEAF_KIND="$source_node_kind" \
  TEST_MV_SOURCE_LEAF_SYMLINK_TARGET="$TEST_ROOT/source-node-target/sentinel" \
  INCOMING="$TEST_ROOT/data/incoming" \
  SORTED="$TEST_ROOT/data/sorted" \
  QUARANTINE="$TEST_ROOT/data/quarantine" \
  STABLE_WAIT=1 \
  STABLE_SKIP_AGE=1 \
  SORT_WORKERS=1 \
  RECONCILE_IDLE=30 \
  NOTIFY_INTERVAL=3600 \
  RAW_FULL_VALIDATE=0 \
  TG_CONFIG="$TEST_ROOT/telegram.json" \
    /bin/bash "$SORTER" > "$TEST_ROOT/sorter.log" 2>&1 &
  SORTER_PID=$!

  wait_for_count "$TEST_ROOT/mv-source-node-state" 2 30 \
    || fail "source $source_node_kind replacement did not reach rollback"
  wait_for_claim_release "$source_node_path" "$TEST_ROOT/data/.sort-locks" 30 \
    || fail "source $source_node_kind replacement worker did not release its claim"
  stop_sorter
  [[ -f "$source_node_path.part" && ! -L "$source_node_path.part" ]] \
    || fail "source $source_node_kind replacement lost the original saved camera payload"
  [[ "$(cat "$source_node_path.part")" == "ORIGINAL VALIDATED CAMERA PAYLOAD — $source_node_kind" ]] \
    || fail "source $source_node_kind replacement changed the original saved camera payload"
  if [[ "$source_node_kind" == regular ]]; then
    [[ -f "$source_node_path" && ! -L "$source_node_path" ]] \
      || fail "source regular replacement was not restored to its pinned incoming leaf"
    chmod 0600 -- "$source_node_path"
    [[ "$(cat "$source_node_path")" == "REPLACEMENT REGULAR PAYLOAD" ]] \
      || fail "source regular replacement payload changed during rollback"
  elif [[ "$source_node_kind" == symlink ]]; then
    [[ -L "$source_node_path" ]] \
      || fail "source symlink replacement was not restored to its pinned incoming leaf"
    [[ "$(readlink "$source_node_path")" == "$TEST_ROOT/source-node-target/sentinel" ]] \
      || fail "source symlink replacement target changed during rollback"
    [[ "$(cat "$TEST_ROOT/source-node-target/sentinel")" == "SYMLINK TARGET — KEEP" ]] \
      || fail "source symlink replacement modified its target"
  else
    [[ -p "$source_node_path" ]] \
      || fail "source FIFO replacement was not restored to its pinned incoming leaf"
  fi
  [[ $(find "$TEST_ROOT/data/sorted" -name "source-node-$source_node_kind.dat" | wc -l) -eq 0 ]] \
    || fail "source $source_node_kind replacement remained in sorted output"
  [[ ! -s "$TEST_ROOT/data/.sort-locks/queues/notify-queue.tsv" ]] \
    || fail "source $source_node_kind replacement queued a false success notification"
  ! grep -q "ok: source-node-$source_node_kind.dat ->" "$TEST_ROOT/sorter.log" \
    || fail "source $source_node_kind replacement falsely logged success"
  grep -q 'source changed during move; replacement recovered through pinned source parent' \
    "$TEST_ROOT/sorter.log" \
    || fail "source $source_node_kind replacement did not report exact-node rollback"
done

echo "PASS: source regular, symlink, and FIFO swaps were restored to incoming with output clean"

stop_sorter
rm -rf "$TEST_ROOT/data" "$TEST_ROOT/move-gate"
mkdir -p "$TEST_ROOT/data/incoming"
: > "$TEST_ROOT/stable-sleeps.log"
: > "$TEST_ROOT/duplicate-claims.log"
: > "$TEST_ROOT/sorter.log"

PATH="$ROOT/tests/fixtures/claim-flock:$ROOT/tests/fixtures/fast-metadata:$ROOT/tests/fixtures/bin:$PATH" \
TEST_CLAIM_FLOCK_LOG="$TEST_ROOT/duplicate-claims.log" \
TEST_SLEEP_LOG="$TEST_ROOT/stable-sleeps.log" \
TEST_SLEEP_RELEASE_FILE="$TEST_ROOT/duplicate-sleep-release" \
TEST_STABLE_WAIT=2 \
INCOMING="$TEST_ROOT/data/incoming" \
SORTED="$TEST_ROOT/data/sorted" \
QUARANTINE="$TEST_ROOT/data/quarantine" \
STABLE_WAIT=2 \
STABLE_SKIP_AGE=3600 \
SORT_WORKERS=4 \
RECONCILE_IDLE=30 \
NOTIFY_INTERVAL=3600 \
RAW_FULL_VALIDATE=0 \
TG_CONFIG="$TEST_ROOT/telegram.json" \
  /bin/bash "$SORTER" > "$TEST_ROOT/sorter.log" 2>&1 &
SORTER_PID=$!

wait_for_log 'watching ' 15 || fail "sorter did not start watching"
printf 'one upload, many close events\n' > "$TEST_ROOT/data/incoming/duplicate.dat"
wait_for_lines "$TEST_ROOT/stable-sleeps.log" 1 15 \
  || fail "first duplicate-event worker never reached its stability gate"
for _ in 1 2 3 4 5 6 7 8 9 10 11 12; do
  : >> "$TEST_ROOT/data/incoming/duplicate.dat"
  /bin/sleep 0.1
done
wait_for_lines "$TEST_ROOT/duplicate-claims.log" 4 15 \
  || fail "duplicate-event fixture did not create competing process claims"
: > "$TEST_ROOT/duplicate-sleep-release"

wait_for_count "$TEST_ROOT/data/incoming" 0 20 || fail "duplicate-event fixture did not sort"
wait_for_lines "$TEST_ROOT/data/.sort-locks/queues/notify-queue.tsv" 1 20 || fail "duplicate event notification was not queued"
stable_checks=$(wc -l < "$TEST_ROOT/stable-sleeps.log")
[[ "$stable_checks" -eq 1 ]] || fail "one path ran $stable_checks concurrent stability checks"
[[ $(find "$TEST_ROOT/data/sorted" -type f | wc -l) -eq 1 ]] || fail "duplicate events produced multiple outputs"
[[ $(wc -l < "$TEST_ROOT/data/.sort-locks/queues/notify-queue.tsv") -eq 1 ]] || fail "duplicate events produced multiple notifications"

echo "PASS: duplicate events shared one in-flight file worker"

stop_sorter
rm -rf "$TEST_ROOT/data"
mkdir -p "$TEST_ROOT/data/incoming" "$TEST_ROOT/bounded-sleep-state"
for n in 1 2 3 4 5 6 7 8 9; do
  printf 'bounded fixture %s\n' "$n" > "$TEST_ROOT/data/incoming/bounded-$n.dat"
done

PATH="$ROOT/tests/fixtures/fast-metadata:$ROOT/tests/fixtures/bin:$PATH" \
TEST_SLEEP_STATE_DIR="$TEST_ROOT/bounded-sleep-state" \
TEST_SLEEP_RELEASE_FILE="$TEST_ROOT/bounded-sleep-release" \
TEST_STABLE_WAIT=1 \
INCOMING="$TEST_ROOT/data/incoming" \
SORTED="$TEST_ROOT/data/sorted" \
QUARANTINE="$TEST_ROOT/data/quarantine" \
STABLE_WAIT=1 \
STABLE_SKIP_AGE=3600 \
SORT_WORKERS=3 \
RECONCILE_IDLE=30 \
NOTIFY_INTERVAL=3600 \
RAW_FULL_VALIDATE=0 \
TG_CONFIG="$TEST_ROOT/telegram.json" \
  /bin/bash "$SORTER" > "$TEST_ROOT/sorter.log" 2>&1 &
SORTER_PID=$!

wait_for_value_at_least "$TEST_ROOT/bounded-sleep-state/max" 3 20 \
  || fail "three workers never entered the stability check concurrently"
: > "$TEST_ROOT/bounded-sleep-release"
wait_for_count "$TEST_ROOT/data/sorted" 9 45 || fail "bounded-worker batch did not sort"
wait_for_lines "$TEST_ROOT/data/.sort-locks/queues/notify-queue.tsv" 9 45 || fail "bounded-worker notification queue lost a row"
peak_workers=$(cat "$TEST_ROOT/bounded-sleep-state/max" 2>/dev/null || echo 0)
[[ "$peak_workers" -eq 3 ]] || fail "worker limit was 3 but observed peak was $peak_workers"
[[ $(find "$TEST_ROOT/data/sorted" -type f | wc -l) -eq 9 ]] \
  || fail "bounded-worker batch produced an unexpected output count"
[[ $(wc -l < "$TEST_ROOT/data/.sort-locks/queues/notify-queue.tsv") -eq 9 ]] \
  || fail "bounded-worker notification queue produced an unexpected row count"

echo "PASS: worker pool respected SORT_WORKERS=3 across nine files"

stop_sorter
rm -rf "$TEST_ROOT/data"
mkdir -p "$TEST_ROOT/data/incoming"
: > "$TEST_ROOT/sorter.log"

PATH="$ROOT/tests/fixtures/fast-metadata:$PATH" \
INCOMING="$TEST_ROOT/data/incoming" \
SORTED="$TEST_ROOT/data/sorted" \
QUARANTINE="$TEST_ROOT/data/quarantine" \
STABLE_WAIT=1 \
STABLE_SKIP_AGE=3600 \
SORT_WORKERS=4 \
RECONCILE_IDLE=2 \
NOTIFY_INTERVAL=3600 \
RAW_FULL_VALIDATE=0 \
TG_CONFIG="$TEST_ROOT/telegram.json" \
  /bin/bash "$SORTER" > "$TEST_ROOT/sorter.log" 2>&1 &
SORTER_PID=$!

wait_for_log 'watching ' 15 || fail "retry-reconcile sorter did not start watching"
printf 'old' > "$TEST_ROOT/data/incoming/retry.dat"
/bin/sleep 0.2
printf 'replacement-is-larger' > "$TEST_ROOT/data/replacement.dat"
mv -f "$TEST_ROOT/data/replacement.dat" "$TEST_ROOT/data/incoming/retry.dat"

# Keep inotify continuously busy until the assertions finish. The blocking path
# claim must preserve the replacement, and a wall-clock reconcile must run even
# though unrelated events never leave a silence window.
(
  while true; do
    : >> "$TEST_ROOT/data/incoming/.continuous-events"
    /bin/sleep 0.25
  done
) &
TRAFFIC_PID=$!

wait_for_count "$TEST_ROOT/data/sorted" 1 30 \
  || fail "replacement stayed stranded while unrelated events continued"
[[ ! -f "$TEST_ROOT/data/incoming/retry.dat" ]] \
  || fail "replacement remained after its sorted output appeared"
wait_for_log_count 'reconcile scan' 2 30 \
  || fail "continuous event traffic prevented the wall-clock reconcile"
kill -0 "$TRAFFIC_PID" 2>/dev/null \
  || fail "continuous event producer stopped before reconciliation"
[[ $(find "$TEST_ROOT/data/sorted" -type f | wc -l) -eq 1 ]] \
  || fail "replacement test produced an unexpected output count"
replacement_output=$(find "$TEST_ROOT/data/sorted" -type f -name retry.dat -print -quit)
[[ -n "$replacement_output" ]] \
  || fail "replacement test sorted an unexpected filename"
[[ "$(cat "$replacement_output")" == "replacement-is-larger" ]] \
  || fail "replacement test sorted stale or changed payload bytes"
stop_traffic

echo "PASS: exact replacement payload and wall-clock reconcile survived continuous traffic"

stop_sorter
rm -rf "$TEST_ROOT/data"
mkdir -p "$TEST_ROOT/data/incoming"
: > "$TEST_ROOT/shutdown-sleeps.log"
: > "$TEST_ROOT/shutdown-children.log"
: > "$TEST_ROOT/notifier-sleeps.log"
: > "$TEST_ROOT/sorter.log"

PATH="$ROOT/tests/fixtures/bin:$PATH" \
TEST_SLEEP_LOG="$TEST_ROOT/shutdown-sleeps.log" \
TEST_FORK_CHILDREN_LOG="$TEST_ROOT/shutdown-children.log" \
TEST_NOTIFIER_SLEEP_LOG="$TEST_ROOT/notifier-sleeps.log" \
TEST_NOTIFY_INTERVAL=3600 \
TEST_STABLE_WAIT=30 \
INCOMING="$TEST_ROOT/data/incoming" \
SORTED="$TEST_ROOT/data/sorted" \
QUARANTINE="$TEST_ROOT/data/quarantine" \
STABLE_WAIT=30 \
STABLE_SKIP_AGE=3600 \
SORT_WORKERS=1 \
RECONCILE_IDLE=300 \
NOTIFY_INTERVAL=3600 \
RAW_FULL_VALIDATE=0 \
TG_CONFIG="$TEST_ROOT/telegram.json" \
  /bin/bash "$SORTER" > "$TEST_ROOT/sorter.log" 2>&1 &
SORTER_PID=$!

wait_for_log 'watching ' 15 || fail "shutdown sorter did not start watching"
wait_for_lines "$TEST_ROOT/notifier-sleeps.log" 1 15 \
  || fail "notifier did not enter its interval sleep"
notifier_sleep_pid=$(tail -n1 "$TEST_ROOT/notifier-sleeps.log")
inotify_child_pid=""
notifier_child_pid=""
watch_probe_dir=""
mapfile -t service_descendants < <(list_descendants "$SORTER_PID")
for child_pid in "${service_descendants[@]}"; do
  child_command=$(tr '\0' ' ' < "/proc/$child_pid/cmdline" 2>/dev/null || true)
  if [[ "$child_command" == *inotifywait* ]]; then
    inotify_child_pid=$child_pid
    watch_probe_dir=$(tr '\0' '\n' < "/proc/$child_pid/cmdline" 2>/dev/null \
      | grep '^/tmp/camera-sorter-watch-ready\.' | tail -n1 || true)
  elif [[ "$child_command" == *"/bin/bash $SORTER"* ]]; then
    notifier_child_pid=$child_pid
  fi
done
[[ -n "$inotify_child_pid" ]] || fail "could not identify the inotify child"
[[ -n "$notifier_child_pid" ]] || fail "could not identify the notifier child"
[[ -n "$watch_probe_dir" && -d "$watch_probe_dir" ]] \
  || fail "private watcher readiness directory was not retained"
notifier_sleep_is_descendant=0
mapfile -t notifier_descendants < <(list_descendants "$notifier_child_pid")
for child_pid in "${notifier_descendants[@]}"; do
  if [[ "$child_pid" == "$notifier_sleep_pid" ]]; then
    notifier_sleep_is_descendant=1
    break
  fi
done
[[ "$notifier_sleep_is_descendant" -eq 1 ]] \
  || fail "captured notifier sleep was not below the notifier process"

printf 'shutdown fixture\n' > "$TEST_ROOT/data/incoming/shutdown.dat"
wait_for_lines "$TEST_ROOT/shutdown-sleeps.log" 1 15 || fail "worker did not enter stability sleep"
wait_for_lines "$TEST_ROOT/shutdown-children.log" 2 15 || fail "worker did not start both external descendants"
sleep_pid=$(tail -n1 "$TEST_ROOT/shutdown-sleeps.log")
mapfile -t sleep_children < "$TEST_ROOT/shutdown-children.log"
stop_sorter
[[ "$LAST_STOP_ESCALATED" -eq 0 ]] \
  || fail "sorter required SIGKILL during graceful shutdown"
/bin/sleep 0.2
assert_pid_stopped "$sleep_pid" "worker child"
for child_pid in "${sleep_children[@]}"; do
  assert_pid_stopped "$child_pid" "worker grandchild"
done
assert_pid_stopped "$inotify_child_pid" "inotify child"
assert_pid_stopped "$notifier_child_pid" "notifier child"
assert_pid_stopped "$notifier_sleep_pid" "notifier sleep descendant"
[[ ! -e "$watch_probe_dir" ]] \
  || fail "shutdown left private watcher readiness directory $watch_probe_dir"

echo "PASS: shutdown terminated service and worker process trees"

stop_sorter
rm -rf "$TEST_ROOT/data"
mkdir -p "$TEST_ROOT/data/incoming"
printf 'stubborn raw fixture\n' > "$TEST_ROOT/data/incoming/stubborn.dng"
: > "$TEST_ROOT/sorter.log"

PATH="$ROOT/tests/fixtures/stubborn-validator:$PATH" \
INCOMING="$TEST_ROOT/data/incoming" \
SORTED="$TEST_ROOT/data/sorted" \
QUARANTINE="$TEST_ROOT/data/quarantine" \
STABLE_WAIT=1 \
STABLE_SKIP_AGE=3600 \
SORT_WORKERS=1 \
RECONCILE_IDLE=30 \
NOTIFY_INTERVAL=3600 \
RAW_MIN_BYTES_DEFAULT=1 \
RAW_VALIDATE_TIMEOUT=1 \
RAW_FULL_VALIDATE=0 \
TG_CONFIG="$TEST_ROOT/telegram.json" \
  /bin/bash "$SORTER" > "$TEST_ROOT/sorter.log" 2>&1 &
SORTER_PID=$!

wait_for_count "$TEST_ROOT/data/quarantine" 1 30 \
  || fail "TERM-ignoring validator held its worker indefinitely"
[[ $(find "$TEST_ROOT/data/quarantine" -type f | wc -l) -eq 1 ]] \
  || fail "stubborn validator produced an unexpected quarantine count"
grep -q 'raw container check timed out' "$TEST_ROOT/sorter.log" \
  || fail "forced validator kill was not reported as a timeout"

echo "PASS: TERM-ignoring RAW validator was forcibly bounded"

stop_sorter
for metadata_stage in date raw-model raw-readable camera-make camera-model filetype duration; do
  rm -rf "$TEST_ROOT/data"
  mkdir -p "$TEST_ROOT/data/incoming"
  case "$metadata_stage" in
    raw-model|raw-readable)
      metadata_name="stubborn-$metadata_stage.dng"
      printf 'stubborn raw metadata fixture\n' \
        > "$TEST_ROOT/data/incoming/$metadata_name"
      metadata_outcome=quarantine
      ;;
    filetype|duration)
      metadata_name="stubborn-$metadata_stage.mov"
      truncate -s 600001 "$TEST_ROOT/data/incoming/$metadata_name"
      metadata_outcome=quarantine
      ;;
    *)
      metadata_name="stubborn-$metadata_stage.dat"
      printf 'stubborn ordinary metadata fixture\n' \
        > "$TEST_ROOT/data/incoming/$metadata_name"
      metadata_outcome=sorted
      ;;
  esac
  touch -d '2 minutes ago' "$TEST_ROOT/data/incoming/$metadata_name"
  : > "$TEST_ROOT/sorter.log"

  PATH="$ROOT/tests/fixtures/stubborn-validator:$PATH" \
  TEST_STUBBORN_STAGE="$metadata_stage" \
  INCOMING="$TEST_ROOT/data/incoming" \
  SORTED="$TEST_ROOT/data/sorted" \
  QUARANTINE="$TEST_ROOT/data/quarantine" \
  STABLE_WAIT=1 \
  STABLE_SKIP_AGE=1 \
  SORT_WORKERS=1 \
  RECONCILE_IDLE=30 \
  NOTIFY_INTERVAL=3600 \
  RAW_MIN_BYTES_DEFAULT=1 \
  RAW_VALIDATE_TIMEOUT=1 \
  RAW_FULL_VALIDATE=0 \
  TG_CONFIG="$TEST_ROOT/telegram.json" \
    /bin/bash "$SORTER" > "$TEST_ROOT/sorter.log" 2>&1 &
  SORTER_PID=$!

  wait_for_count "$TEST_ROOT/data/$metadata_outcome" 1 30 \
    || fail "TERM-ignoring $metadata_stage metadata probe held its worker indefinitely"
  [[ $(find "$TEST_ROOT/data/$metadata_outcome" -type f | wc -l) -eq 1 ]] \
    || fail "stubborn $metadata_stage metadata probe produced an unexpected output count"
  case "$metadata_stage" in
    date)
      metadata_log='exif date lookup timed out after 1s — using mtime'
      ;;
    raw-model)
      metadata_log='raw camera model lookup timed out after 1s'
      ;;
    raw-readable)
      metadata_log='raw Make/Model lookup timed out after 1s'
      ;;
    camera-make)
      metadata_log='camera Make lookup timed out after 1s'
      ;;
    camera-model)
      metadata_log='camera Model lookup timed out after 1s'
      ;;
    filetype)
      metadata_log='video FileType lookup timed out after 1s'
      ;;
    duration)
      metadata_log='video Duration lookup timed out after 1s'
      ;;
  esac
  grep -q "$metadata_log" "$TEST_ROOT/sorter.log" \
    || fail "forced $metadata_stage metadata kill was not classified"
  stop_sorter
done

echo "PASS: every TERM-ignoring ExifTool metadata stage was forcibly bounded"

stop_sorter
for stage in identify decode; do
  rm -rf "$TEST_ROOT/data"
  mkdir -p "$TEST_ROOT/data/incoming"
  printf 'stubborn payload fixture\n' > "$TEST_ROOT/data/incoming/stubborn-$stage.dng"
  touch -d '2 minutes ago' "$TEST_ROOT/data/incoming/stubborn-$stage.dng"
  : > "$TEST_ROOT/sorter.log"

  PATH="$ROOT/tests/fixtures/stubborn-payload:$PATH" \
  TEST_STUBBORN_STAGE="$stage" \
  INCOMING="$TEST_ROOT/data/incoming" \
  SORTED="$TEST_ROOT/data/sorted" \
  QUARANTINE="$TEST_ROOT/data/quarantine" \
  STABLE_WAIT=1 \
  STABLE_SKIP_AGE=1 \
  SORT_WORKERS=1 \
  RECONCILE_IDLE=30 \
  NOTIFY_INTERVAL=3600 \
  RAW_MIN_BYTES_DEFAULT=1 \
  RAW_VALIDATE_TIMEOUT=1 \
  RAW_FULL_VALIDATE=1 \
  TG_CONFIG="$TEST_ROOT/telegram.json" \
    /bin/bash "$SORTER" > "$TEST_ROOT/sorter.log" 2>&1 &
  SORTER_PID=$!

  wait_for_count "$TEST_ROOT/data/quarantine" 1 30 \
    || fail "TERM-ignoring $stage validator held its worker indefinitely"
  [[ $(find "$TEST_ROOT/data/quarantine" -type f | wc -l) -eq 1 ]] \
    || fail "stubborn $stage validator produced an unexpected quarantine count"
  if [[ "$stage" == "identify" ]]; then
    grep -q 'raw-identify timed out after 1s' "$TEST_ROOT/sorter.log" \
      || fail "forced raw-identify kill was not reported as a timeout"
  else
    grep -q 'raw decode timed out after 1s' "$TEST_ROOT/sorter.log" \
      || fail "forced raw decode kill was not reported as a timeout"
  fi
  stop_sorter
done

echo "PASS: TERM-ignoring LibRaw validators were forcibly bounded"

stop_sorter
rm -rf "$TEST_ROOT/data"
mkdir -p "$TEST_ROOT/data/incoming" "$TEST_ROOT/data/.sort-locks/raw-validate-tmp/raw.stale-test"
chmod 0700 "$TEST_ROOT/data/.sort-locks" "$TEST_ROOT/data/.sort-locks/raw-validate-tmp"
printf 'stale scratch\n' > "$TEST_ROOT/data/.sort-locks/raw-validate-tmp/raw.stale-test/output.ppm"
printf 'startup fixture\n' > "$TEST_ROOT/data/incoming/startup.dat"
touch -d '30 minutes ago' \
  "$TEST_ROOT/data/.sort-locks/raw-validate-tmp/raw.stale-test" \
  "$TEST_ROOT/data/.sort-locks/raw-validate-tmp/raw.stale-test/output.ppm"
: > "$TEST_ROOT/scratch-order-failures.log"
: > "$TEST_ROOT/sorter.log"

PATH="$ROOT/tests/fixtures/fast-metadata:$ROOT/tests/fixtures/bin:$PATH" \
TEST_STABLE_WAIT=1 \
TEST_ASSERT_ABSENT="$TEST_ROOT/data/.sort-locks/raw-validate-tmp/raw.stale-test" \
TEST_ASSERT_FAILURE_LOG="$TEST_ROOT/scratch-order-failures.log" \
INCOMING="$TEST_ROOT/data/incoming" \
SORTED="$TEST_ROOT/data/sorted" \
QUARANTINE="$TEST_ROOT/data/quarantine" \
STABLE_WAIT=1 \
SORT_WORKERS=1 \
RECONCILE_IDLE=30 \
NOTIFY_INTERVAL=3600 \
RAW_FULL_VALIDATE=0 \
TG_CONFIG="$TEST_ROOT/telegram.json" \
  /bin/bash "$SORTER" > "$TEST_ROOT/sorter.log" 2>&1 &
SORTER_PID=$!

wait_for_log 'watching ' 30 || fail "scratch-cleanup sorter did not start watching"
[[ ! -d "$TEST_ROOT/data/.sort-locks/raw-validate-tmp/raw.stale-test" ]] \
  || fail "stale RAW validation scratch directory survived startup"
[[ ! -s "$TEST_ROOT/scratch-order-failures.log" ]] \
  || fail "startup processed incoming files before reclaiming stale RAW scratch"

echo "PASS: startup removed stale RAW validation scratch before processing"

stop_sorter
rm -rf "$TEST_ROOT/data"
mkdir -p "$TEST_ROOT/data/incoming"
for n in $(seq 1 300); do
  : > "$TEST_ROOT/data/incoming/.lock-fixture-$n"
done
: > "$TEST_ROOT/sorter.log"

PATH="$ROOT/tests/fixtures/fast-metadata:$PATH" \
INCOMING="$TEST_ROOT/data/incoming" \
SORTED="$TEST_ROOT/data/sorted" \
QUARANTINE="$TEST_ROOT/data/quarantine" \
STABLE_WAIT=1 \
SORT_WORKERS=8 \
RECONCILE_IDLE=30 \
NOTIFY_INTERVAL=3600 \
RAW_FULL_VALIDATE=0 \
TG_CONFIG="$TEST_ROOT/telegram.json" \
  /bin/bash "$SORTER" > "$TEST_ROOT/sorter.log" 2>&1 &
SORTER_PID=$!

wait_for_log 'watching ' 120 || fail "lock-bucket sorter did not finish startup"
lock_count=$(find "$TEST_ROOT/data/.sort-locks/process" -type f | wc -l)
(( lock_count <= 256 )) || fail "process lock table grew to $lock_count files"

echo "PASS: process claim lock storage remained bounded"

stop_sorter
rm -rf "$TEST_ROOT/data"
mkdir -p "$TEST_ROOT/data/incoming"
declare -A bucket_paths=()
collision_first=""
collision_second=""
for n in $(seq 1 1000); do
  candidate="$TEST_ROOT/data/incoming/bucket-$n.dat"
  key=$(printf '%s' "$candidate" | sha256sum | cut -c1-2)
  previous=${bucket_paths[$key]-}
  if [[ -n "$previous" ]]; then
    collision_first=$previous
    collision_second=$candidate
    break
  fi
  bucket_paths[$key]=$candidate
done
[[ -n "$collision_first" && -n "$collision_second" ]] \
  || fail "could not construct a process-lock bucket collision"
printf 'first bucket collision\n' > "$collision_first"
printf 'second bucket collision\n' > "$collision_second"
: > "$TEST_ROOT/sorter.log"

PATH="$ROOT/tests/fixtures/fast-metadata:$PATH" \
INCOMING="$TEST_ROOT/data/incoming" \
SORTED="$TEST_ROOT/data/sorted" \
QUARANTINE="$TEST_ROOT/data/quarantine" \
STABLE_WAIT=2 \
STABLE_SKIP_AGE=3600 \
SORT_WORKERS=2 \
RECONCILE_IDLE=30 \
NOTIFY_INTERVAL=3600 \
RAW_FULL_VALIDATE=0 \
TG_CONFIG="$TEST_ROOT/telegram.json" \
  /bin/bash "$SORTER" > "$TEST_ROOT/sorter.log" 2>&1 &
SORTER_PID=$!

wait_for_log 'watching ' 20 || fail "same-bucket sorter did not finish startup"
[[ $(find "$TEST_ROOT/data/incoming" -type f | wc -l) -eq 0 ]] \
  || fail "one same-bucket input was discarded during startup"
[[ $(find "$TEST_ROOT/data/sorted" -type f | wc -l) -eq 2 ]] \
  || fail "same-bucket inputs did not both sort"

echo "PASS: distinct paths sharing one claim bucket were serialized"

stop_sorter
for lock_case in root flock-selftest.lock move.lock notify.lock flush.lock; do
  rm -rf "$TEST_ROOT/data"
  mkdir -p "$TEST_ROOT/data/incoming"
  : > "$TEST_ROOT/sorter.log"
  if [[ "$lock_case" == "root" ]]; then
    mkdir -p "$TEST_ROOT/data/control-target"
    printf 'KEEP\n' > "$TEST_ROOT/data/control-target/important"
    ln -s control-target "$TEST_ROOT/data/.sort-locks"
    sentinel="$TEST_ROOT/data/control-target/important"
    expected_lock_log='unsafe lock directory'
  else
    mkdir -p "$TEST_ROOT/data/.sort-locks"
    chmod 0700 "$TEST_ROOT/data/.sort-locks"
    printf 'KEEP\n' > "$TEST_ROOT/data/important"
    ln -s ../important "$TEST_ROOT/data/.sort-locks/$lock_case"
    sentinel="$TEST_ROOT/data/important"
    expected_lock_log='unsafe lock file'
  fi

  INCOMING="$TEST_ROOT/data/incoming" \
  SORTED="$TEST_ROOT/data/sorted" \
  QUARANTINE="$TEST_ROOT/data/quarantine" \
  STABLE_WAIT=1 \
  SORT_WORKERS=1 \
  RECONCILE_IDLE=30 \
  NOTIFY_INTERVAL=3600 \
  RAW_FULL_VALIDATE=0 \
  TG_CONFIG="$TEST_ROOT/telegram.json" \
    /bin/bash "$SORTER" > "$TEST_ROOT/sorter.log" 2>&1 &
  SORTER_PID=$!

  for _ in $(seq 1 150); do
    kill -0 "$SORTER_PID" 2>/dev/null || break
    /bin/sleep 0.1
  done
  if kill -0 "$SORTER_PID" 2>/dev/null; then
    fail "sorter started with unsafe lock path $lock_case"
  fi
  set +e
  wait "$SORTER_PID"
  sorter_rc=$?
  set -e
  SORTER_PID=""
  [[ "$sorter_rc" -eq 2 ]] \
    || fail "unsafe lock path $lock_case exited $sorter_rc instead of 2"
  [[ "$(cat "$sentinel")" == "KEEP" ]] \
    || fail "unsafe lock path $lock_case modified its symlink target"
  grep -q "$expected_lock_log" "$TEST_ROOT/sorter.log" \
    || fail "unsafe lock path $lock_case was not explained"
done

echo "PASS: unsafe shared lock symlinks failed closed without truncation"

stop_sorter
for queue_node in \
  .notify-queue.tsv .notify-queue.tsv.flush.injected .notify-queue.tsv.failed.injected \
  .quarantine-queue.tsv .quarantine-queue.tsv.flush.injected .quarantine-queue.tsv.failed.injected \
  .perm-queue.tsv .perm-queue.tsv.flush.injected .perm-queue.tsv.failed.injected; do
  rm -rf "$TEST_ROOT/data"
  mkdir -p "$TEST_ROOT/data/incoming"
  printf 'QUEUE TARGET — KEEP\n' > "$TEST_ROOT/data/queue-sentinel"
  ln -s queue-sentinel "$TEST_ROOT/data/$queue_node"
  : > "$TEST_ROOT/sorter.log"

  INCOMING="$TEST_ROOT/data/incoming" \
  SORTED="$TEST_ROOT/data/sorted" \
  QUARANTINE="$TEST_ROOT/data/quarantine" \
  STABLE_WAIT=1 \
  SORT_WORKERS=1 \
  RECONCILE_IDLE=30 \
  NOTIFY_INTERVAL=3600 \
  RAW_FULL_VALIDATE=0 \
  TG_CONFIG="$TEST_ROOT/telegram.json" \
    /bin/bash "$SORTER" > "$TEST_ROOT/sorter.log" 2>&1 &
  SORTER_PID=$!

  for _ in $(seq 1 150); do
    kill -0 "$SORTER_PID" 2>/dev/null || break
    /bin/sleep 0.1
  done
  if kill -0 "$SORTER_PID" 2>/dev/null; then
    fail "sorter started with unsafe queue node $queue_node"
  fi
  set +e
  wait "$SORTER_PID"
  sorter_rc=$?
  set -e
  SORTER_PID=""
  [[ "$sorter_rc" -eq 2 ]] \
    || fail "unsafe queue node $queue_node exited $sorter_rc instead of 2"
  [[ "$(cat "$TEST_ROOT/data/queue-sentinel")" == "QUEUE TARGET — KEEP" ]] \
    || fail "unsafe queue node $queue_node modified its symlink target"
  [[ -L "$TEST_ROOT/data/$queue_node" ]] \
    || fail "unsafe queue node $queue_node was unexpectedly replaced"
done

echo "PASS: unsafe notification queue symlinks failed closed without corruption"

stop_sorter
for legacy_queue in .notify-queue.tsv .quarantine-queue.tsv .perm-queue.tsv; do
  for legacy_suffix in '' .flush.injected .failed.injected; do
    legacy_artifact="${legacy_queue}${legacy_suffix}"
    rm -rf "$TEST_ROOT/data"
    mkdir -p "$TEST_ROOT/data/incoming"
    printf 'LEGACY PENDING ROW — KEEP\n' > "$TEST_ROOT/data/$legacy_artifact"
    : > "$TEST_ROOT/sorter.log"

    set +e
    INCOMING="$TEST_ROOT/data/incoming" \
    SORTED="$TEST_ROOT/data/sorted" \
    QUARANTINE="$TEST_ROOT/data/quarantine" \
    STABLE_WAIT=1 \
    STABLE_SKIP_AGE=1 \
    SORT_WORKERS=1 \
    RECONCILE_IDLE=30 \
    NOTIFY_INTERVAL=3600 \
    RAW_FULL_VALIDATE=0 \
    TG_CONFIG="$TEST_ROOT/telegram.json" \
      timeout -k 1 10 /bin/bash "$SORTER" > "$TEST_ROOT/sorter.log" 2>&1
    sorter_rc=$?
    set -e

    [[ "$sorter_rc" -eq 2 ]] \
      || fail "pending legacy queue $legacy_artifact exited $sorter_rc instead of 2"
    [[ "$(cat "$TEST_ROOT/data/$legacy_artifact")" == "LEGACY PENDING ROW — KEEP" ]] \
      || fail "pending legacy queue $legacy_artifact was modified"
    grep -q 'pending legacy queue requires migration with the older sorter stopped' \
      "$TEST_ROOT/sorter.log" \
      || fail "pending legacy queue $legacy_artifact did not explain the safe migration block"
  done
done

echo "PASS: pending legacy base, flush, and failed queues blocked startup without silent loss"

stop_sorter
for private_state_node in \
  notify-queue.tsv quarantine-queue.tsv perm-queue.tsv .notify.pending.injected; do
  rm -rf "$TEST_ROOT/data"
  mkdir -p \
    "$TEST_ROOT/data/incoming" \
    "$TEST_ROOT/data/.sort-locks/queues"
  chmod 0700 "$TEST_ROOT/data/.sort-locks" "$TEST_ROOT/data/.sort-locks/queues"
  printf 'PRIVATE STATE TARGET — KEEP\n' > "$TEST_ROOT/data/state-sentinel"
  ln -s ../../state-sentinel \
    "$TEST_ROOT/data/.sort-locks/queues/$private_state_node"
  : > "$TEST_ROOT/sorter.log"

  set +e
  INCOMING="$TEST_ROOT/data/incoming" \
  SORTED="$TEST_ROOT/data/sorted" \
  QUARANTINE="$TEST_ROOT/data/quarantine" \
  STABLE_WAIT=1 \
  STABLE_SKIP_AGE=1 \
  SORT_WORKERS=1 \
  RECONCILE_IDLE=30 \
  NOTIFY_INTERVAL=3600 \
  RAW_FULL_VALIDATE=0 \
  TG_CONFIG="$TEST_ROOT/telegram.json" \
    timeout -k 1 10 /bin/bash "$SORTER" > "$TEST_ROOT/sorter.log" 2>&1
  sorter_rc=$?
  set -e

  [[ "$sorter_rc" -eq 2 ]] \
    || fail "unsafe private state node $private_state_node exited $sorter_rc instead of 2"
  [[ "$(cat "$TEST_ROOT/data/state-sentinel")" == "PRIVATE STATE TARGET — KEEP" ]] \
    || fail "unsafe private state node $private_state_node modified its target"
  [[ -L "$TEST_ROOT/data/.sort-locks/queues/$private_state_node" ]] \
    || fail "unsafe private state node $private_state_node was unexpectedly replaced"
done

echo "PASS: active queues and pending snapshots rejected symlink substitution"

stop_sorter
rm -rf "$TEST_ROOT/data"
mkdir -p \
  "$TEST_ROOT/data/incoming" \
  "$TEST_ROOT/data/.sort-locks/queues"
chmod 0700 "$TEST_ROOT/data/.sort-locks" "$TEST_ROOT/data/.sort-locks/queues"
printf '01:02:03\tRecovery Camera\traw\trecovered.arw\n' \
  > "$TEST_ROOT/notify-recovery.expected"
printf '01:02:04\trecovered-bad.arw\tfailed validation\n' \
  > "$TEST_ROOT/quarantine-recovery.expected"
printf 'recovered-unreadable.arw\n' > "$TEST_ROOT/permission-recovery.expected"
cp -- "$TEST_ROOT/notify-recovery.expected" \
  "$TEST_ROOT/data/.sort-locks/queues/.notify.pending.interrupted"
cp -- "$TEST_ROOT/quarantine-recovery.expected" \
  "$TEST_ROOT/data/.sort-locks/queues/.quarantine.pending.interrupted"
cp -- "$TEST_ROOT/permission-recovery.expected" \
  "$TEST_ROOT/data/.sort-locks/queues/.permission.pending.interrupted"
chmod 0600 "$TEST_ROOT/data/.sort-locks/queues/".*.pending.interrupted
: > "$TEST_ROOT/sorter.log"

INCOMING="$TEST_ROOT/data/incoming" \
SORTED="$TEST_ROOT/data/sorted" \
QUARANTINE="$TEST_ROOT/data/quarantine" \
STABLE_WAIT=1 \
STABLE_SKIP_AGE=1 \
SORT_WORKERS=1 \
RECONCILE_IDLE=30 \
NOTIFY_INTERVAL=3600 \
RAW_FULL_VALIDATE=0 \
TG_CONFIG="$TEST_ROOT/missing-telegram.json" \
  /bin/bash "$SORTER" > "$TEST_ROOT/sorter.log" 2>&1 &
SORTER_PID=$!

wait_for_log 'watching ' 30 || fail "snapshot-recovery sorter did not start"
cmp -s "$TEST_ROOT/notify-recovery.expected" \
  "$TEST_ROOT/data/.sort-locks/queues/notify-queue.tsv" \
  || fail "notify snapshot was not recovered exactly once"
cmp -s "$TEST_ROOT/quarantine-recovery.expected" \
  "$TEST_ROOT/data/.sort-locks/queues/quarantine-queue.tsv" \
  || fail "quarantine snapshot was not recovered exactly once"
cmp -s "$TEST_ROOT/permission-recovery.expected" \
  "$TEST_ROOT/data/.sort-locks/queues/perm-queue.tsv" \
  || fail "permission snapshot was not recovered exactly once"
if find "$TEST_ROOT/data/.sort-locks/queues" -maxdepth 1 \
  -name '.*.pending.*' -print -quit | grep -q .; then
  fail "recovered pending snapshots were not removed"
fi
[[ $(grep -c 'recovered interrupted .* notification batch' "$TEST_ROOT/sorter.log") -eq 3 ]] \
  || fail "startup did not report all three recovered notification batches"
grep -q 'notifications disabled' "$TEST_ROOT/sorter.log" \
  || fail "snapshot recovery without credentials did not remain notification-disabled"
/bin/sleep 1
while IFS= read -r descendant; do
  descendant_cmd=$(tr '\0' ' ' < "/proc/$descendant/cmdline" 2>/dev/null || true)
  [[ "$descendant_cmd" != *'sleep 3600'* ]] \
    || fail "snapshot recovery without credentials started a notifier"
done < <(list_descendants "$SORTER_PID")

echo "PASS: disabled startup retained recovered rows without loss, duplication, or notifier"

stop_sorter
rm -rf "$TEST_ROOT/data"
mkdir -p "$TEST_ROOT/data/incoming"
printf 'KEEP\n' > "$TEST_ROOT/data/important"
: > "$TEST_ROOT/sorter.log"

INCOMING="$TEST_ROOT/data/incoming" \
SORTED="$TEST_ROOT/data/sorted" \
QUARANTINE="$TEST_ROOT/data/quarantine" \
STABLE_WAIT=1 \
SORT_WORKERS=1 \
RECONCILE_IDLE=30 \
NOTIFY_INTERVAL=3600 \
RAW_FULL_VALIDATE=0 \
TG_CONFIG="$TEST_ROOT/telegram.json" \
  /bin/bash "$SORTER" > "$TEST_ROOT/sorter.log" 2>&1 &
SORTER_PID=$!

wait_for_log 'watching ' 15 || fail "process-lock symlink sorter did not start watching"
claimed_path="$TEST_ROOT/data/incoming/claim-symlink.dat"
claim_key=$(printf '%s' "$claimed_path" | sha256sum | cut -c1-2)
ln -s ../../important "$TEST_ROOT/data/.sort-locks/process/$claim_key.lock"
printf 'claim symlink fixture\n' > "$claimed_path"
wait_for_log 'unsafe lock file' 15 || fail "unsafe process lock was not rejected"
[[ "$(cat "$TEST_ROOT/data/important")" == "KEEP" ]] \
  || fail "process lock symlink modified its target"
[[ -L "$TEST_ROOT/data/.sort-locks/process/$claim_key.lock" ]] \
  || fail "process lock symlink was unexpectedly replaced"
[[ -f "$claimed_path" ]] || fail "file was processed without a safe process claim"

echo "PASS: unsafe process-claim symlink failed closed without truncation"

stop_sorter
rm -rf "$TEST_ROOT/data"
mkdir -p "$TEST_ROOT/data/incoming"
: > "$TEST_ROOT/sorter.log"

PATH="$ROOT/tests/fixtures/no-lock:$PATH" \
INCOMING="$TEST_ROOT/data/incoming" \
SORTED="$TEST_ROOT/data/sorted" \
QUARANTINE="$TEST_ROOT/data/quarantine" \
STABLE_WAIT=1 \
SORT_WORKERS=1 \
RECONCILE_IDLE=30 \
NOTIFY_INTERVAL=3600 \
RAW_FULL_VALIDATE=0 \
TG_CONFIG="$TEST_ROOT/telegram.json" \
  /bin/bash "$SORTER" > "$TEST_ROOT/sorter.log" 2>&1 &
SORTER_PID=$!

for _ in $(seq 1 300); do
  kill -0 "$SORTER_PID" 2>/dev/null || break
  /bin/sleep 0.1
done
if kill -0 "$SORTER_PID" 2>/dev/null; then
  fail "sorter started when flock exclusion was not enforced"
fi
set +e
wait "$SORTER_PID"
sorter_rc=$?
set -e
SORTER_PID=""
[[ "$sorter_rc" -eq 2 ]] || fail "bad-flock startup exited $sorter_rc instead of 2"
grep -q 'filesystem does not enforce flock exclusion' "$TEST_ROOT/sorter.log" \
  || fail "bad-flock startup did not explain the refusal"

echo "PASS: startup refused a filesystem without flock exclusion"

stop_sorter
rm -rf "$TEST_ROOT/data"
mkdir -p "$TEST_ROOT/data/incoming"
: > "$TEST_ROOT/sorter.log"

(
  mkdir -p "$TEST_ROOT/data/.sort-locks"
  chmod 0700 "$TEST_ROOT/data/.sort-locks"
  : > "$TEST_ROOT/data/.sort-locks/flock-selftest.lock"
  chmod 0600 "$TEST_ROOT/data/.sort-locks/flock-selftest.lock"
  exec 9>> "$TEST_ROOT/data/.sort-locks/flock-selftest.lock"
  flock -x 9
  : > "$TEST_ROOT/flock-holder-ready"
  exec /bin/sleep 30
) &
LOCK_HOLDER_PID=$!

for _ in $(seq 1 30); do
  [[ -f "$TEST_ROOT/flock-holder-ready" ]] && break
  /bin/sleep 0.1
done
[[ -f "$TEST_ROOT/flock-holder-ready" ]] || fail "could not hold the flock self-test path"

set +e
PATH="$ROOT/tests/fixtures/log-flock:$PATH" \
TEST_FLOCK_CALL_LOG="$TEST_ROOT/flock-calls.log" \
INCOMING="$TEST_ROOT/data/incoming" \
SORTED="$TEST_ROOT/data/sorted" \
QUARANTINE="$TEST_ROOT/data/quarantine" \
STABLE_WAIT=1 \
SORT_WORKERS=1 \
RECONCILE_IDLE=30 \
NOTIFY_INTERVAL=3600 \
RAW_FULL_VALIDATE=0 \
TG_CONFIG="$TEST_ROOT/telegram.json" \
  timeout -k 5 20 /bin/bash "$SORTER" > "$TEST_ROOT/sorter.log" 2>&1
sorter_rc=$?
set -e
stop_lock_holder
[[ "$sorter_rc" -eq 2 ]] || fail "contended flock self-test exited $sorter_rc instead of 2"
grep -q 'filesystem lock self-test cannot acquire' "$TEST_ROOT/sorter.log" \
  || fail "contended flock startup did not explain the refusal"
grep -Eq '(^|[[:space:]])-w[[:space:]]+2([[:space:]]|$)' "$TEST_ROOT/flock-calls.log" \
  || fail "flock self-test did not request a bounded two-second wait"

echo "PASS: startup flock verification was bounded"

stop_sorter
rm -rf "$TEST_ROOT/data"
mkdir -p "$TEST_ROOT/data/incoming"
printf 'KEEP\n' > "$TEST_ROOT/data/important"
: > "$TEST_ROOT/sorter.log"

(
  mkdir -p "$TEST_ROOT/data/.sort-locks"
  chmod 0700 "$TEST_ROOT/data/.sort-locks"
  : > "$TEST_ROOT/data/.sort-locks/flock-selftest.lock"
  chmod 0600 "$TEST_ROOT/data/.sort-locks/flock-selftest.lock"
  exec 9>> "$TEST_ROOT/data/.sort-locks/flock-selftest.lock"
  flock -x 9
  : > "$TEST_ROOT/probe-flock-holder-ready"
  exec /bin/sleep 30
) &
LOCK_HOLDER_PID=$!
for _ in $(seq 1 30); do
  [[ -f "$TEST_ROOT/probe-flock-holder-ready" ]] && break
  /bin/sleep 0.1
done
[[ -f "$TEST_ROOT/probe-flock-holder-ready" ]] \
  || fail "could not pause startup before the readiness probe"

INCOMING="$TEST_ROOT/data/incoming" \
SORTED="$TEST_ROOT/data/sorted" \
QUARANTINE="$TEST_ROOT/data/quarantine" \
STABLE_WAIT=1 \
SORT_WORKERS=1 \
RECONCILE_IDLE=300 \
NOTIFY_INTERVAL=3600 \
RAW_FULL_VALIDATE=0 \
TG_CONFIG="$TEST_ROOT/telegram.json" \
  /bin/bash "$SORTER" > "$TEST_ROOT/sorter.log" 2>&1 &
SORTER_PID=$!
watch_link="$TEST_ROOT/data/incoming/.sort-watch-ready.$SORTER_PID"
ln -s ../important "$watch_link"
stop_lock_holder

wait_for_log 'watching ' 15 || fail "symlink-safety sorter did not start watching"
[[ "$(cat "$TEST_ROOT/data/important")" == "KEEP" ]] \
  || fail "readiness probe followed a pre-existing symlink and truncated its target"
[[ -L "$watch_link" ]] \
  || fail "readiness probe deleted a pre-existing incoming path"

echo "PASS: watcher readiness probe resisted predictable-path symlinks"

stop_sorter
rm -rf "$TEST_ROOT/data"
mkdir -p "$TEST_ROOT/data/incoming"
: > "$TEST_ROOT/sorter.log"

PATH="$ROOT/tests/fixtures/fast-metadata:$ROOT/tests/fixtures/delayed-watch:$PATH" \
TEST_WATCH_INVOKED_FILE="$TEST_ROOT/watch-invoked" \
TEST_WATCH_PARENT_PROBED_FILE="$TEST_ROOT/watch-parent-probed" \
TEST_WATCH_RELEASE_FILE="$TEST_ROOT/watch-release" \
INCOMING="$TEST_ROOT/data/incoming" \
SORTED="$TEST_ROOT/data/sorted" \
QUARANTINE="$TEST_ROOT/data/quarantine" \
STABLE_WAIT=1 \
STABLE_SKIP_AGE=3600 \
SORT_WORKERS=1 \
RECONCILE_IDLE=300 \
NOTIFY_INTERVAL=3600 \
RAW_FULL_VALIDATE=0 \
TG_CONFIG="$TEST_ROOT/telegram.json" \
  /bin/bash "$SORTER" > "$TEST_ROOT/sorter.log" 2>&1 &
SORTER_PID=$!

for _ in $(seq 1 150); do
  [[ -f "$TEST_ROOT/watch-parent-probed" ]] && break
  /bin/sleep 0.1
done
[[ -f "$TEST_ROOT/watch-invoked" ]] || fail "delayed watcher fixture was not invoked"
[[ -f "$TEST_ROOT/watch-parent-probed" ]] \
  || fail "sorter never emitted its private readiness probe"
assert_log_absent_for 'watching ' 10 \
  || fail "watching was announced while inotify installation was held"
printf 'watch readiness fixture\n' > "$TEST_ROOT/data/incoming/watch-ready.dat"
: > "$TEST_ROOT/watch-release"
wait_for_log 'watching ' 45 || fail "delayed watcher never became ready"
wait_for_count "$TEST_ROOT/data/sorted" 1 30 \
  || fail "watching was announced before inotify was ready"
[[ $(find "$TEST_ROOT/data/sorted" -type f | wc -l) -eq 1 ]] \
  || fail "watch readiness test produced an unexpected output count"

echo "PASS: watching log represented an established inotify watch"

stop_sorter
rm -rf "$TEST_ROOT/data"
mkdir -p "$TEST_ROOT/data/incoming"
: > "$TEST_ROOT/sorter.log"

PATH="$ROOT/tests/fixtures/dead-watch:$PATH" \
INCOMING="$TEST_ROOT/data/incoming" \
SORTED="$TEST_ROOT/data/sorted" \
QUARANTINE="$TEST_ROOT/data/quarantine" \
STABLE_WAIT=1 \
SORT_WORKERS=1 \
RECONCILE_IDLE=30 \
NOTIFY_INTERVAL=3600 \
RAW_FULL_VALIDATE=0 \
TG_CONFIG="$TEST_ROOT/telegram.json" \
  /bin/bash "$SORTER" > "$TEST_ROOT/sorter.log" 2>&1 &
SORTER_PID=$!

wait_for_log 'watching ' 15 \
  || fail "dead watcher never completed readiness before exiting"
for _ in $(seq 1 150); do
  kill -0 "$SORTER_PID" 2>/dev/null || break
  /bin/sleep 0.1
done
if kill -0 "$SORTER_PID" 2>/dev/null; then
  fail "sorter stayed alive after its inotify watcher exited"
fi
set +e
wait "$SORTER_PID"
sorter_rc=$?
set -e
SORTER_PID=""
[[ "$sorter_rc" -eq 1 ]] || fail "dead watcher exited sorter with $sorter_rc instead of 1"
grep -q 'inotifywait exited — exiting for container restart' "$TEST_ROOT/sorter.log" \
  || fail "runtime watcher EOF did not produce a restart-worthy error"
if grep -q 'inotifywait exited before watcher readiness' "$TEST_ROOT/sorter.log"; then
  fail "dead watcher fixture exited before reaching the runtime EOF branch"
fi

echo "PASS: dead inotify watcher exited for container restart"
