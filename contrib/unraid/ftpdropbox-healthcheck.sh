#!/bin/bash
# Every-5-min health check for the camera pipeline. Telegram on state CHANGE
# only (no re-spam while something stays broken, plus a recovery ping).
# Each probe produces a human "likely cause" guess — a decision tree covers
# the realistic failure modes, no LLM required.
#
# Install (Unraid): copy to /boot/config/scripts/, cron via
# /boot/config/plugins/dynamix/ftpdropbox.cron, then run `update_cron`.

TG_JSON="/mnt/user/appdata/camera-sorter/telegram.json"
STATE="/var/tmp/ftpdropbox-health.state"
BACKUP_STAMP="/var/tmp/ftpdropbox-backup.stamp"

tg() {
  local text=$1 token chat
  token=$(sed -n 's/.*"bot_token"[^"]*"\([^"]*\)".*/\1/p' "$TG_JSON" 2>/dev/null)
  chat=$(sed -n 's/.*"chat_id"[^"]*"\([^"]*\)".*/\1/p' "$TG_JSON" 2>/dev/null)
  [ -z "$token" ] || [ -z "$chat" ] && return 1
  curl -sS -m 15 -X POST "https://api.telegram.org/bot${token}/sendMessage" \
    --data-urlencode "chat_id=${chat}" --data-urlencode "text=${text}" >/dev/null 2>&1
}

problems=""
add() { problems="${problems}• $1
"; }

# --- Docker daemon itself ---
if ! docker info >/dev/null 2>&1; then
  add "Docker daemon not responding — array stopped, or Docker service crashed"
else
  # --- The three containers ---
  for c in pure-ftpd camera-sorter frameio-mirror; do
    state=$(docker inspect "$c" --format '{{.State.Status}}' 2>/dev/null)
    case "$state" in
      running) : ;;
      restarting)
        add "$c is crash-looping — check: docker logs $c" ;;
      exited)
        # Self-heal: an exited pipeline container should simply be running.
        # Unraid GUI reboots don't reliably honor Docker restart policies for
        # CLI-created containers, so start it ourselves and say what happened.
        rc=$(docker inspect "$c" --format '{{.State.ExitCode}}' 2>/dev/null)
        if docker start "$c" >/dev/null 2>&1; then
          add "$c was down (exit rc=$rc, likely reboot) — auto-restarted OK"
        else
          add "$c exited rc=$rc and auto-restart FAILED — check: docker logs $c"
        fi ;;
      "")
        add "$c container does not exist — deleted or renamed?" ;;
      *)
        add "$c in state '$state'" ;;
    esac
  done

  # --- FTP actually listening (probe inside the container: macvlan means the
  # host cannot reach the container IP, so exec is the reliable path). Read
  # /proc/net/tcp directly — the image has no netstat/ss. Port 21 = 0015 hex. ---
  if [ "$(docker inspect pure-ftpd --format '{{.State.Status}}' 2>/dev/null)" = "running" ]; then
    if ! docker exec pure-ftpd sh -c "grep -q ':0015 ' /proc/net/tcp /proc/net/tcp6 2>/dev/null"; then
      add "pure-ftpd runs but nothing listens on :21 — config or crashed daemon inside container"
    fi
  fi

  # --- Mirror answering its own health endpoint ---
  if [ "$(docker inspect frameio-mirror --format '{{.State.Status}}' 2>/dev/null)" = "running" ]; then
    if ! docker exec frameio-mirror python3 -c "import urllib.request;urllib.request.urlopen('http://127.0.0.1:8000/health',timeout=5)" 2>/dev/null; then
      add "frameio-mirror runs but /health does not answer — app wedged; docker restart frameio-mirror"
    fi
  fi
fi

# --- Source pool mounted ---
[ -d /mnt/nvmenetworkstorage/FTPDropbox/incoming ] || add "FTPDropbox share missing — nvmenetworkstorage pool unmounted?"

# --- Backup freshness (backup script stamps on success/partial) ---
if [ -f "$BACKUP_STAMP" ]; then
  age=$(( $(date +%s) - $(cat "$BACKUP_STAMP" 2>/dev/null || echo 0) ))
  if [ "$age" -gt 93600 ]; then  # 26 hours
    add "nightly backup has not completed in $((age/3600))h — cron dead, or backup failing before the stamp"
  fi
fi

# --- Alert only on state change ---
prev=$(cat "$STATE" 2>/dev/null || echo "")
if [ -n "$problems" ]; then
  if [ "$problems" != "$prev" ]; then
    printf '%s' "$problems" > "$STATE"
    tg "🔴 Camera pipeline problem(s):
$problems"
  fi
else
  if [ -n "$prev" ]; then
    : > "$STATE"
    tg "🟢 Camera pipeline recovered — all checks passing"
  fi
fi
