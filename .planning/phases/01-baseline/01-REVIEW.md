---
phase: 01-baseline
reviewed: 2026-09-01T21:08:23Z
depth: standard
files_reviewed: 6
files_reviewed_list:
  - frameio-mirror/app.py
  - frameio-mirror/tests/test_multi_folder.py
  - frameio-mirror/tests/test_app.py
  - frameio-mirror/tests/test_release_safety.py
  - tests/run-on-tower.sh
  - README.md
findings:
  critical: 1
  warning: 0
  info: 3
  total: 4
status: issues_found
---

# Phase 1: Code Review Report

**Reviewed:** 2026-09-01T21:08:23Z
**Depth:** standard
**Files Reviewed:** 6
**Status:** issues_found

## Summary

Reviewed the diff between `4c0a55d` and `HEAD` for the six files in scope, focused on: the cherry-picked LRU folder registry (`_remember_c2c_folder`, `_reconcile_folder_ids`) in `frameio-mirror/app.py`, the `os.path.realpath` fixes in the three test files, the new `tests/run-on-tower.sh`, and the two-line README addition.

**Python side (app.py + tests):** Byte-for-byte diffed `_remember_c2c_folder` and `_reconcile_folder_ids` against `git show 0d566ce` — both are identical to the vetted, already-in-production commit. Manually traced the eviction (`len(known) >= 16` → slice to last 16) and promotion (`known.remove()` + re-append) branches against every case in `test_multi_folder.py` (first discovery, second camera, duplicate no-op, legacy-only merge, garbage rejection, full-registry eviction, re-seen promotion, invalid input) — no off-by-one or ordering bugs found. Ran the full suite with `TMPDIR` unset (`cd frameio-mirror && python3 -m pytest -q`): **57 passed, 5 subtests passed**, matching the phase's D-03/D-05 acceptance number. The three `os.path.realpath()` test fixes are minimal, mechanical, and correctly scoped (confirmed via full-file grep that no other `Path(directory)` site in these files needed the same fix for the suite to pass under default macOS `TMPDIR`). State-file write safety for `_remember_c2c_folder` is unchanged by this diff and consistent with the file's existing `_load_state`/`_save_state` conventions. This portion of the diff is clean.

**Shell side (`tests/run-on-tower.sh`):** New file, and it does not fully deliver on its own stated safety contract. The `TOWER_TMP` validation regex blocks shell-metacharacter injection correctly (verified empirically) but does **not** block `..` path-segment traversal or degenerate values like a bare `/`. Since `TOWER` defaults to `root@10.0.0.100` (i.e., the remote commands run as root on the production NAS), a misconfigured `TOWER_TMP` can make every `rsync`/`docker build`/`rm -rf` in this script operate outside the intended `/tmp`-rooted scratch tree — see CR-01. Quoting of the derived `id`/`dir`/`tag` strings, `EXIT`-trap firing on both early-exit paths and on `SIGINT` (confirmed empirically with a live signal test), and command construction are otherwise correct.

## Critical Issues

### CR-01: `TOWER_TMP` validation does not block `..` path-segment traversal

**File:** `tests/run-on-tower.sh:39-43`
**Issue:** The regex `^/[A-Za-z0-9._/-]*$` is meant to confine every remote operation to `$TOWER_TMP/gsd-test-<id>` (per the file's own header: "this script only ever builds, runs with `--rm`, and removes docker images ... that live inside a `gsd-test-*` directory under `$TOWER_TMP`"). `.` and `/` are both in the allowed character class, so the regex accepts `..` segments and degenerate roots. Verified directly:
```
$ [[ "/tmp/../etc" =~ ^/[A-Za-z0-9._/-]*$ ]] && echo ACCEPTED
ACCEPTED
$ [[ "/" =~ ^/[A-Za-z0-9._/-]*$ ]] && echo ACCEPTED
ACCEPTED
```
With `TOWER_TMP=/tmp/../etc`, `dir` becomes `/etc/gsd-test-<id>`. Since `$TOWER` defaults to `root@10.0.0.100`, every subsequent `ssh` command (`rsync --delete`, `docker build`, `docker run`, and the `cleanup()` trap's `rm -rf -- $dir`) runs as **root** against that path instead of a scratch temp directory. `cleanup()`'s own guard (`[[ "$dir" == */gsd-test-* ]] || return 0`, line 56) does not catch this: `dir` always contains the literal substring `/gsd-test-` by construction (line 50), so the guard is trivially true regardless of where `TOWER_TMP` actually points (see IN-02). The blast radius is bounded to a uniquely-named `gsd-test-<hash>-<pid>` leaf (it can't collide with or delete pre-existing files), but it can still create/populate/delete that leaf under arbitrary root-writable paths on the production NAS — including sensitive small partitions like an Unraid `/boot` flash — which is exactly the accident this script's extensive safety commentary says it exists to prevent.
**Fix:**
```bash
TOWER_TMP="${TOWER_TMP:-/tmp}"
if [[ ! "$TOWER_TMP" =~ ^/[A-Za-z0-9._/-]*$ ]] || [[ "/$TOWER_TMP/" == *"/../"* ]]; then
  echo "TOWER_TMP must be an absolute path with no '..' segments (got: $TOWER_TMP)" >&2
  exit 2
fi
```
(Wrapping in `/.../ ` before the substring check also catches a leading or trailing `..` segment, e.g. `TOWER_TMP=/tmp/..`.)

## Info

### IN-01: Redundant `known and` guard is always true

**File:** `frameio-mirror/app.py:588`
**Issue:** `elif known and known[-1] != parent_folder:` — this branch is only reached when the preceding `if parent_folder not in known:` was false, i.e. `parent_folder in known` is true, which already implies `known` is non-empty. `known and` can never be false here. Harmless (this is byte-identical to the already-running production commit `0d566ce`), but it reads as if there's a real emptiness edge case being guarded when there isn't one.
**Fix:** `elif known[-1] != parent_folder:` (optional; purely a readability nit, not required for correctness).

### IN-02: `cleanup()`'s directory guard can't actually fire

**File:** `tests/run-on-tower.sh:56`
**Issue:** `[[ "$dir" == */gsd-test-* ]] || return 0` is intended (per its comment) to refuse to guess if `dir` "lost its marker." But `dir="$TOWER_TMP/gsd-test-$id"` (line 50) hardcodes the `gsd-test-` substring into every possible value of `dir`, so this condition is a tautology in the current script — it can never protect against anything, including the CR-01 scenario.
**Fix:** Either remove the check (it does nothing) or make it meaningful, e.g. also assert `dir` is still exactly `"$TOWER_TMP/gsd-test-$id"` (guards against a future edit accidentally reassigning `dir` before cleanup) — this doesn't address CR-01 either way, which needs to be fixed at the `TOWER_TMP` validation site.

### IN-03: No guard that the script is invoked from the repo root

**File:** `tests/run-on-tower.sh:62-65`
**Issue:** `rsync -a --delete ... ./ "$TOWER:$dir/"` syncs whatever `./` resolves to. If an agent or developer runs this script from a subdirectory instead of the repo root, it silently syncs a partial tree instead of failing with a clear message. In practice this mostly self-corrects (the remote `docker build` will fail loudly with "Dockerfile not found"), so impact is low, but a `git rev-parse --show-toplevel` check with a clear error would fail faster and closer to the actual mistake.
**Fix:**
```bash
if [[ "$(git rev-parse --show-toplevel)" != "$PWD" ]]; then
  echo "Run this script from the repository root" >&2
  exit 2
fi
```

---

_Reviewed: 2026-09-01T21:08:23Z_
_Reviewer: Claude (gsd-code-reviewer)_
_Depth: standard_
