#!/bin/bash
set -u

# Group-writable by default so files/dirs the sorter creates are deletable over
# SMB (Unraid maps SMB users into the `users` group). Combined with running the
# container as 99:100 (nobody:users), output lands as nobody:users 664/775.
umask 002

INCOMING="${INCOMING:-/data/incoming}"
SORTED="${SORTED:-/data/sorted}"
QUARANTINE="${QUARANTINE:-/data/quarantine}"
NOTIFY_QUEUE="${INCOMING}/../.notify-queue.tsv"
QUAR_QUEUE="${INCOMING}/../.quarantine-queue.tsv"
PERM_QUEUE="${INCOMING}/../.perm-queue.tsv"
NOTIFY_LOCK="${INCOMING}/../.notify-queue.lock"
TG_CONFIG="${TG_CONFIG:-/etc/telegram.json}"
RECONCILE_IDLE="${RECONCILE_IDLE:-300}"
STUCK_AGE_MIN="${STUCK_AGE_MIN:-60}"
STABLE_WAIT="${STABLE_WAIT:-60}"
STABLE_SKIP_AGE="${STABLE_SKIP_AGE:-3600}"  # skip the wait for files older than this (seconds)
NOTIFY_INTERVAL="${NOTIFY_INTERVAL:-300}"   # 5 minutes
RAW_MIN_BYTES_DEFAULT="${RAW_MIN_BYTES_DEFAULT:-5000000}"
RAW_MIN_BYTES_NIKON_ZF="${RAW_MIN_BYTES_NIKON_ZF:-25000000}"
RAW_MIN_BYTES_SONY_A7CR="${RAW_MIN_BYTES_SONY_A7CR:-40000000}"
RAW_MIN_BYTES_GFX100="${RAW_MIN_BYTES_GFX100:-80000000}"
RAW_FULL_VALIDATE="${RAW_FULL_VALIDATE:-1}"
RAW_VALIDATE_TIMEOUT="${RAW_VALIDATE_TIMEOUT:-240}"
RAW_VALIDATE_TMPDIR="${RAW_VALIDATE_TMPDIR:-${INCOMING}/../.raw-validate-tmp}"

log() { echo "[$(date '+%F %T')] $*" >&2; }

# --- Telegram credentials (loaded from mounted JSON, never echoed) ---
TG_TOKEN=""
TG_CHAT_ID=""
if [[ -f "$TG_CONFIG" ]]; then
  TG_TOKEN=$(jq -r '.bot_token' "$TG_CONFIG" 2>/dev/null || true)
  TG_CHAT_ID=$(jq -r '.chat_id' "$TG_CONFIG" 2>/dev/null || true)
fi

telegram_send() {
  local text=$1
  [[ -z "$TG_TOKEN" || -z "$TG_CHAT_ID" ]] && { log "telegram: no credentials, skipping"; return 1; }
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
    jpg|jpeg|heic|heif)                       echo jpg ;;
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

camera_model() {
  sanitize "$(exiftool -Model -s3 "$1" 2>/dev/null | head -n1)"
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

  start_size=$(stat -c %s "$f" 2>/dev/null) || {
    log "validate: raw disappeared before decode"
    return 75
  }

  output=$(timeout "$RAW_VALIDATE_TIMEOUT" raw-identify "$f" 2>&1)
  rc=$?
  if (( rc != 0 )); then
    detail=$(sanitize "$output")
    [[ -n "$detail" ]] || detail="exit $rc"
    if (( rc == 124 )); then
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
  # dir on /data so validation output never lands in incoming or Docker overlay.
  link="$tmp/input.${ext}"
  if ! ln -s "$f" "$link"; then
    rm -rf "$tmp"
    log "validate: cannot stage raw validation input"
    return 1
  fi

  output=$(cd "$tmp" && timeout "$RAW_VALIDATE_TIMEOUT" simple_dcraw -D -4 "$(basename "$link")" 2>&1)
  rc=$?
  rm -rf "$tmp"

  end_size=$(stat -c %s "$f" 2>/dev/null) || {
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
    if (( rc == 124 )); then
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

  output=$(timeout "$RAW_VALIDATE_TIMEOUT" exiftool -validate -warning -error -a "$f" 2>&1)
  rc=$?
  if (( rc == 124 )); then
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

get_date() {
  local f=$1 d
  d=$(exiftool -d '%Y-%m-%d' -DateTimeOriginal -CreateDate -ModifyDate -s3 "$f" 2>/dev/null | head -n1)
  # Accept ONLY a strict YYYY-MM-DD with plausible components, else fall back to
  # mtime. Prevents a malformed/attacker EXIF date (e.g. "2024-13-99" or text with
  # a leading year) from becoming a bogus path component.
  if [[ "$d" =~ ^([0-9]{4})-([0-9]{2})-([0-9]{2})$ ]]; then
    local y=${BASH_REMATCH[1]} mo=${BASH_REMATCH[2]} da=${BASH_REMATCH[3]}
    if (( y >= 1990 && y <= 2100 && 10#$mo >= 1 && 10#$mo <= 12 && 10#$da >= 1 && 10#$da <= 31 )); then
      echo "$d"; return
    fi
    log "exif date out-of-range '$d' for $(basename "$f") — using mtime"
  elif [[ -n "$d" && "$d" != "-" ]]; then
    log "exif date malformed '$d' for $(basename "$f") — using mtime"
  else
    log "no exif date for $(basename "$f") — using mtime"
  fi
  stat -c %y "$f" | cut -d' ' -f1
}

get_camera() {
  local f=$1 make model
  make=$(sanitize "$(exiftool -Make -s3 "$f" 2>/dev/null | head -n1)")
  model=$(sanitize "$(exiftool -Model -s3 "$f" 2>/dev/null | head -n1)")
  # collapse redundant words (NIKON CORPORATION NIKON Z 9 -> NIKON Z 9)
  if [[ -n "$make" && "$model" == "$make "* ]]; then
    echo "$model"
  elif [[ -n "$make" && -n "$model" ]]; then
    echo "$make $model"
  elif [[ -n "$model" ]]; then
    echo "$model"
  else
    echo "Unknown"
  fi
}

wait_stable() {
  local f=$1 a b now mtime
  a=$(stat -c %s "$f" 2>/dev/null) || return 1
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
    return 0
  fi
  sleep "$STABLE_WAIT"
  b=$(stat -c %s "$f" 2>/dev/null) || return 1
  [[ "$a" == "$b" ]]
}

validate_file() {
  local f=$1 type=$2 size head tail ext model min_size
  size=$(stat -c %s "$f" 2>/dev/null) || { log "validate: stat failed"; return 1; }
  case "$type" in
    raw)
      ext="${f##*.}"
      model=$(camera_model "$f")
      min_size=$(raw_min_bytes_for "$model" "$ext")
      (( size >= min_size )) || {
        log "validate: raw too small for ${model:-Unknown} ($size B < $min_size B)"
        return 1
      }
      exiftool -Make -Model -s3 "$f" 2>/dev/null | grep -q . || { log "validate: raw exif unreadable"; return 1; }
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
    video)
      (( size > 500000 )) || { log "validate: video too small ($size B)"; return 1; }
      exiftool -FileType -s3 "$f" 2>/dev/null | grep -q . || { log "validate: video unreadable"; return 1; }
      ;;
    other) ;;
  esac
  return 0
}

xhash() { xxhsum "$1" 2>/dev/null | cut -d' ' -f1; }

MOVED_DEST=""
DEDUP_HIT=0
move_with_suffix() {
  local f=$1 dir=$2 base=$3 name=$4 ext=$5
  mkdir -p "$dir"
  DEDUP_HIT=0
  local dest="$dir/$base" n=2
  local new_size new_hash=""
  new_size=$(stat -c %s "$f" 2>/dev/null) || return 1
  while [[ -e "$dest" ]]; do
    local existing_size; existing_size=$(stat -c %s "$dest" 2>/dev/null)
    if [[ "$existing_size" == "$new_size" ]]; then
      [[ -z "$new_hash" ]] && new_hash=$(xhash "$f")
      local existing_hash; existing_hash=$(xhash "$dest")
      if [[ -n "$new_hash" && "$new_hash" == "$existing_hash" ]]; then
        rm "$f"; MOVED_DEST="$dest"; DEDUP_HIT=1; return 0
      fi
    fi
    dest="$dir/${name}_${n}.${ext}"
    n=$((n+1))
    (( n > 999 )) && { log "FAIL too many collisions: $base"; return 1; }
  done
  if mv "$f" "$dest"; then MOVED_DEST="$dest"; return 0
  else log "FAIL mv: $f -> $dest"; return 1; fi
}

# --- Notification queue (append per successful sort, flush every NOTIFY_INTERVAL seconds) ---
enqueue_notify() {
  local camera type basename
  camera=$(sanitize "$1"); type=$(sanitize "$2"); basename=$(sanitize "$3")
  {
    flock -x 200
    printf '%s\t%s\t%s\t%s\n' "$(date '+%H:%M:%S')" "$camera" "$type" "$basename" >> "$NOTIFY_QUEUE"
  } 200>"$NOTIFY_LOCK"
}

flush_notify() {
  [[ -s "$NOTIFY_QUEUE" ]] || return 0
  local rotated="${NOTIFY_QUEUE}.flush.$$"
  {
    flock -x 200
    [[ -s "$NOTIFY_QUEUE" ]] || return 0
    mv "$NOTIFY_QUEUE" "$rotated"
  } 200>"$NOTIFY_LOCK"
  [[ -f "$rotated" ]] || return 0

  local total per_camera msg
  total=$(wc -l < "$rotated")
  per_camera=$(awk -F'\t' '{c[$2]++} END {for (k in c) printf "%d\t%s\n", c[k], k}' "$rotated" \
    | sort -rn | awk -F'\t' '{printf "• %d × %s\n", $1, $2}')
  msg=$(printf "📸 %d file(s) uploaded in last 5 min:\n%s" "$total" "$per_camera")

  if telegram_send "$msg"; then
    rm "$rotated"
  else
    mv "$rotated" "${NOTIFY_QUEUE}.failed.$(date +%s)"
  fi
}

# Quarantines get their own batched alert. Usually a quarantined file is a
# partial from an aborted FTP transfer and the camera re-sends a good copy
# minutes later — the message says so, so a ping isn't a panic. A name that
# never shows up in a later "uploaded" batch is the one to go pull from card.
enqueue_quar() {
  local basename reason
  basename=$(sanitize "$1"); reason=$(sanitize "$2")
  {
    flock -x 200
    printf '%s\t%s\t%s\n' "$(date '+%H:%M:%S')" "$basename" "$reason" >> "$QUAR_QUEUE"
  } 200>"$NOTIFY_LOCK"
}

flush_quar() {
  [[ -s "$QUAR_QUEUE" ]] || return 0
  local rotated="${QUAR_QUEUE}.flush.$$"
  {
    flock -x 200
    [[ -s "$QUAR_QUEUE" ]] || return 0
    mv "$QUAR_QUEUE" "$rotated"
  } 200>"$NOTIFY_LOCK"
  [[ -f "$rotated" ]] || return 0

  local total names msg
  total=$(wc -l < "$rotated")
  names=$(awk -F'\t' '{print "• " $2 " (" $3 ")"}' "$rotated" | head -10)
  (( total > 10 )) && names="$names
…and $((total-10)) more"
  msg=$(printf "⚠️ %d file(s) quarantined:\n%s\nUsually aborted transfers — the camera normally re-sends a good copy. If a name never lands in sorted/, recover it from the SD card." "$total" "$names")

  if telegram_send "$msg"; then
    rm "$rotated"
  else
    mv "$rotated" "${QUAR_QUEUE}.failed.$(date +%s)"
  fi
}

# Permission-problem queue. Separate from quarantine because the file is NOT
# bad — it's just unreadable by our UID and sitting in incoming. Dedup by
# filename (enqueue_perm returns 1 if already queued) so a file that survives
# multiple reconcile passes only logs/alerts once per flush window.
enqueue_perm() {
  local basename; basename=$(sanitize "$1")
  {
    flock -x 200
    if grep -qxF "$basename" "$PERM_QUEUE" 2>/dev/null; then
      return 1
    fi
    printf '%s\n' "$basename" >> "$PERM_QUEUE"
  } 200>"$NOTIFY_LOCK"
}

flush_perm() {
  [[ -s "$PERM_QUEUE" ]] || return 0
  local rotated="${PERM_QUEUE}.flush.$$"
  {
    flock -x 200
    [[ -s "$PERM_QUEUE" ]] || return 0
    mv "$PERM_QUEUE" "$rotated"
  } 200>"$NOTIFY_LOCK"
  [[ -f "$rotated" ]] || return 0

  local total names msg
  total=$(wc -l < "$rotated")
  names=$(sed 's/^/• /' "$rotated" | head -8)
  (( total > 8 )) && names="$names
…and $((total-8)) more"
  msg=$(printf "🔒 %d file(s) in incoming are UNREADABLE (wrong ownership, not corrupt):\n%s\nThey are safe but won't sort until fixed. On the Tower run:\nchown -R 99:100 /mnt/nvmenetworkstorage/FTPDropbox/incoming" "$total" "$names")

  if telegram_send "$msg"; then
    rm "$rotated"
  else
    mv "$rotated" "${PERM_QUEUE}.failed.$(date +%s)"
  fi
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
  local f=$1
  [[ -f "$f" ]] || return 0
  local base; base=$(basename "$f")
  case "$base" in .*|*.tmp|*.part|*.filepart|Thumbs.db) return 0 ;; esac
  # Readability guard: a file dropped in via SMB/scp as another UID with
  # owner-only perms (e.g. 700 502:games) is invisible to our UID. Without
  # this check every unreadable file fails EXIF validation and gets
  # quarantined as "corrupt" — mixing perfectly good files into quarantine.
  # Instead, leave it in incoming and raise a distinct, throttled alert so the
  # user fixes ownership (chown -R 99:100). The stuck-file scan keeps it visible.
  if [[ ! -r "$f" ]]; then
    if enqueue_perm "$base"; then
      log "UNREADABLE (permissions): $base — left in incoming, needs chown to 99:100"
    fi
    return 0
  fi
  wait_stable "$f" || { log "skip unstable: $base"; return 0; }

  local ext="${base##*.}" name="${base%.*}"
  local type; type=$(get_type "$ext")
  local date; date=$(get_date "$f")

  if validate_file "$f" "$type"; then
    :
  else
    local validation_rc=$?
    if (( validation_rc == 75 )); then
      log "skip unstable: $base changed during validation"
      return 0
    fi
    if move_with_suffix "$f" "$QUARANTINE/$date" "$base" "$name" "$ext"; then
      if (( DEDUP_HIT )); then
        log "DUP-quar: $base matches existing — deleted incoming"
      else
        log "QUARANTINE: $base -> $date/$(basename "$MOVED_DEST")"
        enqueue_quar "$base" "failed validation"
      fi
    fi
    return 0
  fi

  if move_with_suffix "$f" "$SORTED/$date/$type" "$base" "$name" "$ext"; then
    if (( DEDUP_HIT )); then
      log "DUP: $base matches existing $date/$type/$(basename "$MOVED_DEST") — deleted incoming"
      # don't notify on dups; they're noise
    else
      log "ok: $base -> $date/$type/$(basename "$MOVED_DEST")"
      local camera; camera=$(get_camera "$MOVED_DEST")
      enqueue_notify "$camera" "$type" "$base"
    fi
  fi
}

# Remove empty subdirectories left behind after files are sorted out of a
# dropped folder tree. mindepth 1 guarantees INCOMING itself is never removed.
prune_empty_dirs() {
  find "$INCOMING" -mindepth 1 -type d -empty -delete 2>/dev/null
}

reconcile() {
  log "reconcile scan"
  # -type f recurses the whole tree: a true dropbox processes files at any depth,
  # not just the top level. process() handles arbitrary source paths (spaces,
  # colons, nested dirs) — it sorts by EXIF date regardless of folder layout.
  find "$INCOMING" -type f -print0 2>/dev/null | while IFS= read -r -d '' f; do
    process "$f"
  done
  prune_empty_dirs
  find "$INCOMING" -type f -mmin +"$STUCK_AGE_MIN" -print0 2>/dev/null | while IFS= read -r -d '' f; do
    log "STUCK >${STUCK_AGE_MIN}min: $(basename "$f")"
  done
}

mkdir -p "$INCOMING" "$SORTED" "$QUARANTINE"
log "startup drain of $INCOMING"
reconcile

# Online ping
if [[ -n "$TG_TOKEN" && -n "$TG_CHAT_ID" ]]; then
  telegram_send "🟢 camera-sorter online (aggregating every ${NOTIFY_INTERVAL}s)" || log "startup ping failed"
else
  log "no telegram config at $TG_CONFIG — notifications disabled"
fi

# Background notifier
notifier_loop &
NOTIFIER_PID=$!
trap 'kill "$NOTIFIER_PID" 2>/dev/null; exit' SIGTERM SIGINT

log "watching $INCOMING (stable_wait=${STABLE_WAIT}s, raw_full_validate=${RAW_FULL_VALIDATE}, dedup=xxhash, notify=${NOTIFY_INTERVAL}s)"
# -r watches the whole tree, so files dropped into subfolders fire live events
# too. inotifywait auto-adds watches on new subdirectories as they appear.
# SORTED/QUARANTINE/tmp all live OUTSIDE incoming (siblings under /data), so the
# recursive watch never sees our own output — no feedback loop.
exec 3< <(inotifywait -m -r -q -e close_write -e moved_to --format '%w%f' "$INCOMING")
while true; do
  if IFS= read -t "$RECONCILE_IDLE" -u 3 -r f; then
    if [[ -d "$f" ]]; then
      # A whole folder was moved/created in one operation — inotify reports the
      # directory, not the files already inside it. Sweep its contents now
      # instead of waiting for the next reconcile.
      find "$f" -type f -print0 2>/dev/null | while IFS= read -r -d '' sub; do
        process "$sub"
      done
      prune_empty_dirs
    else
      process "$f"
      # If that file was the last one in a dropped subfolder, tidy the empties.
      case "$f" in "$INCOMING"/*/*) prune_empty_dirs ;; esac
    fi
  else
    reconcile
  fi
done
