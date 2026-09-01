# Requirements: FTP Camera Dropbox — 2026-09 Hardening

**Defined:** 2026-09-01
**Core Value:** Every file a camera sends either lands intact in `sorted/` or the operator is told exactly which file did not.

## v1 Requirements

### Baseline

- [x] **BASE-01**: The milestone branch carries the LRU folder registry from commit 0d566ce (`_remember_c2c_folder` evicts the oldest and promotes a re-seen folder; `_reconcile_folder_ids` returns newest-last, max 16) on top of origin/main, with `frameio-mirror/tests/test_multi_folder.py` asserting LRU behavior and the full Frame.io suite passing (57 tests).
- [x] **BASE-02**: The Frame.io test suite passes on macOS with the default `TMPDIR` (tests resolve temporary directories with `os.path.realpath` before handing them to the app).
- [x] **BASE-03**: `.impeccable/` is gitignored; the stale panel draft from this checkout is stashed, not committed; `git status` on the milestone branch is clean apart from planning docs.
- [x] **BASE-04**: `tests/run-on-tower.sh <harness>` syncs the working tree to tower under `/tmp/gsd-test-<id>/`, builds `camera-sorter:gsd-test-<id>`, runs the named Linux-only harness in a `--rm` container, prints `PASS`/`FAIL`, and always removes the build dir and image; it never names a production container or a `/mnt` path. Both `unraid-healthcheck` and `parallel-sort` pass through it.

### Sorter

- [ ] **SORT-01**: `heif_container_validate` accepts a file whose final box ends 1 to 7 bytes before EOF once at least one box has parsed (trailing alignment pad), still rejects an mdat that overruns EOF, and still rejects a file whose first bytes cannot form a box header. A new `tests/parallel-sort.sh` case with a padded fixture passes alongside the existing valid and truncated HEIF cases.
- [ ] **SORT-02**: The reconcile STUCK scan keys on ctime (`find -cmin`), so a file with an hours-old mtime that arrived seconds ago is not logged STUCK. A harness case proves the negative; `wait_stable`'s `STABLE_SKIP_AGE` keeps using mtime.

### Observability

- [ ] **OBS-01**: `contrib/unraid/ftpdropbox-healthcheck.sh` sends one Telegram alert per aborted FTP upload (filename, bytes received, KB/s, and the advice to re-send from the card) by reading the FTP container's log for `451-Transfer aborted` and the preceding `uploaded (N bytes, X KB/sec)` NOTICE line, deduplicated through a fingerprint file under the root 0700 state dir. `tests/unraid-healthcheck.sh` gains cases (docker stub `logs` subcommand) that pass.
- [ ] **OBS-02**: Panel `/api/status` derives `incoming[].age_s` and the derived health lamp from `st_ctime`; any UI copy that names the age says "arrived".
- [ ] **OBS-03**: `frameio-mirror` logs the exception type and `repr` for reconcile-listing and Telegram-send failures; a unit test asserts the log record for an exception whose `str()` is empty names the type.

### Panel

- [ ] **PANEL-01**: `in_library` and `prune_verified` in `panel/app.py` compare bytes with `filecmp.cmp(shallow=False)` against same-name, same-size library files; prune deletes only byte-identical files. A small pytest (`panel/tests/`) using FastAPI's TestClient and a temporary `DATA_ROOT` proves both paths.

### Deploy

- [ ] **DEPLOY-01**: On tower, `camera-sorter` and `dropbox-panel` run images built from the merged milestone commit; `dropbox-panel` mounts `telegram.json` and `/health` read-only; the healthcheck script on `/boot/config/scripts/` matches `contrib/unraid/`; `DSCF8283.HIF` retried through the panel lands in `sorted/2026-08-22/heif/`; `tests/pure-ftpd-abort.py` run from the Mac yields exactly one abort alert within one cron interval.
- [ ] **DEPLOY-02**: README and `contrib/unraid/` docs describe the abort alert and the read-only `telegram.json` mount for the panel.

## v2 Requirements

Deferred to a later milestone. Tracked but not in the current roadmap.

### Observability

- **OBS-04**: The panel lists aborted uploads (needs a root-written, world-readable feed the panel can consume).
- **OBS-05**: The panel lamp reflects the cron healthcheck on hosts where the state dir is root-only.

### Sorter

- **SORT-03**: Per-model RAW size floors reconsidered if a false positive is ever observed.

## Out of Scope

| Feature | Reason |
|---------|--------|
| Handling `/data/Vik` | User's data outside the pipeline; manual decision |
| Docker socket in the panel | Trust boundary: the panel is reachable by any LAN device |
| Raising pure-ftpd idle timeout | Waiting longer on a dying Wi-Fi link does not recover the file |
| Rebuilding `frameio-mirror` in this milestone | Only a log-format change lands there; commands recorded for the next rebuild |

## Traceability

| Requirement | Phase | Status |
|-------------|-------|--------|
| BASE-01 | Phase 1 | Complete |
| BASE-02 | Phase 1 | Complete |
| BASE-03 | Phase 1 | Complete |
| BASE-04 | Phase 1 | Complete |
| SORT-01 | Phase 2 | Pending |
| SORT-02 | Phase 2 | Pending |
| OBS-01 | Phase 3 | Pending |
| OBS-02 | Phase 3 | Pending |
| OBS-03 | Phase 3 | Pending |
| PANEL-01 | Phase 3 | Pending |
| DEPLOY-01 | Phase 4 | Pending |
| DEPLOY-02 | Phase 4 | Pending |
| OBS-04 | v2 (deferred) | Deferred |
| OBS-05 | v2 (deferred) | Deferred |
| SORT-03 | v2 (deferred) | Deferred |

**Coverage:**

- v1 requirements: 12 total
- Mapped to phases: 12
- Unmapped: 0

---
*Requirements defined: 2026-09-01*
*Last updated: 2026-09-01 after review of the live deployment*
