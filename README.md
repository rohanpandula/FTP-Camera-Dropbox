# FTP Camera Dropbox

A self-hosted FTP server and auto-organizer for digital cameras. Point your Fuji, Sony, or Nikon at it over Wi-Fi and it sorts RAWs, JPEGs, HEIFs, and videos into `<date>/<type>/` folders. It also validates files, preserves same-name uploads safely, quarantines bad uploads, and can batch Telegram notifications every 5 minutes.

## Why

Most modern cameras (Fuji X-series, Sony Alpha, Nikon Z) can upload over Wi-Fi via FTP. It's a protocol they speak natively: no app, no USB, no card reader. The gap is on the receiving end. Lightroom's auto-import means buying Lightroom, the vendor apps are bloated and flaky, and cloud transfer ships your RAFs off to someone else's server.

This is a Lightroom-style auto-import folder that runs on your own hardware, with nothing to install beyond Docker.

## Features

- Auto-sorts by EXIF `DateTimeOriginal` → `YYYY-MM-DD/raw|jpg|heif|video/filename`
- Falls back to file mtime when the EXIF date is missing or suspicious
- Content validation: RAW size floor + severe ExifTool EOF checks + LibRaw unpack check, JPEG SOI/EOI checks, HEIF box-boundary checks, and video moov/Duration checks
- Collision-safe naming (`file`, `file_2`, `file_3`, …) for same-name files with different bytes; a byte-identical re-send (camera retry, SD-card drag of shots that already uploaded) is staged under `quarantine/_dupes/` and pruned after 7 days instead of becoming a `_2` copy — nothing is ever deleted in the ingest path
- Quarantine folder for files that fail validation (truncated uploads, corrupted transfers)
- Vendored pure-ftpd fork (`pure-ftpd/`): Debian's package rebuilt with a one-hunk patch so an aborted upload deletes its temp file instead of being published as a truncated partial — quarantine only ever sees real corruption (`tests/pure-ftpd-abort.py` proves it)
- Handles camera retry storms: `wait_stable` holds until the file size is unchanged for 60 seconds
- Processes independent files concurrently with a bounded worker pool (4 workers by default)
- Optional Telegram notifications, batched per 5-minute window instead of one ping per file
- Reconcile scan every 5 minutes catches anything inotify missed
- Stuck-file detection flags uploads that have been sitting in incoming too long
- Offline-capable: the sorter needs no inbound network, only outbound for Telegram
- **Optional Frame.io C2C mirror.** Receives webhooks from Frame.io, durably queues bounded downloads via the V4 API, and hands verified bytes to the same `incoming/` directory the sorter watches. Downloads remain on a separate private staging mount until the no-clobber handoff is durable. Frame.io retains its copy by default; upstream deletion is an explicit size-and-SHA-256-gated opt-in. Works with Enterprise S2S OAuth and personal OAuth Web App credentials. See [frameio-mirror/README.md](frameio-mirror/README.md).

## Quickstart

```bash
cp .env.example .env
# Edit PUBLICHOST to your host machine's LAN IP
nano .env

docker compose up -d

# Logs from the sorter
docker logs -f camera-sorter
```

On first start, the one-shot `data-init` service creates
`incoming/`, `sorted/`, and `quarantine/`, gives the data writers the same
numeric owner, and makes the private sorter-state volume mode `0700`. The FTP
virtual user, sorter, and optional Frame.io mirror therefore all write as
`99:100` by default instead of racing over a new `root:root` volume.

Point your camera at your host's IP, port 21, user `cameras`, password `cameras`. Take a shot. Watch the logs.

Sorted files end up in the Docker named volume `camera_data`. To access them on the host:

```bash
docker run --rm -v ftp-camera-dropbox_camera_data:/data alpine ls /data/sorted
```

Or switch to a bind mount; see the comments in `docker-compose.yml`.

## Camera Setup

Set your camera's FTP settings as follows:

| Setting | Value |
|---|---|
| Server Type / Protocol | **FTP** (not SFTP, not FTPS) |
| Server Address | Your host machine's LAN IP |
| Port | **21** |
| Connection Mode | **Passive (PASV)** |
| User | `cameras` |
| Password | `cameras` |
| Target Folder | `/` |
| SSL/TLS / Secure Transfer | **OFF** |

### Where to find these menus by brand

| Brand | Menu path |
|---|---|
| **Fujifilm** | Network Settings → PC AutoSave → Change PC Settings (or FTP Upload Settings on newer bodies) |
| **Sony** | Menu → Network → Transfer/Remote → FTP Transfer Function → FTP Server Settings |
| **Nikon** | Menu → Network → Connect to FTP server → Options → Server. Turn on **Auto send** (or mark shots for upload), or the camera connects but never pushes files. |

## Configuration

All settings have sensible defaults. Override via `.env` or environment variables in `docker-compose.yml`:

| Variable | Default | Description |
|---|---|---|
| `FTP_USER` | `cameras` | FTP username |
| `FTP_PASS` | `cameras` | FTP password |
| `PUID` | `99` | Numeric UID shared by the pure-ftpd virtual user, sorter, Frame.io mirror, and volume initializer. |
| `PGID` | `100` | Numeric GID shared by the pure-ftpd virtual user, sorter, Frame.io mirror, and volume initializer. |
| `CAMERA_DATA_SOURCE` | `camera_data` | Shared storage source for every writer and the initializer. Use the named volume by default, or set `./data`/an absolute host path for a bind mount. This new opt-in name deliberately ignores legacy `DATA_DIR=./data` settings, so an upgrade cannot silently hide an existing named-volume library. |
| `PUBLICHOST` | `127.0.0.1` | IP advertised to clients in PASV mode. Set this to your host LAN IP. |
| `STABLE_WAIT` | `60` | Seconds to wait for file size to remain unchanged before processing. |
| `STABLE_SKIP_AGE` | `3600` | Files already older than this many seconds skip the quiet wait so a cold-start backlog drains quickly; structural/RAW validation still runs. |
| `SORT_WORKERS` | `4` | Maximum files stabilized and validated concurrently. Keep this bounded because RAW decoding also uses memory and temporary disk. |
| `LOCK_ROOT` | `/var/lib/camera-sorter` | Private persistent control mount for locks and notification queues. Compose mounts its state volume at this exact path; every sorter writing the same output tree must share it. Do not place it in the SMB/FTP-exported camera tree. |
| `WATCH_READY_TIMEOUT` | `30` | Seconds allowed for the inotify readiness handshake during startup. |
| `NOTIFY_INTERVAL` | `300` | How often to flush the Telegram notification queue (seconds) |
| `RAW_FULL_VALIDATE` | `1` | Run severe ExifTool EOF/corruption checks plus `raw-identify` and `simple_dcraw -D -4` before sorting RAW files. This catches truncated RAW payloads that still have readable EXIF. |
| `RAW_VALIDATE_TIMEOUT` | `240` | Per-command timeout for ExifTool metadata/integrity reads and LibRaw validation. A command that ignores TERM is forcibly killed after a 2-second grace period. |
| `RAW_VALIDATE_TMPDIR` | `/var/lib/camera-sorter/raw-validate-tmp` | Private temporary directory for LibRaw validation output. Full RAW unpack writes large PPMs here and deletes them after each check. |
| `RAW_VALIDATE_TMP_STALE_MIN` | `15` | Remove abandoned `raw.*` validation scratch directories older than this many minutes before the startup drain and during reconciliation. |
| `INCOMING` | `/data/incoming` | Directory FTP drops files into |
| `SORTED` | `/data/sorted` | Destination for successfully sorted files |
| `QUARANTINE` | `/data/quarantine` | Destination for files that fail validation |
| `RECONCILE_IDLE` | `300` | Maximum seconds between full reconcile scans, even while inotify events are arriving. |
| `STUCK_AGE_MIN` | `60` | Log a warning for files that have been sitting in incoming this long (minutes) |
| `DUPES_KEEP_DAYS` | `7` | Byte-identical re-sends of a file already in `sorted/` are staged under `quarantine/_dupes/<date>/` and deleted once older than this many days (by ctime, i.e. since staging). |
| `TG_CONFIG` | `/etc/telegram.json` | Path to Telegram credentials file inside the container |

### Telegram (optional)

Copy `telegram.json.example` to `telegram.json`, fill in your bot token and chat ID, then uncomment the `telegram.json` volume mount in `docker-compose.yml`.

```json
{
  "bot_token": "123456789:ABCdef...",
  "chat_id": "-1001234567890"
}
```

Get a bot token from [@BotFather](https://t.me/BotFather). Get your chat ID by sending a message to your bot and visiting `https://api.telegram.org/bot<TOKEN>/getUpdates`.

Notifications look like:

```
📸 12 file(s) uploaded in last 5 min:
• 9 × FUJIFILM X-T5
• 3 × SONY ILCE-7M4
```

If the config file is absent, the sorter starts normally and skips notifications. No crashes, no retries.

## Frame.io Camera-to-Cloud mirror (optional)

If you shoot with a body or phone paired to [Frame.io Camera-to-Cloud](https://frame.io/c2c), there's an opt-in second intake path. The mirror receives Frame.io V4 webhooks, downloads each asset via the API, size-verifies it, and hands it to the same `incoming/` directory the sorter watches. FTP and C2C uploads land in the same date-sorted library.

Downloads first land in `STAGING_DIR` (`/var/lib/frameio/staging` by default), an owner-only persistent mount that must be separate from the shared camera-data mount. Compose supplies it inside `frameio_state`; never place it under `/data` or bind it to the same mount as `incoming/`. This isolation prevents the sorter, FTP clients, and share users from changing or removing the only local copy while an upstream delete is in progress.

The parent of `REFRESH_TOKEN_FILE` is the same security boundary: it must be an owner-only private directory (or a root-protected system directory) on a mount distinct from `/data`. The mirror pins that directory for every state read/write and reports unhealthy if it is shared, symlinked, replaceable, or permissively writable. Compose's `frameio_state` volume satisfies both the state and staging requirements.

It keeps Frame.io's copy by default. Set `DELETE_UPSTREAM=1` only when you intentionally want quota-clearing deletion after the private local copy passes exact positive size and SHA-256 revalidation. After the retain/delete outcome is durable, the mirror copies the bytes to a unique hidden handoff in `incoming/`, verifies that copy, and atomically publishes a no-clobber filename. The private staged copy remains until the handoff and recovery journal are finalized; full media validation still happens next in the sorter.

Resource use is bounded independently of webhook traffic: `FRAMEIO_WORKERS=4` services a fixed `FRAMEIO_QUEUE_SIZE=256` queue, while durable pending state carries excess work into reconciliation. Each download also has a 20 GiB byte cap (`DOWNLOAD_MAX_BYTES=21474836480`) and a 30-minute overall deadline (`DOWNLOAD_MAX_SECONDS=1800`). Adjust these only for known larger source media and available storage/bandwidth.

Off by default. To bring it up:

```bash
docker compose --profile frameio up -d --build
curl http://localhost:8000/health
```

You'll need a public HTTPS endpoint pointing at `:8000` so Frame.io can POST webhooks. Cloudflare Tunnel, ngrok, or any reverse proxy with Let's Encrypt all work.

**Two auth modes:**

- **OAuth Server-to-Server**, for Enterprise Adobe organizations. Headless: add the credential in Dev Console, paste the `client_id` and `client_secret`, done.
- **OAuth Web App + refresh token**, for personal Adobe accounts (Adobe doesn't offer S2S to these). Set `OAUTH_SETUP_SECRET`, request a one-time authorization URL with an authenticated `POST /oauth/start`, then open that returned URL. Compose saves the refresh token, durable webhook jobs, publication journal, reconciliation IDs, and private staged bytes in its `frameio_state` volume.

`GET /health` verifies credentials, writable intake, the private staging boundary, and durable-state structure. Its filesystem probes run away from the request loop and the result is cached for five seconds, so a just-fixed condition may take one cache window to report healthy.

**Failure alerts** (also optional): mount the same `telegram.json` the sorter uses at `/etc/telegram.json` and the mirror sends throttled ⚠️ pings on real failures: Frame.io API errors, size mismatches, missing Adobe credentials. Throttling is per-kind and in-memory, so a stuck state can't spam you. The success path stays silent; the sorter handles "files landed" through its own batched queue.

Full setup (Frame.io webhook config, the click-by-click Adobe Dev Console walkthrough for both auth modes, env vars, alert behavior, endpoints) is in [frameio-mirror/README.md](frameio-mirror/README.md).

## Hard-Earned Gotchas

These are the things that cost real time to figure out.

**Cameras default to SFTP (port 22), not FTP (port 21).** This is the number one silent failure mode. pure-ftpd doesn't speak SSH; it sends RST to anything on port 22. The camera's symptom is a generic "connection failed" with no useful error. The network symptom (via tcpdump) is a clean TCP SYN to `:22`, an immediate RST from the server, then the camera retrying forever. The fix is one menu item: set `Server Type = FTP` (or `Protocol = FTP`), not `SFTP`. Some firmware calls it "secure" vs "not secure". You want not secure.

**Wi-Fi band makes an enormous difference. 2.4 GHz vs 5 GHz is not a "nice to have."** Numbers from real testing, same Fuji body, same room: 2.4 GHz at full bars was about 22 KB/s. 5 GHz from far across the house was about 80 KB/s. 5 GHz close to the access point was 600–1500 KB/s. A 100 MB RAF file takes 80 minutes on 2.4 GHz and roughly 1 minute on 5 GHz. It's not even close. Most Fuji X-bodies are 2.4 GHz only (X-T4 and earlier, the X-S series); the X-T5, X-H2, X-H2S, and GFX 100 II added 5 GHz. Signal strength matters too: a body in the same room as the AP beats one with "full bars" on a distant 2.4 GHz radio by 10×.

**`wait_stable` needs to be ~60 seconds for fresh uploads, not 2 seconds.** Cameras can pause for several seconds while reconnecting, so a 2-second check can bless a partial upload mid-retry. Fresh files therefore pay the full quiet-window check. A cold-start backlog whose mtimes are already at least `STABLE_SKIP_AGE` old (one hour by default) can skip that delay: this is longer than the observed FTP abort/retry window, and structural/LibRaw validation still runs before any move.

**pure-ftpd's `-0` (atomic uploads) still publishes aborted uploads.** It writes the transfer to a hidden `.pureftpd-upload.*` temp, but `dostor()` in `src/ftpd.c` renames that temp onto the real name *before* it checks whether the transfer completed. A camera whose Wi-Fi dies mid-file gets `451 Transfer aborted`, and the truncated partial still lands in `incoming/` under its final name (upstream master behaves the same, and the `-o` upload-script hook fires on aborts too). Every retry storm therefore filled quarantine with `DSC01833.ARW`, `DSC01833_2.ARW`, … next to one good copy in `sorted/`. `pure-ftpd/` rebuilds Debian's own pure-ftpd package with a one-hunk patch (plus the `CAP_SYS_NICE`/`CAP_DAC_READ_SEARCH` drop the stilliard image already carries, so the binary keeps its capability set): when the transfer ended in error and was not a `REST` resume, skip the rename, and the existing cleanup at the end of `dostor()` unlinks the temp. Compose builds it; for a CLI-managed container run `docker build -t ftp-camera-dropbox/pure-ftpd pure-ftpd/` and recreate the container from that image. `tests/pure-ftpd-abort.py ftp://cameras:cameras@HOST/` proves it: the script resets the data connection mid-upload the way a dying Wi-Fi link does and fails if anything appears under the final name — it fails against stock pure-ftpd, which is the point.

**Readable EXIF does not mean a RAW is intact.** A truncated RAW can still have valid camera/date metadata near the front of the file while the image payload ends early. RAW sorting therefore fails files with severe ExifTool EOF/corruption warnings, then runs `raw-identify` plus a full LibRaw unpack with `simple_dcraw -D -4` before moving the file to `sorted/`. This is slower and writes a large temporary PPM under the private sorter control mount, but it catches the "end of file" class of corruption before the file is blessed.

**A readable file type does not mean a video is intact.** The MP4 `ftyp` header sits at the front of the file, but camera QuickTime variants (Sony XAVC-S, Fuji MOV) write the `moov` index at the end, after the media data. So a transfer that dies partway leaves a file that still identifies as a perfectly good MP4 to a header check. Each retry may also die at a different byte count and otherwise look like another suffixed copy. Validation therefore requires an intact tail: any ExifTool "Truncated" warning fails the file, and MP4/MOV/M4V must yield a `Duration` (no `moov`, no blessing) — the video equivalent of the RAW EOF checks.

**A custom Alpine image beats fighting stilliard/pure-ftpd's anonymous mode.** Anonymous FTP (no username/password) is what you'd want ideally, so it's what I tried first. The stilliard/pure-ftpd image's anonymous mode has papercuts with Fuji firmware: some bodies insist on sending credentials even in "anonymous" mode, and the mismatch fails silently. A trivial `cameras`/`cameras` virtual user sidesteps all of it, and every camera firmware I tested accepts it. On a LAN with no internet exposure it's effectively zero-auth anyway.

**macvlan / br0 host-isolation is a red herring on Unraid.** If you assign each container a dedicated IP on br0, the Unraid host itself can't ping or connect to its own containers (`Destination Host Unreachable`). That's a Linux kernel rule about macvlan interfaces, not a bug in your FTP setup: the host and its macvlan children can't talk directly. Other devices on your LAN (including cameras) reach the containers fine. I spent a while convinced the FTP server was broken when it was just the host's network view that was isolated.

**A name collision never deletes anything in the ingest path.** A matching size or hash is not enough reason to *delete* the incoming copy: an SMB client can replace the existing leaf between the comparison and the unlink, and the incoming file might have been the only intact copy. So the sorter compares (against the pinned incoming fd, re-checking the destination inode afterwards) and then *moves*: a byte-identical re-send goes to `quarantine/_dupes/<date>/` — still on disk if that one-in-a-million swap ever happens — and is pruned after `DUPES_KEEP_DAYS`; anything that differs keeps both copies as `name_2.ext`, `name_3.ext`, … Real-world source of dupes: dragging an SD card into `incoming/` over SMB after the camera already FTP'd half of it.

### Frame.io mirror gotchas

**Frame.io V4 webhook payloads contain just `resource.id`. Everything else needs an authenticated API call.** No filename, no size, no pre-signed URL. The "maybe we can skip Adobe Dev Console" idea sounds reasonable until you read [the docs](https://developer.adobe.com/frameio/api/current/guides/webhooks/) literally: *"We do not include any additional information beyond the resource ID."* The mirror durably records the job, calls `GET /v4/accounts/{account_id}/files/{file_id}?include=media_links.original`, and streams the returned URL. Optional upstream deletion is a separate, disabled-by-default policy.

**Frame.io V4 signs `v0:<timestamp>:<body>`, not the body alone.** It's a Stripe-style scheme with two headers: `X-Frameio-Signature` (formatted `v0=<hex>`) and `X-Frameio-Request-Timestamp` (Unix epoch). It's HMAC-SHA256 with the secret encoded as latin-1. A naive `HMAC(secret, body)` returns 403 forever. Check the timestamp drift too, to block replays (5 minutes is sane).

**Adobe Server-to-Server OAuth is Enterprise-only.** Personal Adobe accounts only see `OAuth Web App`, `Single Page App`, and `Native App` in the Developer Console; there's no S2S option. For headless use from a personal account, run the OAuth Web App flow once in a browser to capture a `refresh_token`, persist it, then mint access tokens from the refresh grant. Adobe IMS refresh tokens don't expire unless they sit idle for months. The mirror's `/oauth/start` and `/oauth/callback` endpoints handle this in a single browser visit.

**Web App access tokens last 1 hour (S2S tokens last 24).** The mirror caches the token and refreshes it within 5 minutes of expiry, so you won't notice. But if you fork the auth flow, build the refresh in or you'll hit 401s at the worst time.

**Docker single-file bind mounts can't be atomic-renamed.** Mount a single file (not its parent directory) into a container and the kernel pins the destination inode, so `os.replace(tmp, dest)` raises `EBUSY`. Compose avoids that trap with a private state volume and atomic file replacement. A legacy single-file mount uses a guarded in-place fallback; use the volume/parent-directory layout for full atomic semantics.

**Your "free" static IP isn't guaranteed free.** Checking what's currently assigned to other containers before picking a br0 macvlan IP is necessary but not sufficient. If the IP is inside your DHCP pool, the router can hand it to an iPhone or Mac while your container runs, and you get a silent split-brain: ICMP succeeds (the other device answers) but TCP fails (nothing's listening on its port). Reserve the IP on the DHCP server, or pick one outside the dynamic range.

## How It Works

```
Camera (Wi-Fi FTP)
       |
       v
  pure-ftpd (:21)          -- vendored fork: an aborted upload never lands
       |  writes to
       v
  /data/incoming/          <-- shared Docker volume
       |
       |  inotifywait (close_write, moved_to)
       v
  camera-sorter
    worker pool (4)        -- separate files run concurrently
      wait_stable()        -- wait 60s for file size to stop changing
      get_type()           -- by extension
      get_date()           -- EXIF DateTimeOriginal, fallback to mtime
      validate_file()      -- RAW/JPEG/video integrity checks
      move_with_suffix()   -- pinned, locked no-clobber move with suffix retry
       |
       |-- ok     --> /data/sorted/YYYY-MM-DD/{raw,jpg,heif,video}/filename
       |-- bad    --> /data/quarantine/YYYY-MM-DD/filename
       |-- dupe   --> /data/quarantine/_dupes/YYYY-MM-DD/filename  (byte-identical re-send, pruned after 7d)
       |-- clash  --> both kept (`filename_2`, `filename_3`, ...)
       |
       v
  enqueue_notify()         -- append under the private control mount
  notifier_loop()          -- flush queue to Telegram every 5 min
```

At least every `RECONCILE_IDLE` seconds, a full directory scan runs to catch anything that was missed (power cycling, container restarts, overlapping events, and so on), even if unrelated inotify events keep arriving continuously.

The incoming, sorted, and quarantine roots must be distinct directories on the same filesystem. `LOCK_ROOT` must be a persistent private mount, owned by the sorter at mode `0700`, and shared by every sorter writing the same output tree. The sorter verifies Linux `flock` exclusion before processing, rejects symlinked roots and output paths, pins the validated destination directory while moving, and verifies source/destination inode state before reporting success. Notification queues and RAW scratch also live under the private control mount, outside the SMB/FTP namespace.

When upgrading from a version that kept notification state beside `incoming/`,
stop every sorter first. Legacy state includes the three base files
`.notify-queue.tsv`, `.quarantine-queue.tsv`, and `.perm-queue.tsv` plus their
`.flush.*` and `.failed.*` rotations. If any contains rows, the new sorter
refuses to start instead of silently abandoning it.

The safest migration is to let the old sorter flush current rows before the
upgrade. For rows that must be carried forward, create `$LOCK_ROOT/queues` as
the configured `PUID:PGID` with mode `0700`; create the destination files as
the same owner with mode `0600`; then, while all sorters remain stopped, append
each legacy artifact exactly once using this mapping:

| Legacy name prefix | Private destination |
|---|---|
| `.notify-queue.tsv` | `queues/notify-queue.tsv` |
| `.quarantine-queue.tsv` | `queues/quarantine-queue.tsv` |
| `.perm-queue.tsv` | `queues/perm-queue.tsv` |

Compare source and destination row counts, then move each migrated artifact to
a retained archive outside the camera data root. A historical `.failed.*` row
that should not generate a late Telegram message can be archived without being
appended. Do not delete the legacy copies until the counts and first startup
have been checked.

Compose runs an idempotent `data-init` job before FTP, sorting, or Frame.io
intake starts. On the first run for a configured `PUID:PGID`, it changes
ownership and mode on existing directories under `incoming/`, `sorted/`, and
`quarantine/`—not the photo/video files—then records a private state marker.
The marker includes the mounted data root's identity, so switching volumes or
bind trees runs the migration for that storage too. This lets the new non-root
sorter keep using date/type directories created by older root-run deployments.
`CAMERA_DATA_SOURCE`
selects the same named volume or bind mount for the initializer and every
writer, so they cannot silently point at different storage. For a bind mount,
set `PUID`/`PGID` to the numeric owner you want on the host.
It also prepares separate private volumes for sorter control state and Frame.io
OAuth/reconciliation state, including safe ownership after a `PUID` change.

## Tests

The concurrency suite runs inside the sorter image so it uses the same Bash,
filesystem tools, and inotify implementation as production:

```bash
docker build -t camera-sorter:test .
docker run --rm --entrypoint /bin/bash \
  -e SORTER_UNDER_TEST=/sort.sh \
  -v "$PWD:/work:ro" camera-sorter:test /work/tests/parallel-sort.sh

# Root-only Unraid helper regressions (protected state, backup status, and
# narrowly scoped permission repair):
TEST_IMAGE=camera-sorter:test tests/unraid-healthcheck.sh
TEST_IMAGE=camera-sorter:test tests/unraid-backup.sh
TEST_IMAGE=camera-sorter:test tests/unraid-fixperms.sh

# Frame.io durability, webhook, pagination, path-race, and cleanup regressions.
# Mount only the tests so /app remains the exact code baked into the image:
docker build -t camera-frameio:test frameio-mirror
test "$(docker run --rm --entrypoint sha256sum camera-frameio:test /app/app.py | awk '{print $1}')" \
  = "$(sha256sum frameio-mirror/app.py | awk '{print $1}')"
docker run --rm --user 99:100 -e PYTHONPATH=/app \
  -v "$PWD/frameio-mirror/tests:/tests:ro" \
  --entrypoint python camera-frameio:test -m unittest discover -s /tests -v
```

## Optional: Unraid-Specific Notes

**Run every data writer as `99:100` so files are deletable over SMB.** Compose does this by default: it maps the pure-ftpd virtual user, sorter, and Frame.io mirror to Unraid's `nobody:users`, and its initializer prepares both volumes with the matching ownership. If a container runs as root, every `<date>/<type>/` directory it creates is owned `root:root`, and an SMB client (a non-root user) can't delete files inside a directory it can't write to. That holds even when the files themselves are yours, because POSIX checks the parent directory's write permission, not the file's. The sorter image itself also defaults to `99:100`, and `umask 002` makes output `775`/`664`, deletable by any Unraid SMB user (they're all in the `users` group).

For a bare `docker run`, create the shared data and control directories once
(Compose users do not need this manual step), then mount them into every sorter
instance:

```bash
mkdir -p /mnt/user/your-share/incoming \
  /mnt/user/your-share/sorted \
  /mnt/user/your-share/quarantine \
  /mnt/cache/appdata/camera-sorter/state
chown 99:100 /mnt/user/your-share \
  /mnt/user/your-share/incoming \
  /mnt/user/your-share/sorted \
  /mnt/user/your-share/quarantine \
  /mnt/cache/appdata/camera-sorter/state
chmod 0775 /mnt/user/your-share \
  /mnt/user/your-share/incoming \
  /mnt/user/your-share/sorted \
  /mnt/user/your-share/quarantine
chmod 0700 /mnt/cache/appdata/camera-sorter/state

docker run -d --name camera-sorter --user 99:100 \
  -v /mnt/user/your-share:/data \
  -v /mnt/cache/appdata/camera-sorter/state:/var/lib/camera-sorter \
  -v /mnt/user/appdata/camera-sorter/telegram.json:/etc/telegram.json:ro \
  --restart unless-stopped camera-sorter
```

Mounted config files (`telegram.json`, `frameio.json`, `oauth-state.json`) need
to be owned by the configured `PUID:PGID` (`99:100` by default) so the non-root
containers can read them. The OAuth state file is writable: create it with
`printf '{}\n' > oauth-state.json`, then run `chown 99:100 oauth-state.json`
and `chmod 0600 oauth-state.json` before mounting it. If you already have a
camera tree owned by `root:root`, fix it once with
the Compose `data-init` migration, or change directory ownership only; avoid a
recursive file-wide `chown`. The sorter needs writable/traversable directories,
while original media ownership can remain untouched.

If you install `contrib/unraid/ftpdropbox-fixperms.sh`, its defaults also target
`99:100`. A deployment using different Compose `PUID`/`PGID` values must export
matching `SORTER_UID`/`SORTER_GID` values in the cron command so the repair job
does not hand incoming files to the wrong account.

The healthcheck accepts either the Compose FTP name (`camera-ftp`) or the
legacy Unraid name (`pure-ftpd`). Frame.io is optional by default; set
`REQUIRE_FRAMEIO=1` in its cron command only when that mirror must be present.
The backup and health scripts keep their stamps and alert state in the
root-only `/var/lib/ftpdropbox-health/` directory.

**Hostname instead of raw IP:** add an mDNS alias in `/boot/config/go`:

```bash
nohup /usr/bin/avahi-publish -a -R ftp.local <container-ip> </dev/null >/dev/null 2>&1 &
```

After a reboot, `ftp.local` resolves on your LAN. Set that as the server address in the camera menu.

## License

MIT
