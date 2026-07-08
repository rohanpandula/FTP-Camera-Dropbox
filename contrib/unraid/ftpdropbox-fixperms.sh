#!/bin/bash
# Auto-heal ownership on incoming/. Files copied in as another UID (e.g. an SMB
# drop as 502:games 600) are unreadable by the sorter's UID 99, which would
# otherwise leave them stuck (the sorter's readability guard flags them but
# can't chown — it runs non-root). This root cron chowns them to 99:100 so the
# sorter can read and sort them.
#
# Safety: only touches files idle for >IDLE_MIN minutes, so a file still being
# written over SMB (smbd holds it as the copying user) is never chowned
# mid-transfer — that would make smbd lose write access and break the copy.
#
# Idempotent and silent when there's nothing to fix (chowns nothing, sends
# nothing). Notifies once per fix event.
#
# Install (Unraid): /boot/config/scripts/, cron entry every 2 min.

INCOMING="/mnt/nvmenetworkstorage/FTPDropbox/incoming"
TG_JSON="/mnt/user/appdata/camera-sorter/telegram.json"
LOG="/var/log/ftpdropbox-fixperms.log"
IDLE_MIN="${IDLE_MIN:-2}"
SORTER_UID=99

log() { echo "[$(date '+%F %T')] $*" >> "$LOG"; }

tg() {
  local text=$1 token chat
  token=$(sed -n 's/.*"bot_token"[^"]*"\([^"]*\)".*/\1/p' "$TG_JSON" 2>/dev/null)
  chat=$(sed -n 's/.*"chat_id"[^"]*"\([^"]*\)".*/\1/p' "$TG_JSON" 2>/dev/null)
  [ -z "$token" ] || [ -z "$chat" ] && return 1
  curl -sS -m 15 -X POST "https://api.telegram.org/bot${token}/sendMessage" \
    --data-urlencode "chat_id=${chat}" --data-urlencode "text=${text}" >/dev/null 2>&1
}

[ -d "$INCOMING" ] || exit 0

# Count files needing a fix: not owned by the sorter AND idle long enough to be
# a finished copy (not an in-flight SMB write).
bad=$(find "$INCOMING" -type f ! -uid "$SORTER_UID" ! -name '.*' -mmin +"$IDLE_MIN" 2>/dev/null | wc -l)
[ "$bad" -eq 0 ] && exit 0

log "found $bad unreadable file(s) (uid!=$SORTER_UID, idle>${IDLE_MIN}m) — fixing"

# chown the whole tree (cheap and idempotent; already-99 files are a no-op) so
# nested dropped folders are covered too. Then normalize modes to group-writable
# (also keeps them deletable over SMB). -R is fine: SORTED/QUARANTINE live
# outside incoming, so this can't touch the sorted library.
chown -R "${SORTER_UID}:100" "$INCOMING" 2>/dev/null
find "$INCOMING" -type d -exec chmod 775 {} + 2>/dev/null
find "$INCOMING" -type f ! -name '.*' -exec chmod 664 {} + 2>/dev/null

log "fixed $bad file(s)"
tg "🔧 Auto-fixed ownership on $bad file(s) in incoming that were dropped with the wrong permissions. They'll sort on the next scan (within ~5 min)."
