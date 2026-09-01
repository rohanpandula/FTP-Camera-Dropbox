# FTP Camera Dropbox — 2026-09 Hardening

## What This Is

A self-hosted camera intake pipeline: cameras push over Wi-Fi FTP (and Frame.io Camera-to-Cloud) to an Unraid box, a Bash sorter validates each file and files it by capture date, and a LAN web panel shows status. This milestone fixes the bugs and blind spots found in the 2026-09-01 review of the live deployment (tower, 10.0.0.100).

## Core Value

Every file a camera sends either lands intact in `sorted/` or the operator is told exactly which file did not. Silent loss is the one failure this system must never have.

## Requirements

### Validated

<!-- Shipped and observed working on tower during the 2026-09-01 review. -->

- ✓ Atomic FTP uploads; the pure-ftpd fork never publishes an aborted transfer — PR #11
- ✓ Byte-identical re-sends staged under `quarantine/_dupes/` and pruned after 7 days — PR #12
- ✓ Concurrent sorting with process claims, pinned descriptors, no-clobber moves — PR #1, #4
- ✓ Frame.io mirror with durable publication journal and size-gated upstream delete — PR #2
- ✓ Frame.io LRU folder registry (running on tower as image `frameio-mirror:folder-lru`, unmerged)
- ✓ Panel "Archive Accession Ledger" redesign with prune-verified action — PR #14
- ✓ BASE-01..04 — LRU registry on main's lineage, Frame.io suite green on macOS, `.impeccable/` ignored, `tests/run-on-tower.sh` proven (48/48 in 3m31s) — Validated in Phase 1: Baseline (2026-09-01)
- ✓ SORT-01, SORT-02 — HEIF trailing-pad tolerance (padded fixture sorts, truncated still quarantines), STUCK scan on ctime; harness 50/50 on tower — Validated in Phase 2: Sorter Correctness (2026-09-01)
- ✓ OBS-01..03, PANEL-01 — healthcheck alerts once per aborted FTP upload (fingerprint-deduped, 23/23 harness on tower), panel age from ctime, byte-verified prune with `kept`, mirror logs exception type+repr (59 tests) — Validated in Phase 3: Observability and Panel Honesty (2026-09-01)

### Active

- [ ] DEPLOY — tower rebuilt from the merged branch, DSCF8283.HIF retried, abort alert observed end to end

### Out of Scope

- `/data/Vik` (495 Nikon files outside `sorted/`, not backed up) — the user's data; a manual decision, not code
- Loosening per-model RAW size floors — no false positive observed (DSC01854.ARW is a real truncation: StripByteCounts runs past EOF)
- Panel reading pure-ftpd logs directly — would need the docker socket inside the panel; rejected on trust-boundary grounds
- Making the healthcheck state dir readable by the panel — the script enforces root 0700 by design; the derived lamp stays
- Raising pure-ftpd's 15-minute idle timeout — the fix is telling the operator, not waiting longer for a dying link
- The uncommitted panel draft in this checkout — an older draft of what merged as dd352b1/4c0a55d; stash it, never merge it
- Rebuilding the frameio-mirror container — only a log-format change lands there; redeploy on its next rebuild (commands recorded in Phase 4 context)

## Context

**Deployment (tower = 10.0.0.100, Unraid, CLI-created containers, not compose):**
- `camera-sorter` runs `sort.sh` == origin/main; user 99:100; `/data` = `/mnt/nvmenetworkstorage/FTPDropbox`; state `/mnt/cache/appdata/camera-sorter/state` at `/var/lib/camera-sorter`
- `dropbox-panel` == origin/main (4c0a55d); port 8484; `PANEL_ALLOWED_HOSTS` set; `/health` from `/var/lib/ftpdropbox-health` (root 0700, so the panel lamp is always "derived")
- `frameio-mirror` == branch `fix/frameio-folder-lru` (LRU registry), br0 static IP 10.0.0.106, `DELETE_UPSTREAM=1`, public via Cloudflare tunnel (c2c.roflix.club)
- `pure-ftpd` = repo fork image `ftp-camera-dropbox/pure-ftpd:20260822`, br0 10.0.0.101, `ADDED_FLAGS=-d -d -0`; the tower host cannot reach it (macvlan) — FTP tests run from the Mac
- Root cron: `/boot/config/scripts/ftpdropbox-{healthcheck,fixperms,backup}.sh` (identical to `contrib/unraid/`), healthcheck every 5 min, state in `/var/lib/ftpdropbox-health/`
- Container logs are UTC; pure-ftpd logs are Pacific

**Review findings with evidence (2026-09-01):**
1. `sort.sh` `heif_container_validate` quarantined a valid X100VI HIF (`quarantine/2026-08-22/DSCF8283.HIF`, exiftool Validate OK). Boxes: ftyp 24, meta 1007, free 3057, mdat 10498053 → ends at byte 10502141 of 10502144; three zero pad bytes remain; the walker demands 8 bytes for another header and logs "truncated box header". Its RAF twin is in the library with `.xmp`/`.acr` edits. 40 of 40 sampled sorted HIFs have zero slack, so the pad is rare but real.
2. Since the pure-ftpd fork (Aug 22), aborted uploads vanish silently: DSC01931.ARW (3 tries, Aug 22–23), DSC01932.ARW (2 tries, Aug 22), C0090.MP4 (Aug 31, 60.9 MB at 65 KB/s, 451 Timeout after 910 s). None exist in `sorted/` or `quarantine/`; no sorter log line, no Telegram. Before the fork the partial landed in quarantine with an alert.
3. The STUCK scan (`find -mmin`) and the panel's `age_s`/derived lamp key on mtime. SMB drags preserve capture-time mtime, so on Aug 29 04:23 nine R00000xx files were logged `STUCK >60min` one second before they sorted, and the panel lamp goes red ("stuck >90min") during every card drag.
4. `frameio-mirror` logged `Reconcile listing failed: ` and `Telegram send exception: ` with empty messages (httpx timeout exceptions stringify empty).
5. Panel `prune_verified` and `in_library` compare name+size only; the sorter's own dupe check compares bytes. Uncompressed RAWs all share one size.
6. This checkout was 11 commits behind origin/main with an older draft of the panel redesign uncommitted; the LRU registry commit (0d566ce) is unmerged while main carries the opposite "refuse the 17th folder" behavior.
7. Minor: panel mounts `telegram.json` read-write; `.impeccable/` (8.8 MB of design screenshots) untracked; pre-August lock debris in `/data` root (`.raw-validate-tmp`, `.sort-process-locks`, `.notify-queue.lock`, `.sort-move.lock`), root-owned `recovery/` from June.

**Test infrastructure facts:**
- `tests/parallel-sort.sh` (48 cases) and the `tests/unraid-*.sh` harnesses run only inside the sorter image on Linux (GNU coreutils, inotify, /proc). Local Docker on this Mac is colima (`colima start` if stopped). Fallback: build and run on tower in throwaway `--rm` containers under `/tmp/<branch>-build`, never touching named production containers.
- `frameio-mirror/tests` (57 tests) run locally with `python3 -m pytest`; on macOS they currently need `TMPDIR=/private/tmp` (symlinked `/var` trips the canonical-path check) until BASE-02 lands.
- `tests/panel-static.sh` checks the panel HTML contract (needs `node`).

## Constraints

- **Tech stack**: Bash 5 (`sort.sh`, `contrib/unraid/*.sh`), Python 3.12 FastAPI (`panel/`, `frameio-mirror/`). No new dependencies; stdlib first.
- **Safety**: Agents never stop, remove, rename, or recreate production containers on tower, never edit `/boot/config/plugins/` (the healthcheck under `/boot/config/scripts/` is installed only through Phase 4's human-gated step), never read secrets (`frameio.json`, `telegram.json`, `state.json`). Deployment is a human-gated phase run with `--interactive`.
- **Compatibility**: `sort.sh` keeps passing all existing harness cases; frameio keeps 57 passing; healthcheck fixture suite keeps passing. Validators stay strict except the one specified tolerance.
- **Style**: shortest diff that fixes the root cause; comments explain why; no new abstractions; mark deliberate ceilings with `# ponytail:`.
- **Data**: the library on tower is the user's live working set (Lightroom sidecars beside RAWs). Never move or delete anything under `sorted/`.

## Key Decisions

<!-- Decisions that constrain future work. Add throughout project lifecycle. -->

| Decision | Rationale | Outcome |
|----------|-----------|---------|
| FTP-abort alerts come from the root healthcheck cron, not the panel | The cron already has docker and Telegram; the panel has no docker socket by design | — Pending |
| HEIF: accept fewer than 8 trailing bytes after at least one parsed box; no zero-byte requirement | X100VI pads to 4-byte alignment; exiftool accepts; real truncation still fails on "box overruns EOF" | — Pending |
| ctime (arrival) for the STUCK scan and panel age; mtime stays for `STABLE_SKIP_AGE` | SMB drags preserve capture-time mtime; ctime is when the inode landed | — Pending |
| Prune stays "verified": byte compare via `filecmp.cmp(shallow=False)` | Uncompressed RAWs share sizes; PRODUCT.md principle 2 forbids overclaiming verification | — Pending |
| LRU registry semantics win over main's refuse-newest | The newest folder is exactly what a missed webhook needs backfilled | — Pending |
| One milestone branch `gsd/2026-09-hardening` off origin/main, one PR at the end | Small related fixes; avoids per-phase PR churn; `git.branching_strategy` stays `none` | — Pending |
| Executor model: sonnet by default, opus for Phase 2 (sort.sh + 2,600-line harness) | Bash validators and the harness reward a stronger model; the rest is routine | — Pending |
| Deploy phase is human-gated with exact commands pre-written | Production host; container swaps are not reversible by an agent | — Pending |

---
*Last updated: 2026-09-01 after Phase 3 (Observability and Panel Honesty) completed*
