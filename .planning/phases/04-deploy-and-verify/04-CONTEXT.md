# Phase 4: Deploy and Verify - Context

**Gathered:** 2026-09-01
**Status:** Ready for planning
**Source:** Orchestrator decisions from the 2026-09-01 live-deployment review (every decision below is locked)
**Mode:** run with `/gsd-execute-phase 4 --interactive`; every tower mutation is a `checkpoint:human-verify` task

<domain>
## Phase Boundary

Write the deploy runbook and docs (Plan 04-01, autonomous), then execute the runbook on tower with a human approving each production change (Plan 04-02, checkpoints). Proves DSCF8283.HIF sorts, the abort alert fires end to end, and the panel mounts are read-only. The Frame.io mirror is not rebuilt in this milestone.

</domain>

<decisions>
## Implementation Decisions

### Plan 04-01 — Docs and runbook (DEPLOY-02, autonomous)
- **D-01:** Create `contrib/unraid/DEPLOY.md`: the exact commands below, parametrized by `TAG=$(date +%Y%m%d)`, with the "keep the previous container stopped as `<name>-pre-<change>-<TAG>` with restart=no" convention the operator already uses. This file is the runbook Plan 04-02 executes.
- **D-02:** README: under the Unraid/ops notes, add that the healthcheck cron also alerts on aborted FTP uploads (one message per abort, deduplicated), and that the panel's `telegram.json` and health mounts are read-only in the documented `docker run`. Update the panel `docker run` snippet in README (and `docker-compose.yml` if it mounts `telegram.json` into the panel) to `:ro`. Two to six lines of prose; no new sections.
- **D-03:** Commit subject `docs: deploy runbook and abort-alert notes`.

### Plan 04-02 — Execute on tower with checkpoints (DEPLOY-01)
Run in `--interactive` mode. Each numbered step that mutates tower is its own `checkpoint:human-verify` with the exact command shown; read-only verification steps are `type="auto"`.

- **D-04 (build, auto):** From the merged milestone commit: `rsync -a --delete --exclude .git --exclude .planning --exclude .impeccable ./ root@10.0.0.100:/tmp/sorter-build/` then on tower `docker build -t camera-sorter:$TAG-hardening -t camera-sorter:latest /tmp/sorter-build` and `docker build -t dropbox-panel:$TAG -t dropbox-panel:latest /tmp/sorter-build/panel`. Building does not touch running containers.
- **D-05 (swap sorter, checkpoint):** 
  ```
  docker rename camera-sorter camera-sorter-pre-hardening-$TAG && docker stop camera-sorter-pre-hardening-$TAG && docker update --restart=no camera-sorter-pre-hardening-$TAG
  docker run -d --name camera-sorter --user 99:100 --restart unless-stopped \
    -e SORT_WORKERS=4 -e NEF_LENS_MASSAGE=1 -e NEF_QUEUE=/data/nef-queue \
    -v /mnt/user/appdata/camera-sorter/telegram.json:/etc/telegram.json:ro \
    -v /mnt/nvmenetworkstorage/FTPDropbox:/data \
    -v /mnt/cache/appdata/camera-sorter/state:/var/lib/camera-sorter \
    camera-sorter:latest
  ```
  Verify: `docker logs camera-sorter` shows `startup drain` then `watching /data/incoming (workers=4, ...)` within 60 s; `docker exec camera-sorter md5sum /sort.sh` equals `md5sum sort.sh` on the Mac at the merged commit.
- **D-06 (swap panel, checkpoint):**
  ```
  docker rename dropbox-panel dropbox-panel-pre-hardening-$TAG && docker stop dropbox-panel-pre-hardening-$TAG && docker update --restart=no dropbox-panel-pre-hardening-$TAG
  docker run -d --name dropbox-panel --user 99:100 --restart unless-stopped -m 512m -p 8484:8484 \
    -e PANEL_ALLOWED_HOSTS=10.0.0.100,tower.local,localhost,127.0.0.1 \
    -e NEF_QUEUE_DIR=/data/nef-queue -e HEALTH_FILE=/health/state \
    -v /mnt/user/appdata/camera-sorter/telegram.json:/etc/telegram.json:ro \
    -v /mnt/nvmenetworkstorage/FTPDropbox:/data \
    -v /var/lib/ftpdropbox-health:/health:ro \
    dropbox-panel:latest
  ```
  Verify: `curl -s -H 'Host: 10.0.0.100:8484' http://127.0.0.1:8484/api/status` on tower returns JSON with `"health"`; `docker inspect dropbox-panel --format '{{range .Mounts}}{{.Destination}}={{.Mode}} {{end}}'` shows `/etc/telegram.json=ro` and `/health=ro`; the panel loads at http://10.0.0.100:8484 from the Mac.
- **D-07 (install healthcheck, checkpoint):** `cp /boot/config/scripts/ftpdropbox-healthcheck.sh /boot/config/scripts/ftpdropbox-healthcheck.sh.pre-hardening-$TAG` then `scp contrib/unraid/ftpdropbox-healthcheck.sh root@10.0.0.100:/boot/config/scripts/` and `chmod 755` it. Verify `md5sum` matches on both sides and `bash -n` passes on tower. Cron picks it up on the next 5-minute tick; no `update_cron` needed for an edited file.
- **D-08 (retry the HIF, auto after D-05):** from the Mac: `curl -s -X POST http://10.0.0.100:8484/api/quarantine/action -H 'Content-Type: application/json' -d '{"action":"retry","rel":"2026-08-22/DSCF8283.HIF"}'` → `{"ok":true,"moved_to":"incoming/DSCF8283.HIF"}`. Within about 90 s the sorter log shows `ok: DSCF8283.HIF -> 2026-08-22/heif/DSCF8283.HIF` and `sorted/2026-08-22/heif/DSCF8283.HIF` exists with sha256 equal to the pre-retry quarantine copy (record it before retrying). If it quarantines again, stop and report the `validate:` line.
- **D-09 (prove the abort alert, auto after D-07):** from the Mac run `python3 tests/pure-ftpd-abort.py ftp://cameras:cameras@10.0.0.101/` (it aborts an 8 MB `ftpdropbox-abort-test.part` upload, then uploads and deletes it cleanly). Within one cron interval (≤ 5 min, poll `ls -la /var/lib/ftpdropbox-health/ftp-aborts.seen` on tower) exactly one fingerprint line appears and the operator confirms one Telegram message naming `ftpdropbox-abort-test.part`. Wait a second interval and confirm no repeat.
- **D-10 (soak, auto):** After ten minutes: `docker logs --since 10m camera-sorter` contains only `reconcile scan` lines and the retry's `ok:` line; `docker logs --since 10m dropbox-panel` has no tracebacks; `/var/tmp/ftpdropbox-health.state` is empty (healthy).
- **D-11 (optional cleanup, checkpoint, may be declined):** remove pre-August debris in the data root: `/mnt/nvmenetworkstorage/FTPDropbox/.raw-validate-tmp`, `.sort-process-locks`, `.notify-queue.lock`, `.sort-move.lock` (the current sorter keeps locks under `/var/lib/camera-sorter`; the legacy queue check only cares about `.notify-queue.tsv`-style files, which do not exist). Show `ls -la` first; do not touch `recovery/` or `Vik/` — those are the user's call and out of scope.
- **D-12:** Record in `contrib/unraid/DEPLOY.md` (not executed now) the frameio-mirror recreate command for its next rebuild: `docker run -d --name frameio-mirror --user 99:100 --restart unless-stopped --network br0 --ip 10.0.0.106 -e INCOMING_DIR=/data/incoming -e REFRESH_TOKEN_FILE=/var/lib/frameio/state.json -e STAGING_DIR=/var/lib/frameio/staging -e DELETE_UPSTREAM=1 -e FRAMEIO_WORKERS=4 -v /mnt/nvmenetworkstorage/FTPDropbox:/data -v /mnt/cache/appdata/frameio-mirror/private:/var/lib/frameio -v /mnt/user/appdata/frameio-mirror/frameio.json:/etc/frameio.json:ro -v /mnt/user/appdata/camera-sorter/telegram.json:/etc/telegram.json:ro frameio-mirror:<tag>` with the same rename-previous convention, and the note that the mirror must run as 99:100 (its state-dir privacy check fails as root).

### Guardrails (non-negotiable)
- **D-13:** No step in this phase runs `docker stop|rm|rename|run` without the human approving that exact checkpoint. Never `docker rm` anything; renamed previous containers stay for rollback.
- **D-14:** Rollback for any step: `docker stop <new> && docker rename <new> <new>-failed-$TAG && docker rename <name>-pre-hardening-$TAG <name> && docker start <name>` (and `docker update --restart=unless-stopped`). Put this in DEPLOY.md.
- **D-15:** Never print the contents of `telegram.json`, `frameio.json`, or `state.json`; never touch `sorted/`, `Vik/`, `recovery/`, or `/boot/config/plugins/`.

### Claude's Discretion
- Ordering of D-05 versus D-06 (independent); whether to keep `:latest` tags moving (yes, the operator's convention).

</decisions>

<specifics>
## Specific Ideas

- Current production facts (from `docker inspect` on 2026-09-01): sorter env `SORT_WORKERS=4 NEF_LENS_MASSAGE=1 NEF_QUEUE=/data/nef-queue`, mounts as in D-05 (telegram already `ro`); panel env and mounts as in D-06 but `telegram.json` and `/health` are currently read-write; both on the default bridge; panel memory limit 512 MiB; previous generations are kept as `*-pre-*-2026082x` containers with restart=no.
- `tests/pure-ftpd-abort.py` PASSes against the fork (verified 2026-08-22); it must run from the Mac because tower cannot reach the macvlan address 10.0.0.101.
- The panel's CSRF guard accepts requests without an `Origin` header, so plain `curl` works for D-08; `Host` must be one of the allowlisted names (using the IP:port satisfies it).

</specifics>

<canonical_refs>
## Canonical References

**Downstream agents MUST read these before planning or implementing.**

- `.planning/PROJECT.md` § Context — deployment facts; § Constraints — safety rules
- `.planning/codebase/CONCERNS.md` — operational guardrails for agents
- `contrib/unraid/ftpdropbox-healthcheck.sh` (post Phase 3) — what the cron now alerts on
- `tests/pure-ftpd-abort.py` — the live abort probe
- `README.md` — sections that mention `telegram.json`, `docker run`, and Unraid

</canonical_refs>

<code_context>
## Existing Code Insights

### Reusable Assets
- The operator's build dirs `/tmp/sorter-build` and `/tmp/panel-build` already exist on tower (uid 502 files from earlier rsyncs); reuse `/tmp/sorter-build` and build the panel from its `panel/` subdirectory.

### Established Patterns
- Image tags carry the date (`camera-sorter:20260822-dupes`), `:latest` moves with them, previous containers are renamed and kept stopped.

### Integration Points
- The healthcheck reads container names `camera-ftp` or `pure-ftpd`; production uses `pure-ftpd`.

</code_context>

<deferred>
## Deferred Ideas

- Rebuilding `frameio-mirror` (only OBS-03 logging changed): next time it is rebuilt, using D-12.
- Unraid Docker templates for sorter and panel (they are CLI-created today): a later milestone.

</deferred>

---

*Phase: 04-deploy-and-verify*
*Context gathered: 2026-09-01 by the orchestrator*
