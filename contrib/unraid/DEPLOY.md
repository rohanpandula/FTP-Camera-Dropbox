# Tower Deploy Runbook — 2026-09 Hardening

Tower is `root@10.0.0.100`. This is the runbook Plan 04-02 executes step by
step, with a human approving every command that touches a running container
(D-13). Read a whole numbered section before approving any command in it.

Commands below run on tower unless marked **(from the Mac)**: open `ssh
root@10.0.0.100` once and stay in that shell for the "on tower" commands in
each section; the Mac-side commands (the rsync, the two probe requests, and
every `md5sum`/`git rev-parse` against this checkout) run from the machine
that has this repository checked out.

## Before you start

Export `TAG` once, in the same shell that runs every command below — every
rename and every rollback in this document substitutes this exact value:

```bash
TAG=$(date +%Y%m%d)
```

**(from the Mac)** Record the merged milestone commit this deploy is built
from, before touching tower:

```bash
git rev-parse --short HEAD
```

Every digest comparison in this document is against that commit's `sort.sh`,
`panel/app.py`, and `contrib/unraid/ftpdropbox-healthcheck.sh`.

**Three guardrails, non-negotiable (D-13, D-15):**

- No swap without an approved checkpoint. No step below runs `docker stop|rm|rename|run` against a named production container without the human approving that exact checkpoint first.
- Never `docker rm` anything, anywhere in this document. Renamed previous containers stay stopped — they are the rollback.
- Never print the contents of `telegram.json`, `frameio.json`, or `state.json`. Never touch `sorted/`, `Vik/`, `recovery/`, or `/boot/config/plugins/`.

---

## 1. Build the images (D-04)

One rsync, two build contexts. The sorter's build context is the repo root,
because the root `Dockerfile` does `COPY sort.sh /sort.sh`. The panel's
build context is the `panel/` subdirectory of that same synced tree,
because `panel/Dockerfile` does `COPY app.py index.html /app/` and `COPY
assets /app/assets/`. Building touches no running container, so this step
needs no approval — but it is the last unapproved step in this document.

**(from the Mac):**

```bash
rsync -a --delete \
  --exclude .git --exclude .planning --exclude .impeccable --exclude .claude \
  --exclude '__pycache__' --exclude '.pytest_cache' --exclude '.ruff_cache' --exclude '.venv*' \
  ./ root@10.0.0.100:/tmp/sorter-build/
```

This extends D-04's exclude list to the vetted set already proven in
`tests/run-on-tower.sh`, instead of D-04's shorter three-flag list: `.claude/`
holds live executor worktree checkouts, and without the `__pycache__`
exclude, `panel/__pycache__` lands inside the panel build context — the
same fix recorded as the Plan 01-03 deviation.

On tower:

```bash
docker build -t camera-sorter:$TAG-hardening -t camera-sorter:latest /tmp/sorter-build
docker build -t dropbox-panel:$TAG -t dropbox-panel:latest /tmp/sorter-build/panel
```

**(from the Mac)** record the two digests every later step compares
against:

```bash
md5sum sort.sh
md5sum panel/app.py
```

On tower, the pre-swap digest check — a mismatch here stops the deploy
before any container is touched; catching it here costs nothing, catching
it after the swap costs a rollback:

```bash
docker run --rm --entrypoint md5sum camera-sorter:$TAG-hardening /sort.sh
docker run --rm --entrypoint md5sum dropbox-panel:$TAG /app/app.py
```

Compare both outputs against the Mac-side `md5sum sort.sh` / `md5sum
panel/app.py` above, at the merged commit recorded in "Before you start".

---

## 2. Swap the sorter (D-05)

Approve this checkpoint before running anything in this section.

On tower:

```bash
docker rename camera-sorter camera-sorter-pre-hardening-$TAG && docker stop camera-sorter-pre-hardening-$TAG && docker update --restart=no camera-sorter-pre-hardening-$TAG
docker run -d --name camera-sorter --user 99:100 --restart unless-stopped \
  -e SORT_WORKERS=4 -e NEF_LENS_MASSAGE=1 -e NEF_QUEUE=/data/nef-queue \
  -v /mnt/user/appdata/camera-sorter/telegram.json:/etc/telegram.json:ro \
  -v /mnt/nvmenetworkstorage/FTPDropbox:/data \
  -v /mnt/cache/appdata/camera-sorter/state:/var/lib/camera-sorter \
  camera-sorter:latest
```

Verify (on tower):

- `docker logs camera-sorter` shows `startup drain` then `watching /data/incoming (workers=4, ...)` within 60 seconds.
- `docker exec camera-sorter md5sum /sort.sh` equals the Mac's `md5sum sort.sh` at the merged commit.
- `docker ps -a --format '{{.Names}} {{.Status}}' | grep camera-sorter` lists both `camera-sorter` (Up) and `camera-sorter-pre-hardening-$TAG` (Exited).

If either of the first two checks fails, do not improvise — run § 9's
resolved rollback for `camera-sorter` and report.

---

## 3. Swap the panel (D-06)

Approve this checkpoint before running anything in this section. The only
change beyond the image is that `telegram.json` and `/health` become
`:ro` — the panel never writes either, and the 2026-09-01 review found both
mounted read-write.

On tower:

```bash
docker rename dropbox-panel dropbox-panel-pre-hardening-$TAG && docker stop dropbox-panel-pre-hardening-$TAG && docker update --restart=no dropbox-panel-pre-hardening-$TAG
docker run -d --name dropbox-panel --user 99:100 --restart unless-stopped -m 512m -p 8484:8484 \
  -e PANEL_ALLOWED_HOSTS=10.0.0.100,tower.local,localhost,127.0.0.1 \
  -e NEF_QUEUE_DIR=/data/nef-queue -e HEALTH_FILE=/health/state \
  -v /mnt/user/appdata/camera-sorter/telegram.json:/etc/telegram.json:ro \
  -v /mnt/nvmenetworkstorage/FTPDropbox:/data \
  -v /var/lib/ftpdropbox-health:/health:ro \
  dropbox-panel:latest
```

Verify (on tower):

- `curl -s -H 'Host: 10.0.0.100:8484' http://127.0.0.1:8484/api/status` returns JSON containing `"health"`.
- `docker inspect dropbox-panel --format '{{range .Mounts}}{{.Destination}}={{.Mode}} {{end}}'` shows `/etc/telegram.json=ro` and `/health=ro`.
- `docker exec dropbox-panel md5sum /app/app.py` equals the Mac's `md5sum panel/app.py` at the merged commit — ROADMAP Phase 4 criterion 1 needs the panel digest too, and D-06's own verification list omits it.
- `docker ps -a --format '{{.Names}} {{.Status}}' | grep dropbox-panel` lists both `dropbox-panel` (Up) and `dropbox-panel-pre-hardening-$TAG` (Exited).

Verify (from the Mac): load http://10.0.0.100:8484 in a browser — the panel
renders and the header lamp shows a value.

If any of the on-tower checks fails, do not improvise — run § 9's resolved
rollback for `dropbox-panel` and report.

---

## 4. Install the healthcheck (D-07)

Approve this checkpoint before running anything in this section.

On tower, back up the installed script first — this is the reversal for
this step:

```bash
cp /boot/config/scripts/ftpdropbox-healthcheck.sh /boot/config/scripts/ftpdropbox-healthcheck.sh.pre-hardening-$TAG
```

**(from the Mac)** install the new one:

```bash
scp contrib/unraid/ftpdropbox-healthcheck.sh root@10.0.0.100:/boot/config/scripts/
```

On tower, restore the mode and confirm both sides match and the script
parses:

```bash
chmod 755 /boot/config/scripts/ftpdropbox-healthcheck.sh
md5sum /boot/config/scripts/ftpdropbox-healthcheck.sh
bash -n /boot/config/scripts/ftpdropbox-healthcheck.sh && echo SYNTAX_OK
ls -l /boot/config/scripts/ftpdropbox-healthcheck.sh
```

**(from the Mac)** compare: `md5sum contrib/unraid/ftpdropbox-healthcheck.sh`.

Cron picks up an edited script on its next 5-minute tick; no `update_cron`
is needed for an edited file (only for a new cron line). `/boot/config/scripts/`
is in scope for this step; `/boot/config/plugins/` is not, and nothing
under it is ever read or written (D-15).

Do not `cat` the script's config files or the state-dir contents beyond
`ls` — the Telegram credentials live at the `TG_JSON` path and must never
be printed (D-15).

If the two `md5sum` outputs differ, do not improvise — restore the backup:

```bash
cp /boot/config/scripts/ftpdropbox-healthcheck.sh.pre-hardening-$TAG /boot/config/scripts/ftpdropbox-healthcheck.sh && chmod 755 /boot/config/scripts/ftpdropbox-healthcheck.sh
```

and report.

---

## 5. Retry DSCF8283.HIF (D-08)

No approval needed — this runs no `docker stop|rm|rename|run` (D-13) and
touches nothing under `sorted/` by hand; the panel moves one quarantined
file to `incoming/` and the new sorter files it, which is the pipeline
doing its job. Requires § 2 (the new sorter) to have landed.

On tower, record the pre-retry digest first — without it, "landed intact"
is unprovable afterward:

```bash
sha256sum /mnt/nvmenetworkstorage/FTPDropbox/quarantine/2026-08-22/DSCF8283.HIF
```

**(from the Mac):**

```bash
curl -s -X POST http://10.0.0.100:8484/api/quarantine/action \
  -H 'Content-Type: application/json' \
  -d '{"action":"retry","rel":"2026-08-22/DSCF8283.HIF"}'
```

Expect exactly `{"ok":true,"moved_to":"incoming/DSCF8283.HIF"}`. This
request needs no `Origin` header because the panel's CSRF guard accepts
requests that carry none, and `Host: 10.0.0.100:8484` satisfies
`PANEL_ALLOWED_HOSTS`.

Within about 90 seconds, confirm on tower:

```bash
docker logs --since 5m camera-sorter 2>&1 | grep -F 'ok: DSCF8283.HIF'
sha256sum /mnt/nvmenetworkstorage/FTPDropbox/sorted/2026-08-22/heif/DSCF8283.HIF
```

The log line reads `ok: DSCF8283.HIF -> 2026-08-22/heif/DSCF8283.HIF`, and
the sha256 of the sorted file equals the pre-retry quarantine digest above.

D-08's stop rule, verbatim: if it quarantines again, stop and report the
`validate:` line. Do not retry a second time and do not touch the file by
hand — a second quarantine means SORT-01 did not fix this file's case and
the phase needs a decision, not another attempt.

---

## 6. Prove the abort alert (D-09)

No approval needed — this runs no docker verb and creates only a file the
probe itself deletes. Requires § 4 (the installed script) to have landed
and at least one cron tick, since the alert is the newly installed
script's.

On tower, record the current fingerprint count first, so "exactly one new
line" is measurable:

```bash
wc -l < /var/lib/ftpdropbox-health/ftp-aborts.seen 2>/dev/null || echo 0
```

**(from the Mac)** run the probe — tower cannot reach the macvlan address
10.0.0.101, so this must run from the Mac:

```bash
python3 tests/pure-ftpd-abort.py ftp://cameras:cameras@10.0.0.101/
```

It must print `PASS: aborted upload not published; completed upload
landed`.

On tower, poll for up to one cron interval (5 minutes, per
`contrib/unraid/ftpdropbox.cron`):

```bash
ls -la /var/lib/ftpdropbox-health/ftp-aborts.seen
```

Exactly one new fingerprint line must appear — a bare sha256 digest; the
file never holds filenames. Confirm the filename side from the FTP
container's own log instead:

```bash
docker logs --since 20m pure-ftpd 2>&1 | grep -c 'ftpdropbox-abort-test.part'
```

and from the operator's Telegram confirmation, which no command can
observe. Then wait a second full 5-minute interval and re-poll the line
count: it must not change — one alert per abort, not one per cron tick.

Use `ls`/`wc`/`grep -c` on this state dir only; do not `cat` anything else
under `/var/lib/ftpdropbox-health/` (D-15).

---

## 7. Soak (D-10)

No approval needed — read-only. Wait ten minutes after § 3, then read three
things and nothing else, on tower:

```bash
docker logs --since 10m camera-sorter
docker logs --since 10m dropbox-panel
```

The sorter log contains only `reconcile scan` lines plus § 5's `ok:` line
— no `STUCK`, `FAIL`, or `QUARANTINE:` for a file nobody sent. The panel
log contains no Python traceback.

The healthcheck state file must be empty or absent, which is how this
script says "healthy". D-10 names `/var/tmp/ftpdropbox-health.state`, but
`contrib/unraid/ftpdropbox-healthcheck.sh` defaults `STATE` to
`/var/lib/ftpdropbox-health/state`, and `contrib/unraid/ftpdropbox.cron`
sets no override — so check both paths and treat "empty or absent" as
healthy for whichever one the running cron actually writes:

```bash
wc -c < /var/tmp/ftpdropbox-health.state 2>/dev/null || echo ABSENT
wc -c < /var/lib/ftpdropbox-health/state 2>/dev/null || echo ABSENT
```

Use `wc -c`, not `cat` — this directory is root-only state (D-15).

---

## 8. Optional — pre-August debris cleanup (D-11)

Declinable, and complete either way — declining does not affect DEPLOY-01
or any ROADMAP Phase 4 criterion. `recovery/` and `Vik/` are the user's
call and are never in this list (D-15).

On tower, look before removing:

```bash
ls -la /mnt/nvmenetworkstorage/FTPDropbox/.raw-validate-tmp \
  /mnt/nvmenetworkstorage/FTPDropbox/.sort-process-locks \
  /mnt/nvmenetworkstorage/FTPDropbox/.notify-queue.lock \
  /mnt/nvmenetworkstorage/FTPDropbox/.sort-move.lock
```

The current sorter keeps its locks under `/var/lib/camera-sorter`, and the
legacy queue check only cares about `.notify-queue.tsv`-style files, which
do not exist — that is D-11's justification for treating these four paths
as debris. If the listing shows an mtime after 2026-08-01, or any path
outside these four, decline instead of removing: an active lock is not
debris.

Only if the listing looks like pre-August debris, and only after the
operator approves, remove exactly those four paths and nothing else:

```bash
rm -rf /mnt/nvmenetworkstorage/FTPDropbox/.raw-validate-tmp \
  /mnt/nvmenetworkstorage/FTPDropbox/.sort-process-locks \
  /mnt/nvmenetworkstorage/FTPDropbox/.notify-queue.lock \
  /mnt/nvmenetworkstorage/FTPDropbox/.sort-move.lock
```

Then confirm the pipeline did not notice:

```bash
ls -la /mnt/nvmenetworkstorage/FTPDropbox/ | head -30
docker logs --since 2m camera-sorter
```

`sorted/`, `quarantine/`, `incoming/`, `recovery/`, and `Vik` are all still
there, and the sorter log shows no new `FAIL`. Nothing under `sorted/`,
`Vik/`, or `recovery/` is ever in the removal list — if the `rm` you are
about to approve names any of those, stop, it is wrong.

---

## 9. Rollback (D-14)

Rollback for any container swap, verbatim:

```bash
docker stop <new> && docker rename <new> <new>-failed-$TAG && docker rename <name>-pre-hardening-$TAG <name> && docker start <name> && docker update --restart=unless-stopped <name>
```

Resolved for `camera-sorter`, so the operator can paste without
substituting:

```bash
docker stop camera-sorter && docker rename camera-sorter camera-sorter-failed-$TAG && docker rename camera-sorter-pre-hardening-$TAG camera-sorter && docker start camera-sorter && docker update --restart=unless-stopped camera-sorter
```

Resolved for `dropbox-panel`:

```bash
docker stop dropbox-panel && docker rename dropbox-panel dropbox-panel-failed-$TAG && docker rename dropbox-panel-pre-hardening-$TAG dropbox-panel && docker start dropbox-panel && docker update --restart=unless-stopped dropbox-panel
```

For § 4 (the healthcheck script), the rollback is copying the backup back
over the installed script:

```bash
cp /boot/config/scripts/ftpdropbox-healthcheck.sh.pre-hardening-$TAG /boot/config/scripts/ftpdropbox-healthcheck.sh && chmod 755 /boot/config/scripts/ftpdropbox-healthcheck.sh
```

Never `docker rm` anything, in a rollback or anywhere else in this
document — the renamed `-failed-$TAG` container is left stopped for
inspection, exactly like every other previous generation (D-13).

---

## 10. frameio-mirror — recorded, not executed (D-12)

This milestone does not rebuild `frameio-mirror`; only a log-format change
(OBS-03) lands there, and production keeps running its current unmerged
branch. This section is not a step in this deploy — it is recorded here
for the mirror's next rebuild, using the same rename-previous convention as
every other container in this document. Never `docker rm` the old one when
that day comes, either.

```bash
docker run -d --name frameio-mirror --user 99:100 --restart unless-stopped \
  --network br0 --ip 10.0.0.106 \
  -e INCOMING_DIR=/data/incoming \
  -e REFRESH_TOKEN_FILE=/var/lib/frameio/state.json \
  -e STAGING_DIR=/var/lib/frameio/staging \
  -e DELETE_UPSTREAM=1 -e FRAMEIO_WORKERS=4 \
  -v /mnt/nvmenetworkstorage/FTPDropbox:/data \
  -v /mnt/cache/appdata/frameio-mirror/private:/var/lib/frameio \
  -v /mnt/user/appdata/frameio-mirror/frameio.json:/etc/frameio.json:ro \
  -v /mnt/user/appdata/camera-sorter/telegram.json:/etc/telegram.json:ro \
  frameio-mirror:<tag>
```

The mirror must run as `99:100` — its state-dir privacy check fails when it
runs as root. The rename-previous convention applies here too:
`docker rename frameio-mirror frameio-mirror-pre-<change>-$TAG && docker
stop frameio-mirror-pre-<change>-$TAG && docker update --restart=no
frameio-mirror-pre-<change>-$TAG` before starting the new one. Config paths
appear above; their contents never do (D-15).
