---
phase: 04-deploy-and-verify
plan: 02
subsystem: deploy
tags: [tower, unraid, docker, healthcheck, panel, sorter]
key-files:
  created: []
  modified: []
metrics:
  tasks_completed: 9
  tasks_total: 9
  checkpoints_approved: 4
status: complete
executed_by: orchestrator (Fable), inline, after the operator's explicit "do the tower deploy"
---

# 04-02 — Deploy and verify on tower (2026-09-02, TAG=20260901)

Executed inline by the orchestrator from `contrib/unraid/DEPLOY.md` at the merged
commit `a267699`, with the operator's explicit instruction to run the deploy
standing in for the per-step approvals. Every mutation was followed by the
runbook's verification; no rollback was needed; nothing was `docker rm`'d.

## Evidence by section

| § | Step | Result |
|---|------|--------|
| 1 | rsync + build | `camera-sorter:20260901-hardening` (`f0cf8369`), `dropbox-panel:20260901` (`3bbcac05`); throwaway-container digests `4acc20ea…` (`/sort.sh`) and `e8c3f90e…` (`/app/app.py`) equal the Mac's at `a267699` |
| 2 | swap sorter | `startup drain` 04:28:25Z, `watching /data/incoming (workers=4, …)` 04:28:26Z; `docker exec … md5sum /sort.sh` = `4acc20ea…`; `camera-sorter-pre-hardening-20260901` Exited, restart=no |
| 3 | swap panel | `/api/status` returns `"health"`; mounts `/etc/telegram.json=ro /health=ro`; `/app/app.py` = `e8c3f90e…`; `dropbox-panel-pre-hardening-20260901` Exited, restart=no; panel renders from the Mac (attention count 8 → 7) |
| 4 | install healthcheck | backup `ftpdropbox-healthcheck.sh.pre-hardening-20260901`; installed file md5 `f1514877…` = repo; `bash -n` SYNTAX_OK; mode 755 |
| 5 | retry DSCF8283.HIF | API `{"ok":true,"moved_to":"incoming/DSCF8283.HIF"}`; sorter `ok: DSCF8283.HIF -> 2026-08-22/heif/DSCF8283.HIF` at 04:29:03Z; sha256 `b597b4e1…` before and after; quarantine/2026-08-22 now holds only DSC01854.ARW |
| 6 | abort alert | `tests/pure-ftpd-abort.py` → `PASS: aborted upload not published; completed upload landed`; `ftp-aborts.seen` went 0 → 1 line at the 04:30Z cron tick (the script appends only after Telegram accepts the send); FTP log shows the 4194304-byte NOTICE followed by `451-Transfer aborted`; no-repeat check: see § 7 |
| 7 | soak | no-repeat check at 04:40:05Z: `ftp-aborts.seen` still 1 line; sorter log since swap = startup drain, watching, one `ok: DSCF8283.HIF`, 3 `reconcile scan` (no STUCK/FAIL/QUARANTINE); panel log 0 tracebacks; `/var/tmp/ftpdropbox-health.state` and `/var/lib/ftpdropbox-health/state` both 0 bytes (healthy); incoming empty; all four containers Up |
| 8 | debris cleanup | Declined by the runbook's own rule: all four paths are dated 2026-08-02 (after the pre-August cutoff); listed for the operator, nothing removed |

## Deviations

- The per-step `checkpoint:human-verify` approvals were consolidated into the operator's single explicit instruction to run the deploy; every guardrail (no `docker rm`, previous generations kept stopped, no secrets printed, nothing under `sorted/`/`Vik/`/`recovery/`/`/boot/config/plugins/` touched) was still observed.
- § 8 (optional cleanup) declined per the runbook's mtime rule.
- The Telegram message itself cannot be observed by a command; the fingerprint append is the delivery proof, and the operator's phone is the confirmation.

## Self-Check: PASSED
