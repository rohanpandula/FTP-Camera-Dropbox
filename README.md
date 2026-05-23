# FTP Camera Dropbox

A self-hosted FTP server and auto-organizer for digital cameras. Point your Fuji, Sony, or Nikon at it over Wi-Fi and it sorts RAWs, JPEGs, and videos into `<date>/<type>/` folders. It also validates files, deduplicates, quarantines bad uploads, and can batch Telegram notifications every 5 minutes.

## Why

Most modern cameras (Fuji X-series, Sony Alpha, Nikon Z) can upload over Wi-Fi via FTP. It's a protocol they speak natively: no app, no USB, no card reader. The gap is on the receiving end. Lightroom's auto-import means buying Lightroom, the vendor apps are bloated and flaky, and cloud transfer ships your RAFs off to someone else's server.

This is a Lightroom-style auto-import folder that runs on your own hardware, with nothing to install beyond Docker.

## Features

- Auto-sorts by EXIF `DateTimeOriginal` → `YYYY-MM-DD/raw|jpg|video/filename`
- Falls back to file mtime when the EXIF date is missing or suspicious
- Content validation: RAW size floor, JPEG SOI/EOI byte checks, video readability
- Deduplication via xxhash, but only on filename collision, so unique files cost nothing
- Quarantine folder for files that fail validation (truncated uploads, corrupted transfers)
- Handles camera retry storms: `wait_stable` holds until the file size is unchanged for 60 seconds
- Optional Telegram notifications, batched per 5-minute window instead of one ping per file
- Reconcile scan every 5 minutes catches anything inotify missed
- Stuck-file detection flags uploads that have been sitting in incoming too long
- Offline-capable: the sorter needs no inbound network, only outbound for Telegram
- **Optional Frame.io C2C mirror.** Receives webhooks from Frame.io, downloads and size-verifies assets via the V4 API, deletes them upstream, and drops them into the same `incoming/` directory the sorter watches. FTP and Frame.io uploads end up in one library. Works with both Enterprise Adobe accounts (S2S OAuth) and personal ones (OAuth Web App + persisted refresh token). See [frameio-mirror/README.md](frameio-mirror/README.md).

## Quickstart

```bash
cp .env.example .env
# Edit PUBLICHOST to your host machine's LAN IP
nano .env

docker compose up -d

# Logs from the sorter
docker logs -f camera-sorter
```

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
| `PUBLICHOST` | `127.0.0.1` | IP advertised to clients in PASV mode. Set this to your host LAN IP. |
| `STABLE_WAIT` | `60` | Seconds to wait for a *fresh* file's size to stabilize before processing. Files whose mtime is already older than this (backlog drain, finished uploads) skip the wait. |
| `NOTIFY_INTERVAL` | `300` | How often to flush the Telegram notification queue (seconds) |
| `INCOMING` | `/data/incoming` | Directory FTP drops files into |
| `SORTED` | `/data/sorted` | Destination for successfully sorted files |
| `QUARANTINE` | `/data/quarantine` | Destination for files that fail validation |
| `RECONCILE_IDLE` | `300` | Run a full reconcile scan after this many seconds of inotify silence |
| `STUCK_AGE_MIN` | `60` | Log a warning for files that have been sitting in incoming this long (minutes) |
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

If you shoot with a body or phone paired to [Frame.io Camera-to-Cloud](https://frame.io/c2c), there's an opt-in second intake path. The mirror receives Frame.io V4 webhooks, downloads each asset via the API, size-verifies it, and drops it into the same `incoming/` directory the sorter watches. FTP and C2C uploads land in the same date-sorted library.

It also deletes each asset from Frame.io after a verified download, so the 2 GB free-tier quota stays empty.

Off by default. To bring it up:

```bash
docker compose --profile frameio up -d --build
curl http://localhost:8000/health
```

You'll need a public HTTPS endpoint pointing at `:8000` so Frame.io can POST webhooks. Cloudflare Tunnel, ngrok, or any reverse proxy with Let's Encrypt all work.

**Two auth modes:**

- **OAuth Server-to-Server**, for Enterprise Adobe organizations. Headless: add the credential in Dev Console, paste the `client_id` and `client_secret`, done.
- **OAuth Web App + refresh token**, for personal Adobe accounts (Adobe doesn't offer S2S to these). Sign in once in a browser via `/oauth/start` and it's permanent. The refresh token is saved to disk, and the mirror mints 1-hour access tokens from it on its own.

**Failure alerts** (also optional): mount the same `telegram.json` the sorter uses at `/etc/telegram.json` and the mirror sends throttled ⚠️ pings on real failures: Frame.io API errors, size mismatches, missing Adobe credentials. Throttling is per-kind and in-memory, so a stuck state can't spam you. The success path stays silent; the sorter handles "files landed" through its own batched queue.

Full setup (Frame.io webhook config, the click-by-click Adobe Dev Console walkthrough for both auth modes, env vars, alert behavior, endpoints) is in [frameio-mirror/README.md](frameio-mirror/README.md).

## Hard-Earned Gotchas

These are the things that cost real time to figure out.

**Cameras default to SFTP (port 22), not FTP (port 21).** This is the number one silent failure mode. pure-ftpd doesn't speak SSH; it sends RST to anything on port 22. The camera's symptom is a generic "connection failed" with no useful error. The network symptom (via tcpdump) is a clean TCP SYN to `:22`, an immediate RST from the server, then the camera retrying forever. The fix is one menu item: set `Server Type = FTP` (or `Protocol = FTP`), not `SFTP`. Some firmware calls it "secure" vs "not secure". You want not secure.

**Wi-Fi band makes an enormous difference. 2.4 GHz vs 5 GHz is not a "nice to have."** Numbers from real testing, same Fuji body, same room: 2.4 GHz at full bars was about 22 KB/s. 5 GHz from far across the house was about 80 KB/s. 5 GHz close to the access point was 600–1500 KB/s. A 100 MB RAF file takes 80 minutes on 2.4 GHz and roughly 1 minute on 5 GHz. It's not even close. Most Fuji X-bodies are 2.4 GHz only (X-T4 and earlier, the X-S series); the X-T5, X-H2, X-H2S, and GFX 100 II added 5 GHz. Signal strength matters too: a body in the same room as the AP beats one with "full bars" on a distant 2.4 GHz radio by 10×.

**`wait_stable` needs to be ~60 seconds, not 2 seconds.** The obvious implementation is to wait until the file stops growing, then process it, and the obvious choice for "wait" is 2 seconds. That's wrong on flaky links. Cameras retry uploads on failure, and during a retry the file in `incoming/` can go quiet for several seconds while the camera reconnects and resumes. A 2-second check declares a partial file "stable" mid-retry and sorts a truncated image. 60 seconds outlasts the camera's retry intervals without being annoying, and validation catches anything that still slips through. (Files already older than `STABLE_WAIT` skip the wait, so draining a backlog doesn't crawl.)

**A custom Alpine image beats fighting stilliard/pure-ftpd's anonymous mode.** Anonymous FTP (no username/password) is what you'd want ideally, so it's what I tried first. The stilliard/pure-ftpd image's anonymous mode has papercuts with Fuji firmware: some bodies insist on sending credentials even in "anonymous" mode, and the mismatch fails silently. A trivial `cameras`/`cameras` virtual user sidesteps all of it, and every camera firmware I tested accepts it. On a LAN with no internet exposure it's effectively zero-auth anyway.

**macvlan / br0 host-isolation is a red herring on Unraid.** If you assign each container a dedicated IP on br0, the Unraid host itself can't ping or connect to its own containers (`Destination Host Unreachable`). That's a Linux kernel rule about macvlan interfaces, not a bug in your FTP setup: the host and its macvlan children can't talk directly. Other devices on your LAN (including cameras) reach the containers fine. I spent a while convinced the FTP server was broken when it was just the host's network view that was isolated.

**Dedup is hash-on-collision, not hash-everything.** The naive approach hashes every incoming file against every existing file, which gets expensive on a large library. Instead, a filename collision triggers a size check. Different sizes means a different file, so rename and keep it. Same size triggers an xxhash of both, and an exact duplicate deletes the incoming copy. Uploading a unique file (the common case) costs zero hashing; a retry of an already-sorted file costs one hash compare (~50 ms for a RAF). The library can grow without the dedup step slowing down.

### Frame.io mirror gotchas

**Frame.io V4 webhook payloads contain just `resource.id`. Everything else needs an authenticated API call.** No filename, no size, no pre-signed URL. The "maybe we can skip Adobe Dev Console" idea sounds reasonable until you read [the docs](https://developer.adobe.com/frameio/api/current/guides/webhooks/) literally: *"We do not include any additional information beyond the resource ID."* The flow is webhook arrives, call `GET /v4/accounts/{account_id}/files/{file_id}?include=media_links.original`, stream the URL it returns, then `DELETE` the file. There's no shortcut.

**Frame.io V4 signs `v0:<timestamp>:<body>`, not the body alone.** It's a Stripe-style scheme with two headers: `X-Frameio-Signature` (formatted `v0=<hex>`) and `X-Frameio-Request-Timestamp` (Unix epoch). It's HMAC-SHA256 with the secret encoded as latin-1. A naive `HMAC(secret, body)` returns 403 forever. Check the timestamp drift too, to block replays (5 minutes is sane).

**Adobe Server-to-Server OAuth is Enterprise-only.** Personal Adobe accounts only see `OAuth Web App`, `Single Page App`, and `Native App` in the Developer Console; there's no S2S option. For headless use from a personal account, run the OAuth Web App flow once in a browser to capture a `refresh_token`, persist it, then mint access tokens from the refresh grant. Adobe IMS refresh tokens don't expire unless they sit idle for months. The mirror's `/oauth/start` and `/oauth/callback` endpoints handle this in a single browser visit.

**Web App access tokens last 1 hour (S2S tokens last 24).** The mirror caches the token and refreshes it within 5 minutes of expiry, so you won't notice. But if you fork the auth flow, build the refresh in or you'll hit 401s at the worst time.

**Docker single-file bind mounts can't be atomic-renamed.** Mount a single file (not its parent directory) into a container and the kernel pins the destination inode, so `os.replace(tmp, dest)` raises `EBUSY`. You can write the file in place, but you can't rename other files over it. The mirror writes its `oauth-state.json` in place for this reason; losing atomicity is fine for a tiny single-value write. Mount the parent directory if you need atomic semantics.

**Your "free" static IP isn't guaranteed free.** Checking what's currently assigned to other containers before picking a br0 macvlan IP is necessary but not sufficient. If the IP is inside your DHCP pool, the router can hand it to an iPhone or Mac while your container runs, and you get a silent split-brain: ICMP succeeds (the other device answers) but TCP fails (nothing's listening on its port). Reserve the IP on the DHCP server, or pick one outside the dynamic range.

## How It Works

```
Camera (Wi-Fi FTP)
       |
       v
  pure-ftpd (:21)
       |  writes to
       v
  /data/incoming/          <-- shared Docker volume
       |
       |  inotifywait (close_write, moved_to)
       v
  camera-sorter
    wait_stable()          -- wait 60s for file size to stop changing
    get_type()             -- by extension
    get_date()             -- EXIF DateTimeOriginal, fallback to mtime
    validate_file()        -- size floors, JPEG byte checks, exif readability
    move_with_suffix()     -- dedup check, then mv
       |
       |-- ok     --> /data/sorted/YYYY-MM-DD/{raw,jpg,video}/filename
       |-- bad    --> /data/quarantine/YYYY-MM-DD/filename
       |-- dup    --> deleted (incoming), original left in place
       |
       v
  enqueue_notify()         -- append to .notify-queue.tsv
  notifier_loop()          -- flush queue to Telegram every 5 min
```

Every `RECONCILE_IDLE` seconds of inotify silence, a full directory scan runs to catch anything that was missed (power cycling, container restarts, and so on).

## Optional: Unraid-Specific Notes

**Run the sorter (and Frame.io mirror) as `99:100` so files are deletable over SMB.** If the containers run as root, every `<date>/<type>/` directory they create is owned `root:root`, and an SMB client (a non-root user) can't delete files inside a directory it can't write to. That holds even when the files themselves are yours, because POSIX checks the parent directory's write permission, not the file's. Add `--user 99:100` (Unraid's `nobody:users`) to the `docker run`. The images set `umask 002`, so output lands `nobody:users` `775`/`664`, deletable by any Unraid SMB user (they're all in the `users` group):

```bash
docker run -d --name camera-sorter --user 99:100 \
  -v /mnt/user/your-share:/data \
  -v /mnt/user/appdata/camera-sorter/telegram.json:/etc/telegram.json:ro \
  --restart unless-stopped camera-sorter
```

Mounted config files (`telegram.json`, `frameio.json`, `oauth-state.json`) need to be `chown 99:100` so the non-root container can read them. If you already have a tree owned by `root:root`, fix it once: `chown -R 99:100 /mnt/user/your-share`.

**Hostname instead of raw IP:** add an mDNS alias in `/boot/config/go`:

```bash
nohup /usr/bin/avahi-publish -a -R ftp.local <container-ip> </dev/null >/dev/null 2>&1 &
```

After a reboot, `ftp.local` resolves on your LAN. Set that as the server address in the camera menu.

## License

MIT
