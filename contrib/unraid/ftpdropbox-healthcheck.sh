#!/bin/bash
# Every-5-min health check for the camera pipeline. Telegram on state CHANGE
# only (no re-spam while something stays broken, plus a recovery ping).
# Each probe produces a human "likely cause" guess — a decision tree covers
# the realistic failure modes, no LLM required.
#
# Install (Unraid): copy to /boot/config/scripts/, cron via
# /boot/config/plugins/dynamix/ftpdropbox.cron, then run `update_cron`.

TG_JSON="${TG_JSON:-/mnt/user/appdata/camera-sorter/telegram.json}"
STATE="${STATE:-/var/lib/ftpdropbox-health/state}"
BACKUP_STAMP="${BACKUP_STAMP:-/var/lib/ftpdropbox-health/backup.stamp}"
CAMERA_INCOMING="${CAMERA_INCOMING:-/mnt/nvmenetworkstorage/FTPDropbox/incoming}"
# Deliberate cutovers may need containers to remain stopped. This path is
# intentionally fixed (not environment-configurable) and its private parent
# and marker metadata are verified before it can disable any Docker start.
readonly MAINTENANCE_MARKER=/var/lib/ftpdropbox-health/maintenance
# Compose calls the FTP container camera-ftp; the established Unraid install
# calls it pure-ftpd. Resolve either name so the same check works for both.
FTP_CONTAINER_CANDIDATES="${FTP_CONTAINER_CANDIDATES:-camera-ftp pure-ftpd}"
SORTER_CONTAINER="${SORTER_CONTAINER:-camera-sorter}"
FRAMEIO_CONTAINER="${FRAMEIO_CONTAINER:-frameio-mirror}"
REQUIRE_FRAMEIO="${REQUIRE_FRAMEIO:-0}"
DOCKER_TIMEOUT="${DOCKER_TIMEOUT:-20}"
if [[ ! "$DOCKER_TIMEOUT" =~ ^[1-9][0-9]*$ ]] \
  || (( ${#DOCKER_TIMEOUT} > 3 )) \
  || (( 10#$DOCKER_TIMEOUT > 300 )); then
  printf 'ftpdropbox-healthcheck: invalid DOCKER_TIMEOUT=%s\n' "$DOCKER_TIMEOUT" >&2
  exit 2
fi

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
    if [ -z "$chat" ]; then
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

problems=""
add() { problems="${problems}• $1
"; }

prepare_state_storage() {
  local state_dir state_meta
  case "$STATE" in /*/*) ;; *) return 1 ;; esac
  state_dir=${STATE%/*}
  if [[ -e "$state_dir" || -L "$state_dir" ]]; then
    [[ -d "$state_dir" && ! -L "$state_dir" ]] || return 1
  else
    install -d -m 0700 -o 0 -g 0 -- "$state_dir" || return 1
  fi
  state_meta=$(stat -c '%u:%g:%a' -- "$state_dir" 2>/dev/null || true)
  [[ "$state_meta" == "0:0:700" ]] || return 1

  if [[ -e "$STATE" || -L "$STATE" ]]; then
    [[ -f "$STATE" && ! -L "$STATE" ]] || return 1
    state_meta=$(stat -c '%u:%g:%a:%h' -- "$STATE" 2>/dev/null || true)
    [[ "$state_meta" == "0:0:600:1" ]] || return 1
  fi
}

commit_state() {
  local payload=$1 state_tmp
  state_tmp=$(mktemp "${STATE}.tmp.XXXXXX") || return 1
  chmod 0600 -- "$state_tmp" \
    && printf '%s' "$payload" > "$state_tmp" \
    && mv -f -- "$state_tmp" "$STATE" \
    && return 0
  rm -f -- "$state_tmp"
  return 1
}

if [[ $(id -u) -ne 0 ]] || ! prepare_state_storage; then
  printf 'ftpdropbox-healthcheck: unsafe state storage: %s\n' "$STATE" >&2
  exit 1
fi

# Do not let a wedged probe accumulate overlapping root cron jobs. The parent
# directory has already been established as root:root 0700, so this lock name
# cannot be planted by an unprivileged local user.
HEALTH_LOCK="${STATE}.lock"
if [[ -L "$HEALTH_LOCK" || ( -e "$HEALTH_LOCK" && ! -f "$HEALTH_LOCK" ) ]]; then
  printf 'ftpdropbox-healthcheck: unsafe run lock: %s\n' "$HEALTH_LOCK" >&2
  exit 1
fi
if [[ ! -e "$HEALTH_LOCK" ]]; then
  (umask 077; set -o noclobber; : > "$HEALTH_LOCK") 2>/dev/null || true
fi
lock_meta=$(stat -c '%u:%g:%a:%h' -- "$HEALTH_LOCK" 2>/dev/null || true)
if [[ -L "$HEALTH_LOCK" || ! -f "$HEALTH_LOCK" || "$lock_meta" != "0:0:600:1" ]]; then
  printf 'ftpdropbox-healthcheck: unsafe run lock: %s\n' "$HEALTH_LOCK" >&2
  exit 1
fi
exec {HEALTH_LOCK_FD}>>"$HEALTH_LOCK" || exit 1
flock -n "$HEALTH_LOCK_FD" || exit 0

# A valid marker suppresses only Docker auto-start mutations. All read-only
# probes, state-change alerts, and the normal zero exit status still apply, so
# an operator gets one explicit "auto-start skipped" report for each stopped
# container. An unsafe marker is reported and ignored: it must never let an
# unprivileged user suppress monitoring or recovery.
maintenance_active=0
if [[ -e "$MAINTENANCE_MARKER" || -L "$MAINTENANCE_MARKER" ]]; then
  maintenance_parent=${MAINTENANCE_MARKER%/*}
  maintenance_parent_meta=$(stat -c '%u:%g:%a' -- "$maintenance_parent" 2>/dev/null || true)
  maintenance_meta=$(stat -c '%u:%g:%a:%h' -- "$MAINTENANCE_MARKER" 2>/dev/null || true)
  if [[ -d "$maintenance_parent" && ! -L "$maintenance_parent" \
    && "$maintenance_parent_meta" == "0:0:700" \
    && -f "$MAINTENANCE_MARKER" && ! -L "$MAINTENANCE_MARKER" \
    && "$maintenance_meta" == "0:0:600:1" ]]; then
    maintenance_active=1
    printf 'ftpdropbox-healthcheck: maintenance interlock active; Docker auto-start disabled, monitoring remains active\n' >&2
  else
    add "maintenance marker is unsafe — ignored; Docker auto-recovery remains enabled"
  fi
fi

docker_cmd() {
  timeout -k 2 "$DOCKER_TIMEOUT" docker "$@"
}

container_exists() {
  docker_cmd inspect "$1" >/dev/null 2>&1
}

resolve_first_container() {
  local candidate
  for candidate in $1; do
    if container_exists "$candidate"; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}

check_container() {
  local c=$1 label=$2 state rc
  state=$(docker_cmd inspect "$c" --format '{{.State.Status}}' 2>/dev/null)
  case "$state" in
    running) : ;;
    restarting)
      add "$label ($c) is crash-looping — check: docker logs $c" ;;
    exited)
      # Self-heal: an exited pipeline container should simply be running.
      # Unraid GUI reboots do not always honor restart policies for CLI-created
      # containers, so start it here and report the state transition.
      rc=$(docker_cmd inspect "$c" --format '{{.State.ExitCode}}' 2>/dev/null)
      if [ "$maintenance_active" = "1" ]; then
        add "$label ($c) is down (exit rc=$rc); maintenance interlock active — auto-start skipped"
      elif docker_cmd start "$c" >/dev/null 2>&1; then
        add "$label ($c) was down (exit rc=$rc, likely reboot) — auto-restarted OK"
      else
        add "$label ($c) exited rc=$rc and auto-restart FAILED — check: docker logs $c"
      fi ;;
    "")
      add "$label container ($c) does not exist — deleted or renamed?" ;;
    *)
      add "$label ($c) in state '$state'" ;;
  esac
}

# --- Docker daemon itself ---
if ! docker_cmd info >/dev/null 2>&1; then
  add "Docker daemon not responding — array stopped, or Docker service crashed"
else
  ftp_container=$(resolve_first_container "$FTP_CONTAINER_CANDIDATES" || true)
  if [ -n "$ftp_container" ]; then
    check_container "$ftp_container" "FTP"
  else
    add "FTP container does not exist (tried: $FTP_CONTAINER_CANDIDATES)"
  fi
  check_container "$SORTER_CONTAINER" "sorter"

  # Frame.io is an opt-in Compose profile. If it exists, check it; if it has
  # never been installed, absence is healthy unless explicitly required.
  frameio_exists=0
  if container_exists "$FRAMEIO_CONTAINER"; then
    frameio_exists=1
    check_container "$FRAMEIO_CONTAINER" "Frame.io mirror"
  elif [ "$REQUIRE_FRAMEIO" = "1" ]; then
    add "Frame.io mirror container ($FRAMEIO_CONTAINER) does not exist"
  fi

  # Seconds since a container started. Used to skip readiness probes on a
  # just-started container: right after a reboot the container is "running"
  # before the daemon inside it has bound its port / opened its socket, which
  # would otherwise fire a false "nothing listens" alert on every boot.
  uptime_secs() {
    local started; started=$(docker_cmd inspect "$1" --format '{{.State.StartedAt}}' 2>/dev/null)
    [ -z "$started" ] && { echo 0; return; }
    local s; s=$(date -d "$started" +%s 2>/dev/null) || { echo 999999; return; }
    echo $(( $(date +%s) - s ))
  }
  GRACE=90  # let a freshly-started container's services come up before probing

  # --- FTP actually listening (probe inside the container: macvlan means the
  # host cannot reach the container IP, so exec is the reliable path). Read
  # /proc/net/tcp directly — the image has no netstat/ss. Port 21 = 0015 hex. ---
  if [ -n "$ftp_container" ] \
     && [ "$(docker_cmd inspect "$ftp_container" --format '{{.State.Status}}' 2>/dev/null)" = "running" ] \
     && [ "$(uptime_secs "$ftp_container")" -gt "$GRACE" ]; then
    if ! docker_cmd exec "$ftp_container" sh -c \
      "awk 'NR > 1 { split(\$2, a, \":\"); if (a[2] == \"0015\" && \$4 == \"0A\") found=1 } END { exit !found }' /proc/net/tcp /proc/net/tcp6 2>/dev/null"; then
      add "$ftp_container runs but nothing listens on :21 — config or crashed daemon inside container"
    fi
  fi

  # --- Mirror answering its own health endpoint ---
  if [ "$frameio_exists" = "1" ] \
     && [ "$(docker_cmd inspect "$FRAMEIO_CONTAINER" --format '{{.State.Status}}' 2>/dev/null)" = "running" ] \
     && [ "$(uptime_secs "$FRAMEIO_CONTAINER")" -gt "$GRACE" ]; then
    if ! docker_cmd exec "$FRAMEIO_CONTAINER" python3 -c "import urllib.request;urllib.request.urlopen('http://127.0.0.1:8000/health',timeout=5)" 2>/dev/null; then
      add "$FRAMEIO_CONTAINER runs but /health does not answer — app wedged; docker restart $FRAMEIO_CONTAINER"
    fi
  fi
fi

# --- Source pool mounted ---
[ -d "$CAMERA_INCOMING" ] || add "FTPDropbox share missing — nvmenetworkstorage pool unmounted?"

# --- Backup freshness (backup script stamps on success/partial) ---
if [[ -e "$BACKUP_STAMP" || -L "$BACKUP_STAMP" ]]; then
  # Reject unsafe node types before reading. Bound both size and read time so a
  # corrupt stamp cannot wedge the monitor or consume unbounded memory.
  stamp_meta=$(stat -c '%u:%g:%a:%h' -- "$BACKUP_STAMP" 2>/dev/null || true)
  stamp_size=$(stat -c %s -- "$BACKUP_STAMP" 2>/dev/null || true)
  if [[ -L "$BACKUP_STAMP" || ! -f "$BACKUP_STAMP" \
    || "$stamp_meta" != "0:0:600:1" || ! "$stamp_size" =~ ^[0-9]+$ \
    || "$stamp_size" -gt 32 ]]; then
    add "nightly backup stamp is unsafe or corrupt — rerun the updated backup script"
  else
    stamp_value=$(timeout -k 1 2 head -c 32 -- "$BACKUP_STAMP" 2>/dev/null || true)
    if [[ ! "$stamp_value" =~ ^[1-9][0-9]{0,10}$ ]]; then
      add "nightly backup stamp is unsafe or corrupt — rerun the updated backup script"
    else
      now_epoch=$(date +%s)
      age=$(( now_epoch - stamp_value ))
      if (( stamp_value > now_epoch + 300 )); then
        add "nightly backup stamp is in the future — system clock or stamp is wrong"
      elif [ "$age" -gt 93600 ]; then  # 26 hours
        add "nightly backup has not completed in $((age/3600))h — cron dead, or backup failing before the stamp"
      fi
    fi
  fi
else
  add "nightly backup has never completed — cron missing, disabled, or failing"
fi

# --- Alert only on state change ---
prev=$(cat "$STATE" 2>/dev/null || echo "")
if [ -n "$problems" ]; then
  if [ "$problems" != "$prev" ]; then
    if tg "🔴 Camera pipeline problem(s):
$problems"; then
      commit_state "$problems"
    fi
  fi
else
  if [ -n "$prev" ]; then
    if tg "🟢 Camera pipeline recovered — all checks passing"; then
      commit_state ""
    fi
  fi
fi
