#!/bin/bash
# Nightly FTPDropbox backup: unprotected NVMe pool -> parity-protected array.
# Telegram alert on failure, with a best-guess cause (plain decision tree, no
# LLM needed: the realistic failure modes are enumerable). Silent on success,
# but stamps /var/lib/ftpdropbox-health/backup.stamp so the healthcheck can alert if
# backups quietly stop running.
#
# Install (Unraid): copy to /boot/config/scripts/, cron via
# /boot/config/plugins/dynamix/ftpdropbox.cron, then run `update_cron`.

SRC="${SRC:-/mnt/nvmenetworkstorage/FTPDropbox}"
# /mnt/user0 = array-only view: bypasses the ssdcache pool the Media share is
# cache-enabled onto. Backups must land on parity, not a RAID0 cache.
DEST="${DEST:-/mnt/user0/Media/Photos/FTPDropbox-Backup}"
TG_JSON="${TG_JSON:-/mnt/user/appdata/camera-sorter/telegram.json}"
LOG="${LOG:-/var/log/ftpdropbox-backup.log}"
STAMP="${STAMP:-/var/lib/ftpdropbox-health/backup.stamp}"

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
  [ -z "$token" ] || [ -z "$chat" ] && { log "telegram creds unavailable"; return 1; }
  response=$(curl -fsS -m 15 -X POST "https://api.telegram.org/bot${token}/sendMessage" \
    --data-urlencode "chat_id=${chat}" --data-urlencode "text=${text}" 2>/dev/null) \
    || return 1
  if command -v jq >/dev/null 2>&1; then
    jq -e '.ok == true' >/dev/null 2>&1 <<< "$response"
  else
    grep -Eq '"ok"[[:space:]]*:[[:space:]]*true' <<< "$response"
  fi
}

prepare_stamp_storage() {
  local stamp_dir stamp_meta
  case "$STAMP" in /*/*) ;; *) return 1 ;; esac
  stamp_dir=${STAMP%/*}
  if [[ -e "$stamp_dir" || -L "$stamp_dir" ]]; then
    [[ -d "$stamp_dir" && ! -L "$stamp_dir" ]] || return 1
  else
    install -d -m 0700 -o 0 -g 0 -- "$stamp_dir" || return 1
  fi
  stamp_meta=$(stat -c '%u:%g:%a' -- "$stamp_dir" 2>/dev/null || true)
  [[ "$stamp_meta" == "0:0:700" ]] || return 1
  if [[ -e "$STAMP" || -L "$STAMP" ]]; then
    [[ -f "$STAMP" && ! -L "$STAMP" ]] || return 1
    stamp_meta=$(stat -c '%u:%g:%a:%h' -- "$STAMP" 2>/dev/null || true)
    [[ "$stamp_meta" == "0:0:600:1" ]] || return 1
  fi
}

write_stamp() {
  local stamp_tmp
  stamp_tmp=$(mktemp "${STAMP}.tmp.XXXXXX") || return 1
  chmod 0600 -- "$stamp_tmp" \
    && date +%s > "$stamp_tmp" \
    && mv -f -- "$stamp_tmp" "$STAMP" \
    && return 0
  rm -f -- "$stamp_tmp"
  return 1
}

safe_existing_dir() {
  local path=$1 canonical
  [[ "$path" == /* && "$path" != / && -d "$path" && ! -L "$path" ]] || return 1
  canonical=$(realpath -e -- "$path" 2>/dev/null) || return 1
  [[ "$canonical" == "$path" ]]
}

prepare_destination() {
  local canonical
  [[ "$DEST" == /* && "$DEST" != / ]] || return 1

  # realpath -m resolves every existing ancestor even when the leaf has not
  # been created yet. A mismatch means the configured path contains a symlink,
  # redundant component, or other alias that is unsafe for a root-run backup.
  canonical=$(realpath -m -- "$DEST" 2>/dev/null) || return 1
  [[ "$canonical" == "$DEST" ]] || return 1
  mkdir -p -- "$DEST" || return 1
  safe_existing_dir "$DEST"
}

dir_identity() {
  local identity
  identity=$(stat -Lc '%d:%i:%F' -- "$1" 2>/dev/null) || return 1
  [[ "$identity" == *:directory ]] || return 1
  printf '%s\n' "$identity"
}

verify_dir_binding() {
  local path=$1 pinned_ref=$2 expected=$3 path_identity pinned_identity
  safe_existing_dir "$path" || return 1
  path_identity=$(dir_identity "$path") || return 1
  pinned_identity=$(dir_identity "$pinned_ref") || return 1
  [[ "$path_identity" == "$expected" && "$pinned_identity" == "$expected" ]]
}

verify_backup_paths() {
  verify_dir_binding "$SORTED_PATH" "$SORTED_REF" "$SORTED_ID" \
    && verify_dir_binding "$QUARANTINE_PATH" "$QUARANTINE_REF" "$QUARANTINE_ID" \
    && verify_dir_binding "$DEST" "$DEST_REF" "$DEST_ID" \
    && verify_dir_binding "$DEST_SORTED_PATH" "$DEST_SORTED_REF" "$DEST_SORTED_ID" \
    && verify_dir_binding "$DEST_QUARANTINE_PATH" "$DEST_QUARANTINE_REF" "$DEST_QUARANTINE_ID"
}

fail() {
  local guess=$1
  log "FAILED: $guess"
  tg "🔴 FTPDropbox backup FAILED.
Likely cause: $guess
Log: $LOG on Tower" || true
  exit 1
}

log "backup starting"

[[ $(id -u) -eq 0 ]] || fail "backup must run as root"
prepare_stamp_storage || fail "unsafe backup stamp storage: $STAMP"

# --- Preflight, each check doubles as the failure guess ---
SORTED_PATH="$SRC/sorted"
QUARANTINE_PATH="$SRC/quarantine"
safe_existing_dir "$SORTED_PATH" || fail "source $SORTED_PATH is missing, symlinked, or has an unsafe non-canonical ancestor"
safe_existing_dir "$QUARANTINE_PATH" || fail "source $QUARANTINE_PATH is missing, symlinked, or has an unsafe non-canonical ancestor"
[ -d /mnt/user0/Media ] || fail "array not mounted or Media share gone — is the array started?"
prepare_destination || fail "destination $DEST is unavailable, symlinked, or has an unsafe non-canonical ancestor"

# Keep exact directory inodes open for the whole copy. rsync receives only
# these pinned /proc handles, so renaming or replacing a configured pathname
# cannot redirect a root-run backup into an attacker-selected tree.
exec 10<"$SORTED_PATH" || fail "cannot pin source directory $SORTED_PATH"
exec 11<"$QUARANTINE_PATH" || fail "cannot pin source directory $QUARANTINE_PATH"
exec 12<"$DEST" || fail "cannot pin destination directory $DEST"
SORTED_REF="/proc/$$/fd/10"
QUARANTINE_REF="/proc/$$/fd/11"
DEST_REF="/proc/$$/fd/12"

DEST_SORTED_PATH="$DEST/sorted"
DEST_QUARANTINE_PATH="$DEST/quarantine"
if [[ -e "$DEST_SORTED_PATH" || -L "$DEST_SORTED_PATH" ]]; then
  safe_existing_dir "$DEST_SORTED_PATH" || fail "destination directory $DEST_SORTED_PATH is unsafe"
else
  mkdir -- "$DEST_REF/sorted" || fail "cannot create destination directory $DEST_SORTED_PATH"
fi
if [[ -e "$DEST_QUARANTINE_PATH" || -L "$DEST_QUARANTINE_PATH" ]]; then
  safe_existing_dir "$DEST_QUARANTINE_PATH" || fail "destination directory $DEST_QUARANTINE_PATH is unsafe"
else
  mkdir -- "$DEST_REF/quarantine" || fail "cannot create destination directory $DEST_QUARANTINE_PATH"
fi

exec 13<"$DEST_REF/sorted" || fail "cannot pin destination directory $DEST_SORTED_PATH"
exec 14<"$DEST_REF/quarantine" || fail "cannot pin destination directory $DEST_QUARANTINE_PATH"
DEST_SORTED_REF="/proc/$$/fd/13"
DEST_QUARANTINE_REF="/proc/$$/fd/14"

SORTED_ID=$(dir_identity "$SORTED_REF") || fail "cannot identify source directory $SORTED_PATH"
QUARANTINE_ID=$(dir_identity "$QUARANTINE_REF") || fail "cannot identify source directory $QUARANTINE_PATH"
DEST_ID=$(dir_identity "$DEST_REF") || fail "cannot identify destination directory $DEST"
DEST_SORTED_ID=$(dir_identity "$DEST_SORTED_REF") || fail "cannot identify destination directory $DEST_SORTED_PATH"
DEST_QUARANTINE_ID=$(dir_identity "$DEST_QUARANTINE_REF") || fail "cannot identify destination directory $DEST_QUARANTINE_PATH"
verify_backup_paths || fail "a source or destination path changed during backup setup; no data was copied"

# --- The copy. No --delete: files removed from the library stay in the backup,
# so an accidental (or malicious) mass-delete cannot propagate here. ---
out=$(rsync -a --stats \
  --exclude '.tmp.*' --exclude '.raw-validate-tmp/' --exclude '.notify-queue*' \
  -- "$SORTED_REF/" "$DEST_SORTED_REF/" 2>&1)
rc=$?
if [[ $rc -eq 0 ]]; then
  verify_backup_paths || fail "a source or destination path changed during backup; backup stamp was not refreshed"
  quarantine_out=$(rsync -a --stats \
    --exclude '.tmp.*' --exclude '.raw-validate-tmp/' --exclude '.notify-queue*' \
    -- "$QUARANTINE_REF/" "$DEST_QUARANTINE_REF/" 2>&1)
  rc=$?
  out+=$'\n'"$quarantine_out"
fi

case $rc in
  0)
    verify_backup_paths || fail "a source or destination path changed during backup; backup stamp was not refreshed"
    xfer=$(printf '%s\n' "$out" | awk -F ': ' \
      '/^Number of regular files transferred: / { total += $2; found = 1 } END { if (found) print total }')
    log "OK — files transferred: ${xfer:-?}"
    write_stamp || fail "could not update the protected backup stamp $STAMP"
    ;;
  11) fail "disk full or I/O error writing to the array (rsync code 11). Free space now: $(df -h /mnt/user0 | awk 'NR==2 {print $4}')" ;;
  23) fail "rsync reported a partial transfer due to an error (code 23) — check permissions and I/O errors; backup stamp was not refreshed" ;;
  24) fail "rsync reported vanished source files (code 24) — investigate unexpected source changes; backup stamp was not refreshed" ;;
  30|35) fail "rsync timeout — array disks not spinning up, or extreme load (rc=$rc)" ;;
  *) fail "rsync exited $rc. Last errors: $(echo "$out" | grep -iE 'error|failed' | tail -3 | tr '\n' ' ')" ;;
esac
