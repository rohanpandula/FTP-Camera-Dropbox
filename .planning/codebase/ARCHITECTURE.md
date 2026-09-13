# Architecture

## Data flow

```
camera --FTP--> pure-ftpd (-0: .pureftpd-upload.* temp, rename on success) --> /data/incoming/
Frame.io C2C --webhook--> frameio-mirror --> private staging --> no-clobber handoff --> /data/incoming/
/data/incoming/ --inotify + 5-min reconcile--> sort.sh workers (4)
    wait_stable --> validate_file (raw/jpg/heif/video) --> exact_duplicate? --> move_with_suffix
    ok       --> /data/sorted/YYYY-MM-DD/{raw,jpg,heif,video}/  (+ NEF lens massage, nef-queue hard link)
    invalid  --> /data/quarantine/YYYY-MM-DD/
    re-send  --> /data/quarantine/_dupes/YYYY-MM-DD/ (pruned after 7 days)
panel (read-mostly) --> /api/status, /api/library, /api/quarantine, /api/config, /api/decisions
    writes only: /data/.panel/config.json (atomic), quarantine retry/trash/prune, lens decisions via exiftool
root cron --> healthcheck (containers, FTP listener, mirror /health, backup stamp) --> Telegram on state change
```

## Directories on the data mount (`/data` = `/mnt/nvmenetworkstorage/FTPDropbox`)

`incoming/`, `sorted/`, `quarantine/`, `quarantine/_dupes/`, `quarantine/_trash/`, `nef-queue/`, `.panel/` (config, thumbs, pending/resolved lens questions, cameras.json). Sorter locks and queues live on a separate private mount (`/var/lib/camera-sorter`), never on the SMB-exported tree.

## Trust boundaries (why the code is shaped the way it is)

- `/data` is SMB-writable by LAN clients: every sorter move pins the source directory and output directory by file descriptor, rechecks inode identity, and never clobbers. Do not "simplify" these paths.
- The panel has no auth (LAN trust) but a Host allowlist and an Origin check on writes; it has no docker socket and must not gain one.
- The mirror's webhook is internet-facing: HMAC signature and timestamp window are mandatory; the OAuth setup endpoint is gated by a header secret.
- The healthcheck state dir is root 0700 and the script enforces it; the panel therefore derives health from what it can see.

## Processes on tower

`camera-sorter` (sort.sh), `dropbox-panel` (uvicorn), `frameio-mirror` (uvicorn, br0 10.0.0.106), `pure-ftpd` (br0 10.0.0.101), plus cron scripts on the host. Previous container generations are kept stopped with a `-pre-<change>-<date>` suffix and `restart=no`.
