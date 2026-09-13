# Stack

- **Sorter** (`sort.sh`, ~2,100 lines): Bash 5 on `alpine:3.24.1` with `inotify-tools`, `exiftool`, `coreutils`, `findutils`, `curl`, `jq`, `util-linux` (`flock`), `libraw-tools` (`raw-identify`, `simple_dcraw`). Runs as 99:100. Built by the root `Dockerfile`.
- **Panel** (`panel/app.py`, ~1,100 lines; `panel/index.html`): Python 3.12 on `python:3.12-alpine`, FastAPI 0.115, uvicorn 0.30, Pillow 10, `exiftool` via `subprocess`. Single process, no database, filesystem is the source of truth. Port 8484.
- **Frame.io mirror** (`frameio-mirror/app.py`, ~3,900 lines): Python 3.12, FastAPI, `httpx`, uvicorn. Webhook receiver plus reconcile loop; private staging mount; durable JSON state file.
- **FTP** (`pure-ftpd/`): vendored fork of pure-ftpd 1.0.50 with two patches (never publish aborted uploads; docker capabilities). `ADDED_FLAGS=-d -d -0`.
- **Ops scripts** (`contrib/unraid/*.sh`): Bash, run by root cron on Unraid; Telegram via `curl`; state under `/var/lib/ftpdropbox-health/` (root 0700).
- **Tests**: `tests/parallel-sort.sh` (Bash harness, 48 cases, Linux-only, runs inside the sorter image); `tests/unraid-*.sh` (Bash, inside the sorter image, stub `docker`/`curl` in `tests/fixtures/`); `frameio-mirror/tests/` (pytest, 57 tests); `tests/panel-static.sh` (node + python static contract check); `tests/pure-ftpd-abort.py` (live FTP abort probe, run from a LAN client).
- **Docker Compose** (`docker-compose.yml`) is the public install path; the production box uses CLI-created containers instead.
