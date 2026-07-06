#!/bin/bash
# Nightly FTPDropbox backup: unprotected NVMe pool -> parity-protected array.
# Telegram alert on failure, with a best-guess cause (plain decision tree, no
# LLM needed: the realistic failure modes are enumerable). Silent on success,
# but stamps /var/tmp/ftpdropbox-backup.stamp so the healthcheck can alert if
# backups quietly stop running.
#
# Install (Unraid): copy to /boot/config/scripts/, cron via
# /boot/config/plugins/dynamix/ftpdropbox.cron, then run `update_cron`.

SRC="/mnt/nvmenetworkstorage/FTPDropbox"
# /mnt/user0 = array-only view: bypasses the ssdcache pool the Media share is
# cache-enabled onto. Backups must land on parity, not a RAID0 cache.
DEST="/mnt/user0/Media/Photos/FTPDropbox-Backup"
TG_JSON="/mnt/user/appdata/camera-sorter/telegram.json"
LOG="/var/log/ftpdropbox-backup.log"
STAMP="/var/tmp/ftpdropbox-backup.stamp"

log() { echo "[$(date '+%F %T')] $*" >> "$LOG"; }

tg() {
  local text=$1 token chat
  token=$(sed -n 's/.*"bot_token"[^"]*"\([^"]*\)".*/\1/p' "$TG_JSON" 2>/dev/null)
  chat=$(sed -n 's/.*"chat_id"[^"]*"\([^"]*\)".*/\1/p' "$TG_JSON" 2>/dev/null)
  [ -z "$token" ] || [ -z "$chat" ] && { log "telegram creds unavailable"; return 1; }
  curl -sS -m 15 -X POST "https://api.telegram.org/bot${token}/sendMessage" \
    --data-urlencode "chat_id=${chat}" --data-urlencode "text=${text}" >/dev/null 2>&1
}

fail() {
  local guess=$1
  log "FAILED: $guess"
  tg "🔴 FTPDropbox backup FAILED.
Likely cause: $guess
Log: $LOG on Tower"
  exit 1
}

log "backup starting"

# --- Preflight, each check doubles as the failure guess ---
[ -d "$SRC/sorted" ] || fail "source $SRC/sorted missing — nvmenetworkstorage pool unmounted, renamed, or the NVMe died"
[ -d /mnt/user0/Media ] || fail "array not mounted or Media share gone — is the array started?"
mkdir -p "$DEST" || fail "cannot create $DEST — permissions or read-only filesystem"

avail_kb=$(df -Pk /mnt/user0 | awk 'NR==2 {print $4}')
need_kb=$(du -sk "$SRC/sorted" "$SRC/quarantine" 2>/dev/null | awk '{s+=$1} END {print s}')
if [ -n "$avail_kb" ] && [ -n "$need_kb" ] && [ "$avail_kb" -lt "$need_kb" ]; then
  fail "array almost certainly out of space: need ~$((need_kb/1024/1024))G, only $((avail_kb/1024/1024))G free"
fi

# --- The copy. No --delete: files removed from the library stay in the backup,
# so an accidental (or malicious) mass-delete cannot propagate here. ---
out=$(rsync -a --stats \
  --exclude '.tmp.*' --exclude '.raw-validate-tmp/' --exclude '.notify-queue*' \
  "$SRC/sorted" "$SRC/quarantine" "$DEST/" 2>&1)
rc=$?

case $rc in
  0)
    xfer=$(echo "$out" | sed -n 's/^Number of regular files transferred: //p')
    log "OK — files transferred: ${xfer:-?}"
    date +%s > "$STAMP"
    ;;
  11) fail "disk full or I/O error writing to the array (rsync code 11). Free space now: $(df -h /mnt/user0 | awk 'NR==2 {print $4}')" ;;
  23|24) log "partial (rc=$rc) — some files vanished or were unreadable mid-copy; normal if the sorter was moving files during the run"
         date +%s > "$STAMP" ;;  # partial still counts as a run; next night re-copies stragglers
  30|35) fail "rsync timeout — array disks not spinning up, or extreme load (rc=$rc)" ;;
  *) fail "rsync exited $rc. Last errors: $(echo "$out" | grep -iE 'error|failed' | tail -3 | tr '\n' ' ')" ;;
esac
