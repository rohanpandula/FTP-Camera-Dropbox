# Phase 1: Baseline - Context

**Gathered:** 2026-09-01
**Status:** Ready for planning
**Source:** Orchestrator decisions from the 2026-09-01 live-deployment review (no discuss-phase; every decision below is locked)

<domain>
## Phase Boundary

Make the milestone branch `gsd/2026-09-hardening` equal origin/main plus exactly the Frame.io LRU folder registry that already runs on tower, make every test suite pass on this Mac without environment tweaks, and give agents one vetted way to run the Linux-only harnesses. No behavior changes to the sorter, panel, or healthcheck in this phase.

</domain>

<decisions>
## Implementation Decisions

### LRU registry lands on main's lineage (BASE-01)
- **D-01:** Cherry-pick commit `0d566ce` (frameio-mirror: LRU folder registry) onto the milestone branch with `git cherry-pick 0d566ce`. Do not rebase or merge the old branch `fix/frameio-folder-lru`; leave that branch untouched.
- **D-02:** On conflict in `frameio-mirror/app.py`, the LRU side wins in both functions: `_remember_c2c_folder` (evict `known[0]` when 16 are known, promote a re-seen folder to the end, keep the "Discovered C2C ingest folder" log line) and `_reconcile_folder_ids` (return the stored `c2c_folder_ids` newest-last capped at 16, falling back to the legacy single `c2c_folder_id` only when the list is empty). The resulting bodies must match `git show 0d566ce:frameio-mirror/app.py` for those two functions byte for byte apart from surrounding context.
- **D-03:** For `frameio-mirror/tests/test_multi_folder.py` take the `0d566ce` version wholesale (it asserts eviction and promotion). Then run the full suite: 57 passed is the acceptance number.

### Tests pass on macOS with the default TMPDIR (BASE-02)
- **D-04:** In `frameio-mirror/tests/test_multi_folder.py` (line 14), `test_app.py` (lines 187, 320, 369), and `test_release_safety.py` (lines 167, 349, 384), resolve every `tempfile.TemporaryDirectory()` path with `os.path.realpath(...)` before it is handed to the app as `REFRESH_TOKEN_FILE`, `STAGING_DIR`, or `INCOMING_DIR`. Smallest diff: keep the `TemporaryDirectory` object for cleanup, derive `base = os.path.realpath(self._dir.name)` and use `base` everywhere the name was used. Cause: macOS `/var/folders` is a symlink to `/private/var/folders`, and the app's `_state_parent_path_is_canonical` rejects any non-canonical parent.
- **D-05:** Verify with `cd frameio-mirror && python3 -m pytest -q` and no `TMPDIR` in the environment: 57 passed.

### Checkout hygiene (BASE-03)
- **D-06:** `.impeccable/` is already listed in `.gitignore` by the orchestrator's planning commit; the stale panel draft was stashed by the orchestrator before this branch was created. The plan only verifies: `git status --short` shows nothing outside `.planning/` and the files this phase edits, and `git check-ignore .impeccable` succeeds.

### One vetted way to run Linux-only harnesses (BASE-04)
- **D-07:** Add `tests/run-on-tower.sh`. Interface: `tests/run-on-tower.sh <parallel-sort|unraid-healthcheck|unraid-backup|unraid-fixperms>`; env `TOWER` (default `root@10.0.0.100`) and `TOWER_TMP` (default `/tmp`). It syncs the current working tree (uncommitted changes included) so an executor can test before committing.
- **D-08:** Behavior, in order: `id="$(git rev-parse --short HEAD)-$$"`; `dir="$TOWER_TMP/gsd-test-$id"`; `rsync -a --delete --exclude .git --exclude .planning --exclude .impeccable --exclude '__pycache__' --exclude '.pytest_cache' --exclude '.ruff_cache' --exclude '.venv*' ./ "$TOWER:$dir/"`; `ssh -o BatchMode=yes "$TOWER" "docker build -q -t camera-sorter:gsd-test-$id $dir"`; then for `parallel-sort`: `ssh "$TOWER" "docker run --rm --entrypoint /bin/bash -e SORTER_UNDER_TEST=/sort.sh -v $dir:/work:ro camera-sorter:gsd-test-$id /work/tests/parallel-sort.sh"`; for the `unraid-*` harnesses: `ssh "$TOWER" "cd $dir && TEST_IMAGE=camera-sorter:gsd-test-$id tests/<harness>.sh"` (those scripts re-exec themselves inside the image as root). A `trap` on EXIT always runs `ssh "$TOWER" "docker rmi -f camera-sorter:gsd-test-$id >/dev/null 2>&1; rm -rf $dir"`. Exit status is the harness's; the last line printed is `PASS <harness>` or `FAIL <harness> (rc=N)`.
- **D-09:** The script must never contain the strings `camera-sorter ` (with trailing space, i.e. the production container name as a docker argument), `dropbox-panel`, `frameio-mirror`, `pure-ftpd`, or any `/mnt/` path. Only `docker build`, `docker run --rm`, and `docker rmi` of the `gsd-test-` tag are allowed. Put this rule in the script header comment.
- **D-10:** Acceptance: `tests/run-on-tower.sh unraid-healthcheck` prints `PASS unraid-healthcheck` (about 30 seconds), and `tests/run-on-tower.sh parallel-sort` prints `PASS parallel-sort` (about 10 minutes, 48 cases) — run both once in this phase to establish the baseline. Document the helper in `README.md` § Tests (two lines) and in `.planning/codebase/TESTING.md`.

### Claude's Discretion
- rsync exclude ordering, the exact `id` format, and whether to `set -euo pipefail` (recommended) in the helper.
- Whether D-04 uses a tiny shared helper in a `conftest.py` or inline `os.path.realpath` at each site; inline is fine.

</decisions>

<specifics>
## Specific Ideas

- The production mirror already runs the LRU code as image `frameio-mirror:folder-lru`; this phase makes main match production, not the other way round.
- The macOS failure to reproduce before the fix: `cd frameio-mirror && python3 -m pytest -q -x` fails `test_first_discovery_sets_legacy_and_list` with "state parent contains a symlink: /var/folders/..."; with `TMPDIR=/private/tmp` it passes. After D-04 it passes either way.
- Tower facts the helper relies on: passwordless `ssh root@10.0.0.100`, `rsync` and `docker` present on the host, `/tmp` writable. Docker Hub pulls on tower can hit transient TLS timeouts; `docker build` of `alpine:3.24.1` may need a retry.

</specifics>

<canonical_refs>
## Canonical References

**Downstream agents MUST read these before planning or implementing.**

### Milestone context
- `.planning/PROJECT.md` — Key Decisions table and § Context (deployment facts, review evidence)
- `.planning/codebase/TESTING.md` — where each suite runs and the harness idioms
- `.planning/codebase/CONVENTIONS.md` — commit subject format, no new dependencies

### The change being carried forward
- `git show 0d566ce` — the LRU registry commit (app.py + test_multi_folder.py); the diff against origin/main is confined to `_remember_c2c_folder`, `_reconcile_folder_ids`, and the test file
- `README.md` § Tests (lines 268-290) — the docker recipes the helper wraps

</canonical_refs>

<code_context>
## Existing Code Insights

### Reusable Assets
- `tests/unraid-healthcheck.sh` lines 1-12: the self-re-exec pattern (`HEALTHCHECK_TEST_IN_CONTAINER`, `TEST_IMAGE`) the helper must honor for the `unraid-*` harnesses.
- `contrib/unraid/ftpdropbox-backup.sh` — an existing rsync-on-tower usage for flag conventions.

### Established Patterns
- Frame.io tests build their own state/staging/incoming dirs under a `TemporaryDirectory` and pass paths through env or `app.CFG`; realpath only changes the string handed over.

### Integration Points
- `frameio-mirror/app.py` `_remember_c2c_folder` is called from `_process_asset_inner`; `_reconcile_folder_ids` from `reconcile_once`. No other callers.

</code_context>

<deferred>
## Deferred Ideas

- Running the sorter harness locally under colima: no colima instance exists on this Mac; provisioning one is the user's call. The tower helper covers this milestone.

</deferred>

---

*Phase: 01-baseline*
*Context gathered: 2026-09-01 by the orchestrator*
