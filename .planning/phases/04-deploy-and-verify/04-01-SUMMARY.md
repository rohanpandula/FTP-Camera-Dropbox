---
phase: 04-deploy-and-verify
plan: 01
subsystem: infra
tags: [docs, unraid, docker, runbook, deployment, telegram]

# Dependency graph
requires:
  - phase: 03-observability-and-panel-honesty
    provides: "the abort-alert healthcheck script (OBS-01) this runbook installs, and the panel age/prune honesty fixes it digests"
provides:
  - "contrib/unraid/DEPLOY.md — the ten-section tower runbook Plan 04-02 executes step by step"
  - "README.md Unraid notes extended with the abort-alert and read-only-mount facts"
affects: [04-02-execute-and-verify]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "Runbook sections numbered 1-10, each self-contained with its own verify block and rollback pointer, so an operator can cite a section number instead of re-deriving a command"
    - "Every mutating docker command marked '(on tower)' vs Mac-only commands marked '(from the Mac)', avoiding redundant ssh-wrapping while staying copy-paste-safe"

key-files:
  created: [contrib/unraid/DEPLOY.md]
  modified: [README.md]

key-decisions:
  - "docker-compose.yml needed no :ro edit — both panel optional mounts (lines 517, 520) already carry :ro; verified by direct read of the panel: service block, not just the plan's grep count"
  - "Single combined commit for both tasks, subject 'docs: deploy runbook and abort-alert notes' (D-03), per this plan's explicit override of the default one-commit-per-task pattern"
  - "README edits inserted as new standalone lines immediately after each paragraph's last existing line (not a reflow of the hard-wrapped paragraph), so git diff shows 0 deletions and exactly 2 additions"

patterns-established:
  - "New sentence extending a hard-wrapped README paragraph: append as a new line directly after the paragraph's last line (no blank line between), never edit the existing line's text — keeps diffs additive-only in a hard-wrapped file"

requirements-completed: [DEPLOY-02]

# Metrics
duration: 20min
completed: 2026-09-01
---

# Phase 4 Plan 01: Deploy Runbook and Abort-Alert Notes Summary

**Wrote the 433-line `contrib/unraid/DEPLOY.md` tower runbook (10 sections: build, swap sorter, swap panel, install healthcheck, retry DSCF8283.HIF, prove the abort alert, soak, optional debris cleanup, D-14 rollback, D-12 frameio-mirror recreate) and extended two README paragraphs with the abort-alert and read-only-mount facts — zero tower access, zero code changes.**

## Performance

- **Duration:** ~20 min
- **Completed:** 2026-09-01T22:23:13Z
- **Tasks:** 2 (both `type="auto"`)
- **Files modified:** 2 (1 created, 1 modified)

## Accomplishments

- `contrib/unraid/DEPLOY.md` created: every command in D-04 through D-12, D-14, and D-15 copied verbatim from `04-CONTEXT.md`, parametrized by `TAG=$(date +%Y%m%d)`, organized into 10 numbered sections an operator (or Plan 04-02) can cite by number.
- README's Unraid notes extended with two sentences: the healthcheck cron also alerts on aborted FTP uploads (deduplicated, one message per abort), and the panel's `telegram.json`/`/health` mounts are already read-only in `docker-compose.yml`.
- Confirmed `docker-compose.yml` needs no edit — the panel's two optional mounts were already `:ro` before this plan ran.

## Task Commits

Both tasks were combined into a single commit per this plan's explicit D-03 instruction (overriding the default one-commit-per-task pattern):

1. **Task 1: Write contrib/unraid/DEPLOY.md** + **Task 2: README abort-alert and read-only-mount notes** — `29bd9fb` (docs)

_No plan-metadata commit needed beyond this one — `contrib/unraid/ftpdropbox-healthcheck.sh` was never touched, confirmed via `git diff --name-only HEAD~1`._

## Files Created/Modified

- `contrib/unraid/DEPLOY.md` (new, 433 lines) — the tower deploy runbook. Section list, resolved:
  1. Build the images (D-04) — rsync (vetted exclude set from `tests/run-on-tower.sh`) + two `docker build` + pre-swap digest check
  2. Swap the sorter (D-05) — rename/stop/update + `docker run -d --name camera-sorter` + verify
  3. Swap the panel (D-06) — rename/stop/update + `docker run -d --name dropbox-panel` (both mounts `:ro`) + verify, including the panel `md5sum /app/app.py` check D-06's own list omitted
  4. Install the healthcheck (D-07) — backup, `scp`, `chmod`, two-sided `md5sum` + `bash -n`
  5. Retry DSCF8283.HIF (D-08) — pre-retry sha256, the retry `curl`, log/sha256 confirmation, stop rule
  6. Prove the abort alert (D-09) — pre-probe fingerprint count, `tests/pure-ftpd-abort.py` from the Mac, poll `ftp-aborts.seen`, second-interval no-repeat check
  7. Soak (D-10) — 10-minute log check + both candidate healthcheck state paths (D-10's named path and the script's actual default)
  8. Optional — pre-August debris cleanup (D-11) — `ls -la` first, declinable, four named paths only
  9. Rollback (D-14) — generic recipe plus resolved versions for `camera-sorter` and `dropbox-panel`, plus the healthcheck-script rollback
  10. frameio-mirror — recorded, not executed (D-12) — full recreate command for its next rebuild
- `README.md` (+2 lines, 0 deletions) — two paragraphs in § Optional: Unraid-Specific Notes extended:
  - The paragraph beginning "The healthcheck accepts either the Compose FTP name…" gained: *"The same cron also alerts on an aborted FTP upload: it reads the FTP container's log for a `451-Transfer aborted`, reports the filename, bytes received, KB/s, and the advice to re-send from the card, sending one message per abort, deduplicated through a fingerprint file in that same directory."*
  - The paragraph beginning "Mounted config files (`telegram.json`, `frameio.json`, `oauth-state.json`) need to be owned by…" gained: *"The panel needs only read access to its mounts: its optional `telegram.json` and health-state mounts in `docker-compose.yml` are already read-only (`:ro`), since the panel never writes either."*

## docker-compose.yml — no edit needed (confirmed)

Per Task 2's instruction, verified directly by reading the `panel:` service block (lines 495-524): both optional mounts already carry `:ro`:
```
# - /var/lib/ftpdropbox-health:/health:ro
# - ./telegram.json:/etc/telegram.json:ro
```
`docker-compose.yml` is untouched — `git status --short` after the commit shows nothing outstanding.

Note for future runs of this check: `grep -c 'telegram.json:/etc/telegram.json:ro' docker-compose.yml` returns **3**, not the 1 the plan's acceptance criterion expected — the sorter (line 392), `frameio-mirror` (line 469), and the panel (line 520) each have their own commented optional `telegram.json` mount example sharing that exact substring. The panel-specific line (520, paired with 517 for `/health:ro`) is what matters and was confirmed `:ro` directly; the `/var/lib/ftpdropbox-health:/health:ro` grep does return exactly 1 as expected (only the panel mounts `/health`). This is a note about the acceptance script's count assumption, not a deviation requiring a code change.

## Decisions Made

- **Single commit for both tasks**, subject exactly `docs: deploy runbook and abort-alert notes` (D-03) — the plan explicitly instructs this in Task 2's action, the acceptance criteria, and the success criteria, overriding the executor's normal one-commit-per-task default.
- **README additions as new standalone lines**, not paragraph reflow — README.md is hard-wrapped in the source file (confirmed via `sed -n 'l'` showing backslash-continued lines with no trailing double-space hard-breaks). Appending each new sentence as a new line directly after the paragraph's existing last line (no blank line inserted) keeps the change purely additive (`git diff --stat README.md` = `2 insertions(+), 0 deletions`) while still rendering as part of the same paragraph in Markdown.
- **Command placement convention** (`(on tower)` vs `(from the Mac)`) stated once in DEPLOY.md's preamble rather than re-wrapping every command in `ssh root@10.0.0.100 '...'` — matches the style Plan 04-02's own `<how-to-verify>` blocks use for its checkpoint tasks (Tasks 2-4), and keeps every command exactly as copy-pasted from `04-CONTEXT.md` with no wrapper mutation.

## Deviations from Plan

None — plan executed exactly as written. `docker-compose.yml` needed no edit (expected outcome, confirmed). No task required a Rule 1/2/3 auto-fix.

## Issues Encountered

None. All ten required headings, all eleven required literal strings, both `docker run -d --name {camera-sorter,dropbox-panel}` lines, zero bare `docker rm` lines, and zero secret-pattern matches were confirmed via the plan's own automated verification loops before committing.

## User Setup Required

None — no external service configuration required. Nothing in this plan touched tower or any secret file.

## Next Phase Readiness

- `contrib/unraid/DEPLOY.md` is ready for Plan 04-02 to execute section by section under `--interactive`, citing `§ N` instead of re-deriving any command.
- README now documents both ROADMAP Phase 4 criterion 5 facts (abort alert, read-only mounts) in its existing Unraid notes — no new section, no restructuring.
- `contrib/unraid/ftpdropbox-healthcheck.sh` remains untouched by this plan, confirmed via `git diff --name-only HEAD~1`, so Phase 3's landing of that file this week has no collision risk.
- No blockers for Plan 04-02.

---
*Phase: 04-deploy-and-verify*
*Completed: 2026-09-01*

## Self-Check: PASSED

- FOUND: `contrib/unraid/DEPLOY.md`
- FOUND: `.planning/phases/04-deploy-and-verify/04-01-SUMMARY.md`
- FOUND: commit `29bd9fb` (docs: deploy runbook and abort-alert notes)
- FOUND: commit `275fdd7` (docs: complete 04-01 plan metadata)
