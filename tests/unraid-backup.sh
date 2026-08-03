#!/bin/bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
IMAGE=${TEST_IMAGE:-camera-sorter:candidate-latest}

if [[ ${BACKUP_TEST_IN_CONTAINER:-0} != 1 ]]; then
  exec docker run --rm --user 0:0 \
    -e BACKUP_TEST_IN_CONTAINER=1 \
    -v "$ROOT:/repo:ro" \
    "$IMAGE" bash /repo/tests/unraid-backup.sh
fi

mkdir -p /mnt/user0/Media

rsync() {
  local argc=$# source_operand destination_operand
  local -a args=("$@")
  argc=$#
  source_operand=${args[argc-2]}
  destination_operand=${args[argc-1]}

  if [[ $argc -lt 3 || ${args[argc-3]} != -- \
    || ! $source_operand =~ ^/proc/[0-9]+/fd/[0-9]+/$ \
    || ! $destination_operand =~ ^/proc/[0-9]+/fd/[0-9]+/$ ]]; then
    printf 'unsafe or unpinned rsync operands\n' >&2
    return 97
  fi

  if [[ ${FAKE_SWAP_SOURCE:-0} == 1 && ! -e "${SRC}.source-swap-done" ]]; then
    : > "${SRC}.source-swap-done"
    mv -- "$SRC/sorted" "$SRC/sorted.before-swap"
    mkdir -- "$SRC/sorted"
  fi

  if [[ ${FAKE_SWAP_DEST:-0} == 1 && ! -e "${DEST}.destination-swap-done" ]]; then
    : > "${DEST}.destination-swap-done"
    mkdir -- "$DEST_ATTACK_TARGET"
    mv -- "$DEST" "${DEST}.before-swap"
    ln -s -- "$DEST_ATTACK_TARGET" "$DEST"
    touch -- "${destination_operand}fake-copy"
  fi

  printf 'Number of regular files transferred: 0\n'
  return "${FAKE_RSYNC_RC:-0}"
}

df() {
  if [[ ${FAKE_LOW_SPACE:-0} == 1 && $* == "-Pk /mnt/user0" ]]; then
    printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\n'
    printf 'fake 1024 1024 0 100%% /mnt/user0\n'
    return 0
  fi
  command df "$@"
}

du() {
  if [[ ${FAKE_LOW_SPACE:-0} == 1 && ${1:-} == -sk ]]; then
    printf '1024\tfake-library\n'
    return 0
  fi
  command du "$@"
}
export -f rsync df du

new_case() {
  CASE_DIR=$(mktemp -d /tmp/backup-test.XXXXXX)
  mkdir -p "$CASE_DIR/source/sorted" "$CASE_DIR/source/quarantine" "$CASE_DIR/state"
  chmod 0700 "$CASE_DIR/state"
}

run_backup() {
  env \
    SRC="$CASE_DIR/source" \
    DEST="$CASE_DIR/destination" \
    TG_JSON="$CASE_DIR/missing.json" \
    LOG="$CASE_DIR/backup.log" \
    STAMP="$CASE_DIR/state/backup.stamp" \
    "$@" \
    bash /repo/contrib/unraid/ftpdropbox-backup.sh
}

new_case
run_backup
[[ $(stat -c '%u:%g:%a:%h' "$CASE_DIR/state/backup.stamp") == 0:0:600:1 ]]
grep -Eq '^[0-9]+$' "$CASE_DIR/state/backup.stamp"
echo "PASS: successful backup writes a protected stamp"

new_case
run_backup FAKE_LOW_SPACE=1
grep -Eq '^[0-9]+$' "$CASE_DIR/state/backup.stamp"
grep -q 'OK' "$CASE_DIR/backup.log"
echo "PASS: incremental backup is not blocked by whole-library free-space estimates"

new_case
printf '1\n' > "$CASE_DIR/state/backup.stamp"
chmod 0600 "$CASE_DIR/state/backup.stamp"
if run_backup FAKE_RSYNC_RC=23; then
  echo "FAIL: rsync code 23 was accepted" >&2
  exit 1
fi
grep -qx '1' "$CASE_DIR/state/backup.stamp"
grep -q 'code 23' "$CASE_DIR/backup.log"
echo "PASS: rsync code 23 fails without refreshing the stamp"

new_case
printf '1\n' > "$CASE_DIR/state/backup.stamp"
chmod 0600 "$CASE_DIR/state/backup.stamp"
if run_backup FAKE_RSYNC_RC=24; then
  echo "FAIL: rsync code 24 was accepted" >&2
  exit 1
fi
grep -qx '1' "$CASE_DIR/state/backup.stamp"
grep -q 'code 24' "$CASE_DIR/backup.log"
echo "PASS: rsync code 24 fails without refreshing the stamp"

new_case
rmdir "$CASE_DIR/source/quarantine"
if run_backup; then
  echo "FAIL: missing quarantine source was accepted" >&2
  exit 1
fi
[[ ! -e "$CASE_DIR/state/backup.stamp" ]]
echo "PASS: missing quarantine source fails closed"

new_case
mkdir "$CASE_DIR/sorted-target"
rmdir "$CASE_DIR/source/sorted"
ln -s -- "$CASE_DIR/sorted-target" "$CASE_DIR/source/sorted"
if run_backup; then
  echo "FAIL: symlinked sorted source root was accepted" >&2
  exit 1
fi
[[ ! -e "$CASE_DIR/state/backup.stamp" ]]
echo "PASS: symlinked sorted source root is rejected"

new_case
mv -- "$CASE_DIR/source" "$CASE_DIR/source-real"
ln -s -- "$CASE_DIR/source-real" "$CASE_DIR/source"
if run_backup; then
  echo "FAIL: symlinked source ancestor was accepted" >&2
  exit 1
fi
[[ ! -e "$CASE_DIR/state/backup.stamp" ]]
echo "PASS: symlinked source ancestor is rejected"

new_case
printf '1\n' > "$CASE_DIR/state/backup.stamp"
chmod 0600 "$CASE_DIR/state/backup.stamp"
if run_backup FAKE_SWAP_SOURCE=1; then
  echo "FAIL: source path substitution during rsync was accepted" >&2
  exit 1
fi
grep -qx '1' "$CASE_DIR/state/backup.stamp"
grep -q 'changed during backup' "$CASE_DIR/backup.log"
echo "PASS: source path substitution prevents a success stamp"

new_case
printf '1\n' > "$CASE_DIR/state/backup.stamp"
chmod 0600 "$CASE_DIR/state/backup.stamp"
DEST_ATTACK_TARGET="$CASE_DIR/destination-attacker"
if run_backup FAKE_SWAP_DEST=1 DEST_ATTACK_TARGET="$DEST_ATTACK_TARGET"; then
  echo "FAIL: destination path substitution during rsync was accepted" >&2
  exit 1
fi
grep -qx '1' "$CASE_DIR/state/backup.stamp"
[[ ! -e "$DEST_ATTACK_TARGET/sorted/fake-copy" ]]
[[ -e "$CASE_DIR/destination.before-swap/sorted/fake-copy" ]]
grep -q 'changed during backup' "$CASE_DIR/backup.log"
echo "PASS: destination substitution cannot redirect the copy or refresh the stamp"

new_case
mkdir "$CASE_DIR/destination-target"
ln -s -- "$CASE_DIR/destination-target" "$CASE_DIR/destination"
if run_backup; then
  echo "FAIL: symlinked destination root was accepted" >&2
  exit 1
fi
[[ ! -e "$CASE_DIR/state/backup.stamp" ]]
echo "PASS: symlinked destination root is rejected"

new_case
printf 'do not overwrite\n' > "$CASE_DIR/victim"
ln -s "$CASE_DIR/victim" "$CASE_DIR/state/backup.stamp"
if run_backup; then
  echo "FAIL: unsafe backup stamp symlink was accepted" >&2
  exit 1
fi
grep -qx 'do not overwrite' "$CASE_DIR/victim"
echo "PASS: unsafe backup stamp symlink is rejected"

echo "All Unraid backup tests passed."
