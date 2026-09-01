---
phase: 03-observability-and-panel-honesty
plan: 01
subsystem: monitoring
tags: [bash, docker, telegram, pure-ftpd, healthcheck, cron]

# Dependency graph
requires: []
provides:
  - "FTP abort probe in contrib/unraid/ftpdropbox-healthcheck.sh: pairs each 451-Transfer aborted with the preceding upload NOTICE by (user@host) session token and sends one Telegram alert per new abort naming the file, MB received and KB/s"
  - "ABORT_WINDOW knob (default 15m, charset-validated ^[0-9]{1,4}[smh]$, falls back to 15m instead of exiting on a bad value)"
  - "Fingerprint dedup file ${STATE%/*}/ftp-aborts.seen: sha256 of <451-timestamp>|<sanitized filename>|<bytes>, 0600, capped at 500 lines, appended only after a successful Telegram send"
  - "tests/fixtures/healthcheck/docker gains a logs) branch driven by FAKE_FTP_LOG_FILE"
  - "tests/unraid-healthcheck.sh gains 5 cases (18 -> 23 PASS: lines): paired abort, dedup-on-repeat, silent success, two-aborts-one-window, unpaired-abort-unknown-file"
affects: ["Phase 4 deploy (copies this script to /boot/config/scripts/ and observes the alert end to end on tower)", "any future OBS-04/OBS-05 work that reads this same pure-ftpd log"]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "Bash while-IFS=-read + [[ =~ ]] regex log parser with a declare -A session map (session token -> bytes|speed|basename) pairing an upload NOTICE with the 451-Transfer aborted that follows it, map entry cleared on pairing so a second abort for the same session cannot reuse a stale NOTICE"
    - "Event alert bypassing the existing $problems/commit_state state-change machinery entirely: sent directly via tg(), deduped by a separate sha256 fingerprint file instead of the persistent-state diff pattern used elsewhere in the script"

key-files:
  created: []
  modified:
    - contrib/unraid/ftpdropbox-healthcheck.sh
    - tests/fixtures/healthcheck/docker
    - tests/unraid-healthcheck.sh

key-decisions:
  - "Followed CONTEXT.md D-01 through D-06 as specified; no architectural deviations"

patterns-established:
  - "Fingerprint-file dedup for event alerts (as opposed to persistent-state alerts): sha256 of a pipe-delimited string, appended to a 0600 file only after a successful send, bounded via tail -n 500 written through the same mktemp+chmod+mv atomic shape commit_state() already uses"

requirements-completed: [OBS-01]

# Metrics
duration: ~12min (worktree base 21:44:29Z to final tower verification 21:55:33Z; file-reading/setup time not separately instrumented from commit-to-commit spans)
completed: 2026-09-01
---

# Phase 3 Plan 1: FTP abort alert in the root healthcheck Summary

**Root cron healthcheck now reads the pure-ftpd container's own log, pairs each `451-Transfer aborted` with the upload NOTICE that preceded it, and sends one Telegram message per new abort (file, MB, KB/s) — deduplicated by a sha256 fingerprint file so overlapping 5-minute cron windows never repeat one.**

## Performance

- **Duration:** ~12 min
- **Started:** 2026-09-01T21:44:29Z (worktree base commit `e3b5663`, used as the session-start proxy)
- **Completed:** 2026-09-01T21:56:13Z
- **Tasks:** 3 completed (2 committed, 1 verification-only)
- **Files modified:** 3

## Accomplishments
- Aborted FTP uploads (previously silent since the pure-ftpd fork stopped publishing them — DSC01931.ARW, DSC01932.ARW, C0090.MP4 were lost with zero signal) now produce exactly one Telegram alert each, naming the file, MB received and KB/s.
- The probe is provably isolated from the existing state-change alerting: `add "` call count unchanged at 18, `commit_state ` call count unchanged at 2 — an abort is an event, never a persistent state.
- `ABORT_WINDOW` is charset-validated and self-heals to `15m` on a bad value rather than taking the whole healthcheck down.
- `tests/unraid-healthcheck.sh` grew from 18 to 23 `PASS:` cases, all passing end to end on tower via `tests/run-on-tower.sh unraid-healthcheck` (run twice for confirmation; not flaky).
- Pure-lazy parser: one `while read` + two `[[ =~ ]]` regexes, no new dependency, no new abstraction — matches the plan's Claude's-Discretion note that Bash regex over the small log is fine.

## Task Commits

Each task was committed atomically:

1. **Task 1: Teach the docker stub to serve container logs** - `75acda8` (tests)
2. **Task 2: FTP abort probe with fingerprint dedup, plus its five harness cases** - `8233bb9` (healthcheck)
3. **Task 3: Prove the abort alert on tower and record the evidence** - verification only, no commit (see Verification Evidence below)

**Plan metadata:** committed alongside this SUMMARY.md and REQUIREMENTS.md

## Files Created/Modified
- `contrib/unraid/ftpdropbox-healthcheck.sh` - header comment documents the new alert and `ABORT_WINDOW`; `ABORT_WINDOW` knob added and validated beside `DOCKER_TIMEOUT`; new probe block inserted between the FTP-listening probe and the Frame.io health-endpoint probe, guarded by `$ftp_container` non-empty + `running` (no GRACE gate — an abort right after a restart still deserves an alert)
- `tests/fixtures/healthcheck/docker` - new `logs)` branch prints `${FAKE_FTP_LOG_FILE}` (or nothing when unset) and exits 0; `exit 64` default for unknown subcommands untouched
- `tests/unraid-healthcheck.sh` - 5 new cases (Case 1-5 per plan, including the orchestrator-added Case 5 for the unpaired-abort fallback), each writing its own log fixture inline via a quoted heredoc into `$CASE_DIR/ftp.log`, no new fixture files added under `tests/fixtures/`

## Decisions Made
None beyond CONTEXT.md's locked D-01 through D-06 — plan executed as specified. The log-parser regex shape (Bash `[[ =~ ]]` with `declare -A` session map, no awk subprocess per line) was Claude's Discretion per CONTEXT.md and follows the plan's own guidance to pick Bash regex since the log is small.

## Deviations from Plan

None - plan executed exactly as written. All 5 harness cases match the plan's Task 2 Part 4 specification (including the orchestrator's post-plan-check Case 5 addition), and every acceptance-criteria grep count in the plan (`add "` = 18, `commit_state ` = 2, `ABORT_WINDOW` ≥ 3, `docker_cmd logs --since` = 1, `sha256sum` ≥ 1, `tr -d` ≥ 1, `PASS:` = 23, etc.) was verified locally before each commit.

## Issues Encountered

One self-caught near-miss during implementation, fixed before any commit: my first draft of the new probe's explanatory comment used the phrase "bypasses ... commit_state entirely," which itself matched the plan's own acceptance grep `grep -c 'commit_state '` (that check is not comment-exclusive, unlike the `add "` check). Reworded to "calls commit_state()" before running the acceptance checks or committing — no incorrect wording was ever shipped. Documented here only because it's a good illustration of why that specific acceptance criterion checks the whole file rather than just executable lines.

## User Setup Required

None - no external service configuration required. Deployment of this script to `/boot/config/scripts/` on tower is explicitly out of scope for this plan (Phase 4).

## Next Phase Readiness
- OBS-01 fully satisfied: probe exists, header documents it, harness has 23 `PASS:` cases (18 pre-existing + 5 new), `$problems`/`commit_state` machinery provably untouched, code and tests landed in one `healthcheck:` commit as required.
- Phase 4 (Deploy) can copy this script to `/boot/config/scripts/` and observe the real abort alert end to end via `tests/pure-ftpd-abort.py` (DEPLOY-01) — no further work needed on the probe itself.
- No blockers. Sibling plans in this phase (panel arrival-age/byte-verified prune, mirror exception logging) touch disjoint files (`panel/`, `frameio-mirror/`) and were not touched by this plan.

## Verification Evidence

**Task 3 — `PASS unraid-healthcheck` (run twice on tower via `tests/run-on-tower.sh unraid-healthcheck`, identical result both times):**

First run (untimed) and a second, timed confirmation run:
```
PASS unraid-healthcheck
```
Wall clock (second, timed run): `2026-09-01T21:55:22Z` → `2026-09-01T21:55:33Z` (~11s, consistent with the ~10s-plus-build baseline recorded in `01-03-SUMMARY.md`; tower's Docker layer cache was already warm).

`grep -c '^PASS:'` on the captured output: `23` (both runs).

The five new sentences were present in the captured output on both runs:
- `PASS: an aborted upload alerts once with file, size and speed`
- `PASS: a repeated abort in the next window is not re-sent`
- `PASS: a completed upload sends no abort alert`
- `PASS: two aborts in one window send two messages`
- `PASS: unpaired abort alerts as unknown file`

`All Unraid healthcheck tests passed.` present; final line exactly `PASS unraid-healthcheck` both times.

**Static gates (verified locally before each commit):**
- `bash -n contrib/unraid/ftpdropbox-healthcheck.sh` → exits 0
- `bash -n tests/unraid-healthcheck.sh` → exits 0
- `bash -n tests/fixtures/healthcheck/docker` → exits 0
- `grep -c 'add "' contrib/unraid/ftpdropbox-healthcheck.sh` → `18` (D-03: no new problem lines)
- `grep -c 'commit_state ' contrib/unraid/ftpdropbox-healthcheck.sh` → `2` (D-03: state machinery untouched)
- `grep -c '^echo "PASS:' tests/unraid-healthcheck.sh` → `23`
- `git log --oneline -1 --format=%s` → `healthcheck: alert once per aborted FTP upload`

**Standalone parser dry-run (pure Bash, no docker/tower involved, run before the tower round-trip to catch logic errors cheaply):** confirmed the exact message text `⚠️ FTP upload aborted: C0090.MP4 — 60.9 MB received at 65 KB/s before pure-ftpd gave up (451)...` for the paired case, silence for the 226-success case, two distinct messages (DSC01932.ARW, DSC01931.ARW) for the two-aborts case, and the `unknown file` fallback with the 451 timestamp for the unpaired case.

---
*Phase: 03-observability-and-panel-honesty*
*Completed: 2026-09-01*

## Self-Check: PASSED

- FOUND: `contrib/unraid/ftpdropbox-healthcheck.sh`
- FOUND: `tests/fixtures/healthcheck/docker`
- FOUND: `tests/unraid-healthcheck.sh`
- FOUND: `.planning/phases/03-observability-and-panel-honesty/03-01-SUMMARY.md`
- FOUND: commit `75acda8` (Task 1 — docker stub `logs` branch)
- FOUND: commit `8233bb9` (Task 2 — abort probe + 5 harness cases)
- CONFIRMED: `OBS-01` checked off and marked Complete in `.planning/REQUIREMENTS.md`'s traceability table
- CONFIRMED: `.planning/STATE.md` and `.planning/ROADMAP.md` untouched by this plan (worktree mode excludes them per orchestrator instructions)
