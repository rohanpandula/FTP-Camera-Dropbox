#!/bin/bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TEST_TOKEN="$$-$RANDOM"
COMPOSE_PROJECT="camera-data-init-smoke-$TEST_TOKEN"
DATA_VOLUME="camera_data_init_race_data_$TEST_TOKEN"
STATE_VOLUME="camera_data_init_race_state_$TEST_TOKEN"
VICTIM_VOLUME="camera_data_init_race_victim_$TEST_TOKEN"

cleanup() {
  local volume
  case "$COMPOSE_PROJECT" in
    camera-data-init-smoke-*)
      docker compose --project-directory "$ROOT" -f "$ROOT/docker-compose.yml" \
        --project-name "$COMPOSE_PROJECT" --profile frameio \
        down -v --remove-orphans \
        >/dev/null 2>&1 || true
      ;;
  esac
  for volume in "$DATA_VOLUME" "$STATE_VOLUME" "$VICTIM_VOLUME"; do
    case "$volume" in
      camera_data_init_race_*) docker volume rm -f "$volume" >/dev/null 2>&1 || true ;;
    esac
  done
}
trap cleanup EXIT

for volume in "$DATA_VOLUME" "$STATE_VOLUME" "$VICTIM_VOLUME"; do
  docker volume create "$volume" >/dev/null
done

docker run --rm \
  -v "$DATA_VOLUME:/data" \
  -v "$STATE_VOLUME:/state" \
  -v "$VICTIM_VOLUME:/victim" \
  alpine:3.24.1 /bin/sh -ec '
    mkdir -p /data/incoming /data/sorted/race-target /data/quarantine
    chown 0:0 /victim
    chmod 0711 /victim
    printf "%s\n" "do-not-touch" > /victim/marker-victim
    chmod 0640 /victim/marker-victim
  '

compose_data_init_command() {
  docker compose --project-directory "$ROOT" -f "$ROOT/docker-compose.yml" \
    config --format json \
    | jq -r '.services["data-init"].command[2]' \
    | sed 's/\$\$/\$/g'
}

race_chown_prelude() {
  # The single-quoted variables below are intentionally expanded by the
  # container shell after this generated function is piped to it.
  # shellcheck disable=SC2016
  printf '%s\n' \
    'chown() {' \
    '  chown_last=' \
    '  chown_attack=0' \
    '  for chown_arg in "$@"; do chown_last=$chown_arg; done' \
    '  case "$chown_last" in' \
    '    /data/sorted/race-target) chown_attack=1 ;;' \
    '    /proc/*/fd/9)' \
    '      chown_fd_target=$(/usr/bin/readlink "$chown_last" 2>/dev/null || true)' \
    '      [ "$chown_fd_target" = /data/sorted/race-target ] && chown_attack=1' \
    '      ;;' \
    '  esac' \
    '  if [ "$chown_attack" -eq 1 ] && [ ! -e /data/.race-fired ]; then' \
    '    /bin/mv /data/sorted/race-target /data/sorted/race-target.original' \
    '    /bin/ln -s /victim /data/sorted/race-target' \
    '    : > /data/.race-fired' \
    '  fi' \
    '  /bin/chown "$@"' \
    '}'
}

victim_before=$(docker run --rm -v "$VICTIM_VOLUME:/victim" \
  alpine:3.24.1 stat -c '%u:%g:%a' /victim)
victim_file_before=$(docker run --rm -v "$VICTIM_VOLUME:/victim" \
  alpine:3.24.1 /bin/sh -ec \
  'stat -c "%u:%g:%a" /victim/marker-victim; sha256sum /victim/marker-victim')

root_prep_race_chown_prelude() {
  # shellcheck disable=SC2016
  printf '%s\n' \
    'chown() {' \
    '  chown_last=' \
    '  for chown_arg in "$@"; do chown_last=$chown_arg; done' \
    '  case "$chown_last" in' \
    '    /proc/*/fd/9)' \
    '      chown_fd_target=$(/usr/bin/readlink "$chown_last" 2>/dev/null || true)' \
    '      if [ "$chown_fd_target" = /data/sorted ] && [ ! -e /data/.root-prep-race-fired ]; then' \
    '        /bin/mv /data/sorted /data/sorted.original' \
    '        /bin/ln -s /victim /data/sorted' \
    '        : > /data/.root-prep-race-fired' \
    '      fi' \
    '      ;;' \
    '  esac' \
    '  /bin/chown "$@"' \
    '}'
}

set +e
root_prep_output=$(
  { root_prep_race_chown_prelude; compose_data_init_command; } \
    | docker run --rm -i \
      -e PUID=12345 \
      -e PGID=12346 \
      -e PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
      -v "$DATA_VOLUME:/data" \
      -v "$STATE_VOLUME:/state" \
      -v "$VICTIM_VOLUME:/victim" \
      alpine:3.24.1 /bin/sh -e -s 2>&1
)
root_prep_rc=$?
set -e

docker run --rm -v "$DATA_VOLUME:/data" alpine:3.24.1 \
  test -e /data/.root-prep-race-fired || {
  printf '%s\n' "$root_prep_output" >&2
  echo "FAIL: deterministic root-preparation swap hook did not fire" >&2
  exit 1
}
victim_after=$(docker run --rm -v "$VICTIM_VOLUME:/victim" \
  alpine:3.24.1 stat -c '%u:%g:%a' /victim)
[[ "$victim_after" == "$victim_before" ]] || {
  printf '%s\n' "$root_prep_output" >&2
  echo "FAIL: root preparation changed swapped target from $victim_before to $victim_after" >&2
  exit 1
}
prepared_after=$(docker run --rm -v "$DATA_VOLUME:/data" \
  alpine:3.24.1 stat -c '%u:%g:%a' /data/sorted.original)
[[ "$prepared_after" == 12345:12346:775 ]] || {
  echo "FAIL: pinned root directory was not prepared: $prepared_after" >&2
  exit 1
}
(( root_prep_rc != 0 )) || {
  echo "FAIL: root preparation did not reject a path swapped during mutation" >&2
  exit 1
}
grep -q 'changed during directory preparation' <<< "$root_prep_output"
echo "PASS: root preparation mutates its pinned inode and rejects a swapped path"

docker run --rm -v "$DATA_VOLUME:/data" alpine:3.24.1 /bin/sh -ec '
  [ -L /data/sorted ]
  rm /data/sorted
  mv /data/sorted.original /data/sorted
  rm /data/.root-prep-race-fired
'

marker_noclobber_prelude() {
  # Insert a hostile symlink after the absence check and migrations, immediately
  # before the script enables noclobber and opens its creation descriptor.
  # shellcheck disable=SC2016
  printf '%s\n' \
    'umask() {' \
    '  if [ "$#" -eq 1 ] && [ "$1" = 077 ] && [ ! -e /state/.noclobber-race-fired ]; then' \
    '    marker=/state/.directory-owner-v1-${PUID}-${PGID}-$(stat -c "%d-%i" /data)' \
    '    /bin/ln -s /victim/marker-victim "$marker"' \
    '    : > /state/.noclobber-race-fired' \
    '  fi' \
    '  command umask "$@"' \
    '}'
}

set +e
marker_noclobber_output=$(
  { marker_noclobber_prelude; compose_data_init_command; } \
    | docker run --rm -i \
      -e PUID=12345 \
      -e PGID=12346 \
      -v "$DATA_VOLUME:/data" \
      -v "$STATE_VOLUME:/state" \
      -v "$VICTIM_VOLUME:/victim" \
      alpine:3.24.1 /bin/sh -e -s 2>&1
)
marker_noclobber_rc=$?
set -e

docker run --rm -v "$STATE_VOLUME:/state" alpine:3.24.1 \
  test -e /state/.noclobber-race-fired || {
  printf '%s\n' "$marker_noclobber_output" >&2
  echo "FAIL: deterministic marker noclobber hook did not fire" >&2
  exit 1
}
victim_file_after=$(docker run --rm -v "$VICTIM_VOLUME:/victim" \
  alpine:3.24.1 /bin/sh -ec \
  'stat -c "%u:%g:%a" /victim/marker-victim; sha256sum /victim/marker-victim')
[[ "$victim_file_after" == "$victim_file_before" ]] || {
  printf '%s\n' "$marker_noclobber_output" >&2
  echo "FAIL: marker creation followed or truncated the attacker node" >&2
  exit 1
}
(( marker_noclobber_rc != 0 )) || {
  echo "FAIL: marker creation accepted an attacker node that won the name" >&2
  exit 1
}
grep -Eq 'File exists|migration marker appeared during creation' <<< "$marker_noclobber_output"
echo "PASS: marker creation is exclusive and never follows or truncates an attacker node"

docker run --rm -v "$STATE_VOLUME:/state" alpine:3.24.1 /bin/sh -ec '
  marker=$(find /state -maxdepth 1 -type l -name ".directory-owner-v1-*" -print -quit)
  [ -n "$marker" ]
  rm "$marker" /state/.noclobber-race-fired
'

marker_race_chown_prelude() {
  # shellcheck disable=SC2016
  printf '%s\n' \
    'chown() {' \
    '  chown_last=' \
    '  for chown_arg in "$@"; do chown_last=$chown_arg; done' \
    '  case "$chown_last" in' \
    '    /proc/*/fd/9)' \
    '      chown_fd_target=$(/usr/bin/readlink "$chown_last" 2>/dev/null || true)' \
    '      case "$chown_fd_target" in' \
    '        /state/.directory-owner-v1-*)' \
    '          if [ ! -e /state/.marker-race-fired ]; then' \
    '            /bin/mv "$chown_fd_target" "$chown_fd_target.original"' \
    '            /bin/ln -s /victim "$chown_fd_target"' \
    '            : > /state/.marker-race-fired' \
    '          fi' \
    '          ;;' \
    '      esac' \
    '      ;;' \
    '  esac' \
    '  /bin/chown "$@"' \
    '}'
}

set +e
marker_race_output=$(
  { marker_race_chown_prelude; compose_data_init_command; } \
    | docker run --rm -i \
      -e PUID=12345 \
      -e PGID=12346 \
      -e PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
      -v "$DATA_VOLUME:/data" \
      -v "$STATE_VOLUME:/state" \
      -v "$VICTIM_VOLUME:/victim" \
      alpine:3.24.1 /bin/sh -e -s 2>&1
)
marker_race_rc=$?
set -e

docker run --rm -v "$STATE_VOLUME:/state" alpine:3.24.1 \
  test -e /state/.marker-race-fired || {
  printf '%s\n' "$marker_race_output" >&2
  echo "FAIL: deterministic marker path-swap hook did not fire" >&2
  exit 1
}
victim_after=$(docker run --rm -v "$VICTIM_VOLUME:/victim" \
  alpine:3.24.1 stat -c '%u:%g:%a' /victim)
[[ "$victim_after" == "$victim_before" ]] || {
  printf '%s\n' "$marker_race_output" >&2
  echo "FAIL: marker swap changed victim from $victim_before to $victim_after" >&2
  exit 1
}
marker_original_after=$(docker run --rm -v "$STATE_VOLUME:/state" \
  alpine:3.24.1 /bin/sh -ec '
    marker=$(find /state -maxdepth 1 -type f -name ".directory-owner-v1-*.original" -print -quit)
    [ -n "$marker" ]
    stat -c "%u:%g:%a:%h" "$marker"
  ')
[[ "$marker_original_after" == 12345:12346:600:1 ]] || {
  echo "FAIL: pinned marker was not prepared safely: $marker_original_after" >&2
  exit 1
}
(( marker_race_rc != 0 )) || {
  echo "FAIL: marker creation did not reject a path swapped during mutation" >&2
  exit 1
}
grep -q 'marker changed during metadata update' <<< "$marker_race_output"
echo "PASS: marker metadata changes use the exclusive pinned descriptor"

docker run --rm -v "$STATE_VOLUME:/state" alpine:3.24.1 /bin/sh -ec '
  marker=$(find /state -maxdepth 1 -type l -name ".directory-owner-v1-*" -print -quit)
  [ -n "$marker" ]
  rm "$marker" "$marker.original" /state/.marker-race-fired
'

set +e
race_output=$(
  { race_chown_prelude; compose_data_init_command; } \
    | docker run --rm -i \
      -e PUID=12345 \
      -e PGID=12346 \
      -e PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
      -v "$DATA_VOLUME:/data" \
      -v "$STATE_VOLUME:/state" \
      -v "$VICTIM_VOLUME:/victim" \
      alpine:3.24.1 /bin/sh -e -s 2>&1
)
race_rc=$?
set -e

docker run --rm -v "$DATA_VOLUME:/data" alpine:3.24.1 \
  test -e /data/.race-fired || {
  printf '%s\n' "$race_output" >&2
  echo "FAIL: deterministic path-swap hook did not fire" >&2
  exit 1
}
victim_after=$(docker run --rm -v "$VICTIM_VOLUME:/victim" \
  alpine:3.24.1 stat -c '%u:%g:%a' /victim)
[[ "$victim_after" == "$victim_before" ]] || {
  printf '%s\n' "$race_output" >&2
  echo "FAIL: swapped symlink target changed from $victim_before to $victim_after" >&2
  exit 1
}
pinned_after=$(docker run --rm -v "$DATA_VOLUME:/data" \
  alpine:3.24.1 stat -c '%u:%g:%a' /data/sorted/race-target.original)
[[ "$pinned_after" == 12345:12346:775 ]] || {
  echo "FAIL: pinned directory was not migrated: $pinned_after" >&2
  exit 1
}
(( race_rc != 0 )) || {
  echo "FAIL: migration did not reject a path swapped during mutation" >&2
  exit 1
}
grep -q 'changed during migration' <<< "$race_output"
echo "PASS: migration mutates the pinned inode and rejects a swapped path"

docker run --rm -v "$DATA_VOLUME:/data" alpine:3.24.1 /bin/sh -ec '
  [ -L /data/sorted/race-target ]
  rm /data/sorted/race-target
  mv /data/sorted/race-target.original /data/sorted/race-target
  rm /data/.race-fired
'

for _ in 1 2; do
  compose_data_init_command \
    | docker run --rm -i \
      -e PUID=12345 \
      -e PGID=12346 \
      -v "$DATA_VOLUME:/data" \
      -v "$STATE_VOLUME:/state" \
      alpine:3.24.1 /bin/sh -e -s
done

docker run --rm \
  -v "$DATA_VOLUME:/data" \
  -v "$STATE_VOLUME:/state" \
  alpine:3.24.1 /bin/sh -ec '
    for directory in /data /data/incoming /data/sorted /data/sorted/race-target /data/quarantine; do
      [ "$(stat -c "%u:%g:%a" "$directory")" = 12345:12346:775 ]
    done
    [ "$(stat -c "%u:%g:%a" /state)" = 12345:12346:700 ]
    marker=$(find /state -maxdepth 1 -type f -name ".directory-owner-v1-*" -print -quit)
    [ -n "$marker" ]
    [ "$(stat -c "%u:%g:%a:%h" "$marker")" = 12345:12346:600:1 ]
  '
echo "PASS: data-init remains successful and idempotent after the race defense"

docker compose --project-directory "$ROOT" -f "$ROOT/docker-compose.yml" config -q
echo "PASS: Compose configuration is valid"

PUID=12345 PGID=12346 docker compose \
  --project-directory "$ROOT" \
  -f "$ROOT/docker-compose.yml" \
  --project-name "$COMPOSE_PROJECT" \
  run --rm --no-deps data-init >/dev/null
echo "PASS: Compose executes data-init with the rendered descriptor path"

if docker volume inspect "${COMPOSE_PROJECT}_frameio_state" >/dev/null 2>&1; then
  echo "FAIL: core data-init unexpectedly created the profile-scoped Frame.io volume" >&2
  exit 1
fi
echo "PASS: Frame.io initialization remains isolated behind its profile"

PUID=12345 PGID=12346 docker compose \
  --project-directory "$ROOT" \
  -f "$ROOT/docker-compose.yml" \
  --project-name "$COMPOSE_PROJECT" \
  --profile frameio \
  run --rm --no-deps frameio-init >/dev/null

frameio_state_volume="${COMPOSE_PROJECT}_frameio_state"
staging_metadata=$(docker run --rm -v "$frameio_state_volume:/frameio-state" \
  alpine:3.24.1 stat -c '%u:%g:%a' /frameio-state/staging)
[[ "$staging_metadata" == 12345:12346:700 ]] || {
  echo "FAIL: private Frame.io staging directory has $staging_metadata" >&2
  exit 1
}
echo "PASS: Frame.io profile prepares a private 0700 staging directory"

compose_profile_json=$(PUID=12345 PGID=12346 docker compose \
  --project-directory "$ROOT" -f "$ROOT/docker-compose.yml" \
  --profile frameio config --format json)
jq -e '
  .services.sorter.environment.RECONCILE_IDLE == "300" and
  .services.sorter.environment.STUCK_AGE_MIN == "60" and
  .services["frameio-mirror"].environment.STAGING_DIR == "/var/lib/frameio/staging"
' <<< "$compose_profile_json" >/dev/null
echo "PASS: Compose exposes sorter reconciliation controls and private staging"
