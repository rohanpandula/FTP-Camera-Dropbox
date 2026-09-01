#!/bin/bash
set -euo pipefail

# tests/run-on-tower.sh -- run a Linux-only test harness on tower.
#
# Why: the development Mac has no Docker VM (no colima instance), so the
# harnesses under tests/ that need real Linux tooling (inotify, GNU
# coreutils, all inside a container) cannot run on this machine at all.
# This script is the one sanctioned way to run them anyway: it syncs the
# current working tree to a throwaway directory on tower, builds a
# throwaway image, runs the named harness in a --rm container, and
# removes both afterwards. Without it, every future phase would
# improvise its own tower command, and an improvised command against a
# production NAS is exactly how a live container gets stopped by
# accident.
#
# Safety rule (the review gate for this file is a grep over the whole
# file, comments included, for the names this rule forbids): this
# script only ever builds, runs with --rm, and removes docker images
# tagged gsd-test-* that live inside a gsd-test-* directory under
# $TOWER_TMP. It must never name a production container, a sibling
# service, or a host storage path, and no other docker subcommand may
# appear here.

usage() {
  echo "Usage: $0 <parallel-sort|unraid-healthcheck|unraid-backup|unraid-fixperms>" >&2
}

harness="${1:-}"
case "$harness" in
  parallel-sort|unraid-healthcheck|unraid-backup|unraid-fixperms) ;;
  *)
    usage
    exit 2
    ;;
esac

TOWER="${TOWER:-root@10.0.0.100}"
TOWER_TMP="${TOWER_TMP:-/tmp}"
if [[ ! "$TOWER_TMP" =~ ^/[A-Za-z0-9._/-]*$ ]]; then
  echo "TOWER_TMP must match ^/[A-Za-z0-9._/-]*\$ (got: $TOWER_TMP)" >&2
  exit 2
fi

# id, dir, and tag are built from a short git hash and this shell's PID --
# both hex/decimal, so the derived strings are charset-safe by
# construction and need no further escaping when interpolated into the
# remote command strings below.
id="$(git rev-parse --short HEAD)-$$"
dir="$TOWER_TMP/gsd-test-$id"
tag="camera-sorter:gsd-test-$id"

cleanup() {
  # A path that lost its gsd-test- marker is not this run's directory --
  # do nothing rather than guess.
  [[ "$dir" == */gsd-test-* ]] || return 0
  ssh -o BatchMode=yes "$TOWER" \
    "docker rmi -f $tag >/dev/null 2>&1; rm -rf -- $dir" || true
}
trap cleanup EXIT

rsync -a --delete \
  --exclude .git --exclude .planning --exclude .impeccable \
  --exclude '__pycache__' --exclude '.pytest_cache' --exclude '.ruff_cache' --exclude '.venv*' \
  ./ "$TOWER:$dir/"

ssh -o BatchMode=yes "$TOWER" "docker build -q -t $tag $dir"

rc=0
case "$harness" in
  parallel-sort)
    ssh -o BatchMode=yes "$TOWER" \
      "docker run --rm --entrypoint /bin/bash -e SORTER_UNDER_TEST=/sort.sh -v $dir:/work:ro $tag /work/tests/parallel-sort.sh" \
      || rc=$?
    ;;
  unraid-healthcheck|unraid-backup|unraid-fixperms)
    ssh -o BatchMode=yes "$TOWER" \
      "cd $dir && TEST_IMAGE=$tag tests/$harness.sh" \
      || rc=$?
    ;;
esac

if [[ $rc -eq 0 ]]; then
  echo "PASS $harness"
else
  echo "FAIL $harness (rc=$rc)"
fi
exit "$rc"
