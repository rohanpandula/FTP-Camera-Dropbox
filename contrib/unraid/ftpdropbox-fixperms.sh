#!/bin/bash
# Auto-heal ownership on incoming/. Files copied in as another UID (e.g. an SMB
# drop as 502:games 600) are unreadable by the sorter's configured UID, which would
# otherwise leave them stuck (the sorter's readability guard flags them but
# can't chown — it runs non-root). This root cron chowns them to SORTER_UID and
# SORTER_GID (99:100 by default) so the sorter can read and sort them.
#
# Safety: only touches files idle for >IDLE_MIN minutes, so a file still being
# written over SMB (smbd holds it as the copying user) is never chowned
# mid-transfer — that would make smbd lose write access and break the copy.
#
# Idempotent and silent when there's nothing to fix (chowns nothing, sends
# nothing). Notifies once per fix event.
#
# Install (Unraid): /boot/config/scripts/, cron entry every 2 min.

INCOMING="${INCOMING:-/mnt/nvmenetworkstorage/FTPDropbox/incoming}"
TG_JSON="${TG_JSON:-/mnt/user/appdata/camera-sorter/telegram.json}"
LOG="${LOG:-/var/log/ftpdropbox-fixperms.log}"
IDLE_MIN="${IDLE_MIN:-2}"
SORTER_UID="${SORTER_UID:-99}"
SORTER_GID="${SORTER_GID:-100}"

[[ "$SORTER_UID" =~ ^[0-9]+$ && "$SORTER_GID" =~ ^[0-9]+$ ]] || exit 2
[[ "$IDLE_MIN" =~ ^[1-9][0-9]*$ ]] || exit 2

log() { echo "[$(date '+%F %T')] $*" >> "$LOG"; }

tg() {
  local text=$1 token chat response
  if command -v jq >/dev/null 2>&1; then
    token=$(jq -er '.bot_token | select(type == "string" and length > 0)' \
      "$TG_JSON" 2>/dev/null || true)
    chat=$(jq -er \
      '.chat_id | if type == "number" then tostring elif type == "string" and length > 0 then . else empty end' \
      "$TG_JSON" 2>/dev/null || true)
  else
    token=$(sed -n 's/.*"bot_token"[^"]*"\([^"]*\)".*/\1/p' "$TG_JSON" 2>/dev/null)
    chat=$(sed -n 's/.*"chat_id"[^"]*"\([^"]*\)".*/\1/p' "$TG_JSON" 2>/dev/null)
    if [[ -z "$chat" ]]; then
      chat=$(sed -n 's/.*"chat_id"[[:space:]]*:[[:space:]]*\(-\{0,1\}[0-9][0-9]*\).*/\1/p' \
        "$TG_JSON" 2>/dev/null)
    fi
  fi
  [ -z "$token" ] || [ -z "$chat" ] && return 1
  response=$(curl -fsS -m 15 -X POST "https://api.telegram.org/bot${token}/sendMessage" \
    --data-urlencode "chat_id=${chat}" --data-urlencode "text=${text}" 2>/dev/null) \
    || return 1
  if command -v jq >/dev/null 2>&1; then
    jq -e '.ok == true' >/dev/null 2>&1 <<< "$response"
  else
    grep -Eq '"ok"[[:space:]]*:[[:space:]]*true' <<< "$response"
  fi
}

[[ -d "$INCOMING" && ! -L "$INCOMING" ]] || exit 0
INCOMING_REAL=$(realpath -e -- "$INCOMING") || exit 1

repair_ancestor_dirs() {
  local candidate=$1
  local current=${candidate%/*} dir_fd dir_ref pinned dir_state
  ancestor_repaired=0
  while true; do
    case "$current" in
      "$INCOMING_REAL"|"$INCOMING_REAL"/*) ;;
      *) return 1 ;;
    esac
    [[ -d "$current" && ! -L "$current" ]] || return 1
    if ! exec {dir_fd}<"$current"; then
      return 1
    fi
    dir_ref="/proc/$BASHPID/fd/$dir_fd"
    pinned=$(realpath -e -- "$dir_ref" 2>/dev/null || true)
    if [[ "$pinned" != "$current" ]]; then
      exec {dir_fd}<&-
      return 1
    fi
    dir_state=$(stat -Lc '%u:%g:%a' -- "$dir_ref" 2>/dev/null || true)
    if [[ "$dir_state" != "${SORTER_UID}:${SORTER_GID}:775" ]]; then
      if ! chown "${SORTER_UID}:${SORTER_GID}" -- "$dir_ref" \
        || ! chmod 0775 -- "$dir_ref"; then
        exec {dir_fd}<&-
        return 1
      fi
      ancestor_repaired=1
    fi
    exec {dir_fd}<&-
    [[ "$current" == "$INCOMING_REAL" ]] && return 0
    current=${current%/*}
  done
}

# Apply the idle/wrong-owner predicate to the actual mutation, not only to a
# preliminary count. One stale offender must never cause an actively uploading
# neighbour to be recursively chowned or chmodded. Recheck immediately before
# each chown, use NUL delimiters, and `-h` so a final-component symlink swap
# cannot redirect root's chown to its target. Changing ownership is sufficient:
# even mode 0600 becomes readable by the sorter once it owns the file.
fixed=0
while IFS= read -r -d '' candidate; do
  [[ -f "$candidate" && ! -L "$candidate" ]] || continue
  file_fd=""
  if ! exec {file_fd}<"$candidate"; then
    continue
  fi
  file_ref="/proc/$BASHPID/fd/$file_fd"
  pinned=$(realpath -e -- "$file_ref" 2>/dev/null || true)
  file_id=$(stat -Lc '%d:%i' -- "$file_ref" 2>/dev/null || true)
  file_links=$(stat -Lc %h -- "$file_ref" 2>/dev/null || true)
  mtime=$(stat -Lc %Y -- "$file_ref" 2>/dev/null || true)
  file_owner=$(stat -Lc %u -- "$file_ref" 2>/dev/null || true)
  file_mode=$(stat -Lc %a -- "$file_ref" 2>/dev/null || true)
  now=$(date +%s)
  if [[ "$pinned" != "$candidate" || -z "$file_id" || "$file_links" != 1 \
    || ! "$mtime" =~ ^[0-9]+$ || $((now - mtime)) -le $((IDLE_MIN * 60)) \
    || ! "$file_owner" =~ ^[0-9]+$ || ! "$file_mode" =~ ^[0-7]{1,4}$ ]]; then
    exec {file_fd}<&-
    continue
  fi
  # A correctly owned/readable file can still be stuck behind an old root-owned
  # 0700 directory. Repair and verify the pinned ancestors before deciding the
  # leaf itself needs no work.
  if ! repair_ancestor_dirs "$candidate"; then
    exec {file_fd}<&-
    continue
  fi
  if [[ "$file_owner" == "$SORTER_UID" ]] \
    && (( (8#$file_mode & 0400) != 0 )); then
    fixed=$((fixed + ancestor_repaired))
    exec {file_fd}<&-
    continue
  fi
  if chown "${SORTER_UID}:${SORTER_GID}" -- "$file_ref" 2>/dev/null \
    && chmod 0664 -- "$file_ref" 2>/dev/null \
    && [[ "$(stat -c '%d:%i' -- "$candidate" 2>/dev/null)" == "$file_id" ]] \
    && [[ "$(stat -Lc %u -- "$file_ref" 2>/dev/null)" == "$SORTER_UID" ]]; then
    fixed=$((fixed + 1))
  fi
  exec {file_fd}<&-
done < <(
  find "$INCOMING_REAL" -type f ! -name '.*' \
    -mmin +"$IDLE_MIN" -print0 2>/dev/null
)

(( fixed > 0 )) || exit 0
log "fixed $fixed stuck file path(s) (leaf ownership/read mode or ancestor traversal, idle>${IDLE_MIN}m)"
tg "🔧 Auto-fixed permissions on $fixed stuck file path(s) in incoming. They'll sort on the next scan (within ~5 min)." || true
