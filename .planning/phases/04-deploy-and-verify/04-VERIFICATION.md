---
phase: 04-deploy-and-verify
status: passed
verified: 2026-09-02T04:41:00Z
verified_by: orchestrator (inline; tower evidence is not reachable by a subagent)
score: 5/5
---

# Phase 4 verification — Deploy and Verify

| # | ROADMAP success criterion | Evidence |
|---|---------------------------|----------|
| 1 | `docker exec camera-sorter md5sum /sort.sh` and the panel's `/app/app.py` match the merged commit; `/boot/config/scripts/ftpdropbox-healthcheck.sh` matches `contrib/unraid/` | `4acc20ea…`, `e8c3f90e…`, `f1514877…` — all equal to the Mac's digests at `a267699` |
| 2 | `sorted/2026-08-22/heif/DSCF8283.HIF` exists and the sorter log shows `ok: DSCF8283.HIF` | sorted at 04:29:03Z; sha256 `b597b4e1…` identical to the quarantine copy |
| 3 | `tests/pure-ftpd-abort.py` from the Mac produces exactly one Telegram abort alert within five minutes | probe PASS; `ftp-aborts.seen` 0 → 1 at the 04:30Z tick and still 1 at 04:40Z (the line is appended only after Telegram accepts the send) |
| 4 | `dropbox-panel` shows `/etc/telegram.json` and `/health` mounted `ro` | `docker inspect` mounts: `/etc/telegram.json=ro /data= /health=ro` |
| 5 | README and `contrib/unraid/` document the abort alert and the read-only mounts | README § Unraid notes (+2 lines); `contrib/unraid/DEPLOY.md` §§ 3, 4, 6 |

Requirements: DEPLOY-01 (04-02) and DEPLOY-02 (04-01) both satisfied. Rollback never exercised; previous generations `camera-sorter-pre-hardening-20260901` and `dropbox-panel-pre-hardening-20260901` remain stopped for inspection.

Human-side item outstanding: the operator confirms the Telegram message on their phone named `ftpdropbox-abort-test.part` (delivery to the API is proven by the fingerprint append; the rendered message is not observable by a command).
