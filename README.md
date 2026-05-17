# FTP Camera Dropbox

A self-hosted FTP server + auto-organizer for digital cameras. Point your Fuji, Sony, or Nikon at it over Wi-Fi and it sorts everything into `<date>/<type>/` automatically — RAWs, JPEGs, and videos — with content validation, deduplication, quarantine for bad files, and optional Telegram notifications that batch-aggregate uploads every 5 minutes.

## Why

Most modern cameras (Fuji X-series, Sony Alpha, Nikon Z) have built-in FTP upload over Wi-Fi. It's a native protocol they speak well — no app, no USB, no card reader. The problem is there's no good lightweight receiver. Lightroom's "auto-import" requires you to buy Lightroom. Camera vendor apps are bloated and unreliable. Cloud transfer solutions send your RAFs to someone else's server.

This gives you a Lightroom-style auto-import folder structure, running on your own hardware, with no dependencies beyond Docker.

## Features

- Auto-sorts by EXIF `DateTimeOriginal` → `YYYY-MM-DD/raw|jpg|video/filename`
- Falls back to file mtime when EXIF date is missing or suspicious
- Content validation: RAW size floor, JPEG SOI/EOI byte checks, video readability
- Deduplication via xxhash — but only on filename collision, so unique files have zero overhead
- Quarantine folder for files that fail validation (bad truncated uploads, corrupted transfers)
- Handles camera retry storms: `wait_stable` holds until the file size is unchanged for 60 seconds
- Optional Telegram notifications, aggregated per 5-minute window (not one ping per file)
- Reconcile scan every 5 minutes catches anything inotify missed
- Stuck-file detection flags uploads that have been sitting in incoming for too long
- Entirely offline-capable: sorter needs no inbound network, only outbound for Telegram

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

Or switch to a bind mount — see the comments in `docker-compose.yml`.

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
| **Nikon** | Menu → Network → Connect to FTP server → Options → Server |

## Configuration

All settings have sensible defaults. Override via `.env` or environment variables in `docker-compose.yml`:

| Variable | Default | Description |
|---|---|---|
| `FTP_USER` | `cameras` | FTP username |
| `FTP_PASS` | `cameras` | FTP password |
| `PUBLICHOST` | `127.0.0.1` | IP advertised to clients in PASV mode — **set this to your host LAN IP** |
| `STABLE_WAIT` | `60` | Seconds to wait for file size to stabilize before processing |
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

If the config file is absent, the sorter starts normally and just skips notifications. No crashes, no retries.

## Hard-Earned Gotchas

These are the things that cost real time to figure out.

**Cameras default to SFTP (port 22), not FTP (port 21).** This is the number one silent failure mode. pure-ftpd doesn't speak SSH — it sends RST to anything on port 22. The camera's symptom is a generic "connection failed" with no useful error. The network symptom (via tcpdump) is a clean TCP SYN to `:22`, an immediate RST from the server, and then the camera retrying forever. The fix is one menu item: set `Server Type = FTP` (or `Protocol = FTP`), not `SFTP`. Some firmware calls it "secure" vs "not secure" — you want not secure.

**Wi-Fi band makes an enormous difference. 2.4 GHz vs 5 GHz is not a "nice to have."** Numbers from real testing, same Fuji body, same room: 2.4 GHz at full bars was about 22 KB/s. 5 GHz from far across the house was about 80 KB/s. 5 GHz close to the access point was 600–1500 KB/s. A 100 MB RAF file: 80 minutes on 2.4 GHz, roughly 1 minute on 5 GHz. It's not even close. Most Fuji X-bodies are 2.4 GHz only — X-T4 and earlier, X-S series. The X-T5, X-H2, X-H2S, and GFX 100 II added 5 GHz. Signal strength also dominates — a body in the same room as the AP beats a body with "full bars" on a distant 2.4 GHz radio by 10×.

**`wait_stable` needs to be ~60 seconds, not 2 seconds.** The obvious implementation is: wait until the file stops growing, then process it. The obvious choice for "wait" is 2 seconds. This is wrong on flaky links. Cameras retry uploads on failure. During a retry sequence, the file in `incoming/` can go quiet for several seconds between attempts while the camera reconnects and resumes. A 2-second stability check will declare a partial file "stable" mid-retry and sort a truncated image. 60 seconds is long enough to outlast the camera's retry intervals, short enough to not be annoying. The validation step catches anything that still slips through.

**Custom Alpine image is cleaner than trying to add users to stilliard/pure-ftpd for anonymous mode.** We tried anonymous FTP first (no username/password) because that's what you'd want ideally. The stilliard/pure-ftpd image's anonymous mode has papercuts with Fuji firmware — some bodies insist on sending credentials even in "anonymous" mode, and mismatches cause silent failures. The trivial `cameras`/`cameras` virtual user sidesteps all of this: every camera firmware we tested accepts it without complaint. On a LAN with no internet exposure, it's effectively zero-auth anyway.

**macvlan / br0 host-isolation is a red herring if you're on Unraid.** If you're running on Unraid and assigning each container a dedicated IP on br0, you'll notice the Unraid host itself can't ping or connect to its own containers (`Destination Host Unreachable`). This is a Linux kernel rule about macvlan interfaces — the host and its macvlan children can't communicate directly. It's not a bug in your FTP setup. Other devices on your LAN (including cameras) reach the containers just fine. We spent a while convinced the FTP server was broken when it was just the host's network view that was isolated.

**Dedup is hash-on-collision, not hash-everything.** The naive approach hashes every incoming file against every existing file — expensive on a large library. The approach here: filename collision triggers a size check. If sizes differ, it's a different file, rename and keep. If sizes match, *then* xxhash both files. Exact duplicate → delete incoming. This means uploading a unique file (the common case) costs zero hashing. A retry upload of an already-sorted file costs one hash comparison (~50ms for a RAF). The library can grow without the dedup step getting slower.

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

Every `RECONCILE_IDLE` seconds of inotify silence, a full directory scan runs to catch anything that was missed (power cycling, container restarts, etc.).

## Optional: Unraid-Specific Notes

If you want cameras to reach the FTP server by hostname instead of raw IP, add an mDNS alias. In `/boot/config/go`:

```bash
nohup /usr/bin/avahi-publish -a -R ftp.local <container-ip> </dev/null >/dev/null 2>&1 &
```

After reboot, `ftp.local` resolves on your LAN and you can set that as the server address in the camera menu.

## License

MIT
