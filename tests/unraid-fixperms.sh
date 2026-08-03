#!/bin/bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
IMAGE=${TEST_IMAGE:-camera-sorter:candidate-latest}

if [[ ${FIXPERMS_TEST_IN_CONTAINER:-0} != 1 ]]; then
  exec docker run --rm --user 0:0 \
    -e FIXPERMS_TEST_IN_CONTAINER=1 \
    -v "$ROOT:/repo:ro" \
    "$IMAGE" bash /repo/tests/unraid-fixperms.sh
fi

CASE_DIR=$(mktemp -d /tmp/fixperms-test.XXXXXX)
mkdir -p "$CASE_DIR/incoming/nested" "$CASE_DIR/incoming/blocked"
touch \
  "$CASE_DIR/incoming/nested/old.jpg" \
  "$CASE_DIR/incoming/nested/active.jpg" \
  "$CASE_DIR/incoming/nested/owned-unreadable.jpg" \
  "$CASE_DIR/incoming/blocked/owned-readable.jpg" \
  "$CASE_DIR/outside.jpg"
ln "$CASE_DIR/outside.jpg" "$CASE_DIR/incoming/nested/hardlink.jpg"
chown -R 0:0 "$CASE_DIR/incoming" "$CASE_DIR/outside.jpg"
chmod 0700 "$CASE_DIR/incoming/nested"
chmod 0700 "$CASE_DIR/incoming/blocked"
chmod 0600 \
  "$CASE_DIR/incoming/nested/old.jpg" \
  "$CASE_DIR/incoming/nested/active.jpg" \
  "$CASE_DIR/incoming/nested/hardlink.jpg" \
  "$CASE_DIR/outside.jpg"
chown 123:456 "$CASE_DIR/incoming/nested/owned-unreadable.jpg"
chmod 0000 "$CASE_DIR/incoming/nested/owned-unreadable.jpg"
chown 123:456 "$CASE_DIR/incoming/blocked/owned-readable.jpg"
chmod 0644 "$CASE_DIR/incoming/blocked/owned-readable.jpg"
touch -d '2020-01-01 00:00:00 UTC' \
  "$CASE_DIR/incoming/nested/old.jpg" \
  "$CASE_DIR/incoming/nested/owned-unreadable.jpg" \
  "$CASE_DIR/incoming/blocked/owned-readable.jpg" \
  "$CASE_DIR/incoming/nested/hardlink.jpg"

INCOMING="$CASE_DIR/incoming" \
LOG="$CASE_DIR/fix.log" \
TG_JSON="$CASE_DIR/missing.json" \
IDLE_MIN=2 \
SORTER_UID=123 \
SORTER_GID=456 \
bash /repo/contrib/unraid/ftpdropbox-fixperms.sh

[[ $(stat -c '%u:%g:%a' "$CASE_DIR/incoming/nested/old.jpg") == 123:456:664 ]]
[[ $(stat -c '%u:%g:%a' "$CASE_DIR/incoming/nested") == 123:456:775 ]]
[[ $(stat -c '%u:%g:%a' "$CASE_DIR/incoming/nested/active.jpg") == 0:0:600 ]]
[[ $(stat -c '%u:%g:%a' "$CASE_DIR/incoming/nested/owned-unreadable.jpg") == 123:456:664 ]]
[[ $(stat -c '%u:%g:%a' "$CASE_DIR/incoming/blocked") == 123:456:775 ]]
[[ $(stat -c '%u:%g:%a' "$CASE_DIR/incoming/blocked/owned-readable.jpg") == 123:456:644 ]]
[[ $(stat -c '%u:%g:%a:%h' "$CASE_DIR/incoming/nested/hardlink.jpg") == 0:0:600:2 ]]
[[ $(stat -c '%u:%g:%a:%h' "$CASE_DIR/outside.jpg") == 0:0:600:2 ]]
grep -q 'fixed 3 stuck file path' "$CASE_DIR/fix.log"

echo "PASS: only idle wrong-owner/unreadable single-link files and ancestors were repaired"
