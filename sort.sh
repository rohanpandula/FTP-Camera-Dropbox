#!/bin/bash
set -u

INCOMING="${INCOMING:-/data/incoming}"
SORTED="${SORTED:-/data/sorted}"
QUARANTINE="${QUARANTINE:-/data/quarantine}"
NOTIFY_QUEUE="${INCOMING}/../.notify-queue.tsv"
NOTIFY_LOCK="${INCOMING}/../.notify-queue.lock"
TG_CONFIG="${TG_CONFIG:-/etc/telegram.json}"
RECONCILE_IDLE="${RECONCILE_IDLE:-300}"
STUCK_AGE_MIN="${STUCK_AGE_MIN:-60}"
STABLE_WAIT="${STABLE_WAIT:-60}"
NOTIFY_INTERVAL="${NOTIFY_INTERVAL:-300}"   # 5 minutes

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
  local f=$1 a b
  a=$(stat -c %s "$f" 2>/dev/null) || return 1
  sleep "$STABLE_WAIT"
  b=$(stat -c %s "$f" 2>/dev/null) || return 1
  [[ "$a" == "$b" ]]
}

validate_file() {
  local f=$1 type=$2 size head tail
  size=$(stat -c %s "$f" 2>/dev/null) || { log "validate: stat failed"; return 1; }
  case "$type" in
    raw)
      (( size > 5000000 )) || { log "validate: raw too small ($size B)"; return 1; }
      exiftool -Make -Model -s3 "$f" 2>/dev/null | grep -q . || { log "validate: raw exif unreadable"; return 1; }
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

notifier_loop() {
  while true; do
    sleep "$NOTIFY_INTERVAL"
    flush_notify
  done
}

# --- Main process pipeline ---
process() {
  local f=$1
  [[ -f "$f" ]] || return 0
  local base; base=$(basename "$f")
  case "$base" in .*|*.tmp|*.part|*.filepart|Thumbs.db) return 0 ;; esac
  wait_stable "$f" || { log "skip unstable: $base"; return 0; }

  local ext="${base##*.}" name="${base%.*}"
  local type; type=$(get_type "$ext")
  local date; date=$(get_date "$f")

  if ! validate_file "$f" "$type"; then
    if move_with_suffix "$f" "$QUARANTINE/$date" "$base" "$name" "$ext"; then
      if (( DEDUP_HIT )); then
        log "DUP-quar: $base matches existing — deleted incoming"
      else
        log "QUARANTINE: $base -> $date/$(basename "$MOVED_DEST")"
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

reconcile() {
  log "reconcile scan"
  find "$INCOMING" -type f -print0 2>/dev/null | while IFS= read -r -d '' f; do
    process "$f"
  done
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
trap "kill $NOTIFIER_PID 2>/dev/null; exit" SIGTERM SIGINT

log "watching $INCOMING (stable_wait=${STABLE_WAIT}s, dedup=xxhash, notify=${NOTIFY_INTERVAL}s)"
exec 3< <(inotifywait -m -q -e close_write -e moved_to --format '%w%f' "$INCOMING")
while true; do
  if IFS= read -t "$RECONCILE_IDLE" -u 3 -r f; then
    process "$f"
  else
    reconcile
  fi
done
