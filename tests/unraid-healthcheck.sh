#!/bin/bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
IMAGE=${TEST_IMAGE:-camera-sorter:candidate-latest}

if [[ ${HEALTHCHECK_TEST_IN_CONTAINER:-0} != 1 ]]; then
  exec docker run --rm --user 0:0 \
    -e HEALTHCHECK_TEST_IN_CONTAINER=1 \
    -v "$ROOT:/repo:ro" \
    "$IMAGE" bash /repo/tests/unraid-healthcheck.sh
fi

FIXTURES=/repo/tests/fixtures/healthcheck
SCRIPT=/repo/contrib/unraid/ftpdropbox-healthcheck.sh
MAINTENANCE_MARKER=/var/lib/ftpdropbox-health/maintenance
chmod +x "$FIXTURES/docker" "$FIXTURES/curl" 2>/dev/null || true

new_case() {
  CASE_DIR=$(mktemp -d /tmp/healthcheck-test.XXXXXX)
  install -d -m 0700 -o 0 -g 0 "$CASE_DIR/state" "$CASE_DIR/incoming"
  install -d -m 0700 -o 0 -g 0 "${MAINTENANCE_MARKER%/*}"
  rm -f -- "$MAINTENANCE_MARKER"
  printf '{"bot_token":"test-token","chat_id":-123456}\n' > "$CASE_DIR/tg.json"
  printf '%s\n' "$(date +%s)" > "$CASE_DIR/state/backup.stamp"
  chmod 0600 "$CASE_DIR/tg.json" "$CASE_DIR/state/backup.stamp"
  CURL_LOG="$CASE_DIR/curl.log"
}

run_check() {
  env \
    PATH="$FIXTURES:$PATH" \
    STATE="$CASE_DIR/state/health.state" \
    BACKUP_STAMP="$CASE_DIR/state/backup.stamp" \
    CAMERA_INCOMING="$CASE_DIR/incoming" \
    TG_JSON="$CASE_DIR/tg.json" \
    FAKE_CURL_LOG="$CURL_LOG" \
    "$@" \
    bash "$SCRIPT"
}

new_case
run_check
[[ ! -e "$CASE_DIR/state/health.state" ]]
[[ ! -e "$CURL_LOG" ]]
echo "PASS: Compose FTP name and absent optional Frame.io are healthy"

new_case
run_check FAKE_CAMERA_FTP_PRESENT=0 FAKE_PURE_FTP_PRESENT=1
[[ ! -e "$CASE_DIR/state/health.state" ]]
echo "PASS: legacy pure-ftpd name is accepted"

new_case
run_check REQUIRE_FRAMEIO=1
grep -q 'Frame.io mirror container' "$CASE_DIR/state/health.state"
grep -q -- 'chat_id=-123456' "$CURL_LOG"
echo "PASS: required Frame.io absence alerts and numeric chat ID is sent"

new_case
run_check FAKE_FTP_LISTEN_RC=1
grep -q 'nothing listens on :21' "$CASE_DIR/state/health.state"
echo "PASS: failed FTP readiness probe alerts"

new_case
install -m 0600 -o 0 -g 0 /dev/null "$MAINTENANCE_MARKER"
run_check FAKE_SORTER_STATUS=exited FAKE_START_RC=91
grep -q 'maintenance interlock active.*auto-start skipped' "$CASE_DIR/state/health.state"
if grep -q 'auto-restart FAILED' "$CASE_DIR/state/health.state"; then
  echo "FAIL: maintenance interlock attempted an auto-start" >&2
  exit 1
fi
echo "PASS: valid maintenance marker keeps an exited sorter stopped"

new_case
install -m 0600 -o 0 -g 0 /dev/null "$CASE_DIR/marker-target"
ln -s "$CASE_DIR/marker-target" "$MAINTENANCE_MARKER"
run_check FAKE_SORTER_STATUS=exited
grep -q 'maintenance marker is unsafe' "$CASE_DIR/state/health.state"
grep -q 'auto-restarted OK' "$CASE_DIR/state/health.state"
echo "PASS: symlinked maintenance marker is rejected and recovery remains enabled"

new_case
mkfifo "$MAINTENANCE_MARKER"
SECONDS=0
run_check FAKE_SORTER_STATUS=exited
(( SECONDS < 4 ))
grep -q 'maintenance marker is unsafe' "$CASE_DIR/state/health.state"
grep -q 'auto-restarted OK' "$CASE_DIR/state/health.state"
echo "PASS: FIFO maintenance marker cannot block or suppress recovery"

new_case
install -m 0600 -o 0 -g 0 /dev/null "$MAINTENANCE_MARKER"
ln "$MAINTENANCE_MARKER" "$CASE_DIR/marker-hardlink"
run_check FAKE_SORTER_STATUS=exited
grep -q 'maintenance marker is unsafe' "$CASE_DIR/state/health.state"
grep -q 'auto-restarted OK' "$CASE_DIR/state/health.state"
echo "PASS: hard-linked maintenance marker is rejected and recovery remains enabled"

new_case
install -m 0600 -o 99 -g 100 /dev/null "$MAINTENANCE_MARKER"
run_check FAKE_SORTER_STATUS=exited
grep -q 'maintenance marker is unsafe' "$CASE_DIR/state/health.state"
grep -q 'auto-restarted OK' "$CASE_DIR/state/health.state"
echo "PASS: non-root maintenance marker is rejected and recovery remains enabled"

new_case
install -m 0644 -o 0 -g 0 /dev/null "$MAINTENANCE_MARKER"
run_check FAKE_SORTER_STATUS=exited
grep -q 'maintenance marker is unsafe' "$CASE_DIR/state/health.state"
grep -q 'auto-restarted OK' "$CASE_DIR/state/health.state"
echo "PASS: permissive maintenance marker is rejected and recovery remains enabled"

new_case
run_check REQUIRE_FRAMEIO=1 FAKE_CURL_RC=7 || true
[[ ! -e "$CASE_DIR/state/health.state" ]]
echo "PASS: transport failure does not suppress a retry"

new_case
run_check REQUIRE_FRAMEIO=1 'FAKE_CURL_BODY={"ok":false}' || true
[[ ! -e "$CASE_DIR/state/health.state" ]]
echo "PASS: Telegram ok:false does not suppress a retry"

new_case
printf 'old problem\n' > "$CASE_DIR/state/health.state"
chmod 0600 "$CASE_DIR/state/health.state"
run_check
[[ ! -s "$CASE_DIR/state/health.state" ]]
echo "PASS: delivered recovery clears state atomically"

new_case
printf 'do not overwrite\n' > "$CASE_DIR/victim"
ln -s "$CASE_DIR/victim" "$CASE_DIR/state/health.state"
if run_check; then
  echo "FAIL: unsafe state symlink was accepted" >&2
  exit 1
fi
grep -qx 'do not overwrite' "$CASE_DIR/victim"
echo "PASS: unsafe state symlink is rejected"

new_case
SECONDS=0
run_check DOCKER_TIMEOUT=1 FAKE_DOCKER_SLEEP=5
(( SECONDS < 4 ))
grep -q 'Docker daemon not responding' "$CASE_DIR/state/health.state"
echo "PASS: wedged Docker daemon is bounded"

new_case
mkfifo "$CASE_DIR/unsafe-fifo"
run_check "BACKUP_STAMP=$CASE_DIR/unsafe-fifo"
grep -q 'backup stamp is unsafe or corrupt' "$CASE_DIR/state/health.state"
echo "PASS: FIFO backup stamp is rejected without blocking"

new_case
mkfifo "$CASE_DIR/unsafe-fifo"
ln -s "$CASE_DIR/unsafe-fifo" "$CASE_DIR/unsafe-stamp"
run_check "BACKUP_STAMP=$CASE_DIR/unsafe-stamp"
grep -q 'backup stamp is unsafe or corrupt' "$CASE_DIR/state/health.state"
echo "PASS: symlink-to-FIFO backup stamp is rejected without blocking"

new_case
printf '%s\n' "$(( $(date +%s) + 86400 ))" > "$CASE_DIR/state/backup.stamp"
chmod 0600 "$CASE_DIR/state/backup.stamp"
run_check
grep -q 'backup stamp is in the future' "$CASE_DIR/state/health.state"
echo "PASS: future backup stamp is rejected"

echo "All Unraid healthcheck tests passed."
