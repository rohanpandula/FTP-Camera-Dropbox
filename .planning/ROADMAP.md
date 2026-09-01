# Roadmap: FTP Camera Dropbox — 2026-09 Hardening

## Overview

Four phases, each shippable on its own. Phase 1 puts the code that is actually running on tower onto main's lineage and cleans the checkout. Phase 2 fixes the two sorter bugs that lose or misreport files. Phase 3 closes the observability gaps and makes the panel's "verified" claim true. Phase 4 deploys to tower under human control and proves each fix against the live system.

## Phases

**Phase Numbering:**

- Integer phases (1, 2, 3): Planned milestone work
- Decimal phases (2.1, 2.2): Urgent insertions (marked with INSERTED)

- [ ] **Phase 1: Baseline** - LRU registry on main's lineage, macOS-clean tests, tidy checkout
- [ ] **Phase 2: Sorter Correctness** - HEIF trailing-pad tolerance and ctime-based STUCK scan
- [ ] **Phase 3: Observability and Panel Honesty** - abort alerts, ctime age, exception types, byte-verified prune
- [ ] **Phase 4: Deploy and Verify** - human-gated rollout to tower with end-to-end proof

## Phase Details

### Phase 1: Baseline

**Goal**: The milestone branch equals origin/main plus the LRU folder registry, every test suite passes on this Mac, and nothing stale can be committed by accident.
**Depends on**: Nothing (first phase)
**Requirements**: BASE-01, BASE-02, BASE-03, BASE-04
**Success Criteria** (what must be TRUE):

  1. `python3 -m pytest -q` in `frameio-mirror/` reports 57 passed with no `TMPDIR` override
  2. `git log origin/main..HEAD` on the milestone branch shows the LRU commit (cherry-picked and conflict-resolved) and the test fix, nothing else from the old branch
  3. `_remember_c2c_folder` evicts the oldest folder and promotes a re-seen one; `_reconcile_folder_ids` returns newest-last, capped at 16
  4. `.impeccable/` no longer appears in `git status`
  5. `tests/run-on-tower.sh parallel-sort` prints `PASS parallel-sort` (48 cases) and cleans up after itself on tower

**Plans**: 3 plans

Plans:
**Wave 1**

- [x] 01-01-PLAN.md — (wave 1) Cherry-pick 0d566ce onto the milestone branch, prove `frameio-mirror/app.py` and `test_multi_folder.py` are byte-identical to that commit, record 57 passed
- [ ] 01-03-PLAN.md — (wave 1) `tests/run-on-tower.sh` helper for the Linux-only harnesses, documented in README § Tests and TESTING.md; baseline `PASS` from both harnesses (parallel-sort run is human-gated)

**Wave 2** *(blocked on Wave 1 completion)*

- [x] 01-02-PLAN.md — (wave 2, needs 01-01) Resolve the Frame.io tests' temp dirs with `os.path.realpath` so the suite passes with the default TMPDIR; verify `.impeccable/` is ignored

### Phase 2: Sorter Correctness

**Goal**: The sorter accepts every valid camera HEIF and stops reporting freshly arrived files as stuck.
**Depends on**: Phase 1
**Requirements**: SORT-01, SORT-02
**Success Criteria** (what must be TRUE):

  1. A HEIF fixture with three zero bytes after its last box sorts into `heif/`; the truncated fixture still quarantines
  2. A file whose mtime is hours old but whose ctime is seconds old is not logged `STUCK` by the reconcile scan
  3. `tests/parallel-sort.sh` passes in full inside the sorter image (existing 48 cases plus the new ones)

**Plans**: 1 plan
**Executor model**: opus (Bash validators plus the 2,600-line harness)

Plans:

- [ ] 02-01: Trailing-pad tolerance in `heif_container_validate` and `-cmin` in the STUCK scan, each with a harness case

### Phase 3: Observability and Panel Honesty

**Goal**: Every aborted FTP upload reaches Telegram once, the panel reports arrival age truthfully, mirror failures are diagnosable from the log, and "verified" means bytes matched.
**Depends on**: Phase 1
**Requirements**: OBS-01, OBS-02, OBS-03, PANEL-01
**Success Criteria** (what must be TRUE):

  1. With stubbed `docker logs` output containing a `451-Transfer aborted` sequence, one healthcheck run sends one Telegram message naming the file, bytes, and speed; a second run sends nothing new
  2. `/api/status` reports `age_s` from ctime; a file with an old mtime dropped moments ago shows a small age
  3. `frameio-mirror` log lines for a failed listing or Telegram send include the exception class name even when `str(exc)` is empty
  4. `prune_verified` deletes a quarantined file only when a same-name library file is byte-identical; a same-size different-bytes file survives

**Plans**: 3 plans

Plans:

- [ ] 03-01: Abort alert in `contrib/unraid/ftpdropbox-healthcheck.sh` with fingerprint dedup; extend the docker stub and `tests/unraid-healthcheck.sh`
- [ ] 03-02: Panel ctime age plus byte-verified `in_library`/`prune_verified`; new `panel/tests/` pytest
- [ ] 03-03: Exception type and repr in mirror logging; unit test for the empty-message case

### Phase 4: Deploy and Verify

**Goal**: Tower runs the merged milestone and each fix is proven against the live system, with a human approving every production change.
**Depends on**: Phase 2, Phase 3
**Requirements**: DEPLOY-01, DEPLOY-02
**Success Criteria** (what must be TRUE):

  1. `docker exec camera-sorter md5sum /sort.sh` and the panel's `/app/app.py` match the merged commit; `/boot/config/scripts/ftpdropbox-healthcheck.sh` matches `contrib/unraid/`
  2. `sorted/2026-08-22/heif/DSCF8283.HIF` exists and the sorter log shows `ok: DSCF8283.HIF`
  3. `tests/pure-ftpd-abort.py` from the Mac produces exactly one Telegram abort alert within five minutes
  4. `dropbox-panel` shows `/etc/telegram.json` and `/health` mounted `ro` in `docker inspect`
  5. README and `contrib/unraid/` document the abort alert and the read-only mounts

**Plans**: 2 plans
**Mode**: run with `/gsd-execute-phase 4 --interactive`; every tower mutation is a `checkpoint:human-verify`

Plans:

- [ ] 04-01: Docs (README, healthcheck header, panel docker run) and the tower deploy runbook with exact commands
- [ ] 04-02: Execute the runbook on tower with checkpoints: build, swap sorter, swap panel, install healthcheck, retry HIF, prove the abort alert, optional debris cleanup

## Progress

**Execution Order:**
Phases execute in numeric order: 1 → 2 → 3 → 4 (2 and 3 may run in parallel after 1)

| Phase | Plans Complete | Status | Completed |
|-------|----------------|--------|-----------|
| 1. Baseline | 2/3 | In Progress|  |
| 2. Sorter Correctness | 0/1 | Not started | - |
| 3. Observability and Panel Honesty | 0/3 | Not started | - |
| 4. Deploy and Verify | 0/2 | Not started | - |
