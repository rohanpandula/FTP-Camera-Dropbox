<!-- GSD:project-start source:PROJECT.md -->

## Project

**FTP Camera Dropbox — 2026-09 Hardening**

A self-hosted camera intake pipeline: cameras push over Wi-Fi FTP (and Frame.io Camera-to-Cloud) to an Unraid box, a Bash sorter validates each file and files it by capture date, and a LAN web panel shows status. This milestone fixes the bugs and blind spots found in the 2026-09-01 review of the live deployment (tower, 10.0.0.100).

**Core Value:** Every file a camera sends either lands intact in `sorted/` or the operator is told exactly which file did not. Silent loss is the one failure this system must never have.

### Constraints

- **Tech stack**: Bash 5 (`sort.sh`, `contrib/unraid/*.sh`), Python 3.12 FastAPI (`panel/`, `frameio-mirror/`). No new dependencies; stdlib first.
- **Safety**: Agents never stop, remove, rename, or recreate production containers on tower, never edit `/boot/config/plugins/` (the healthcheck under `/boot/config/scripts/` is installed only through Phase 4's human-gated step), never read secrets (`frameio.json`, `telegram.json`, `state.json`). Deployment is a human-gated phase run with `--interactive`.
- **Compatibility**: `sort.sh` keeps passing all existing harness cases; frameio keeps 57 passing; healthcheck fixture suite keeps passing. Validators stay strict except the one specified tolerance.
- **Style**: shortest diff that fixes the root cause; comments explain why; no new abstractions; mark deliberate ceilings with `# ponytail:`.
- **Data**: the library on tower is the user's live working set (Lightroom sidecars beside RAWs). Never move or delete anything under `sorted/`.

<!-- GSD:project-end -->

<!-- GSD:stack-start source:codebase/STACK.md -->

## Technology Stack

- **Sorter** (`sort.sh`, ~2,100 lines): Bash 5 on `alpine:3.24.1` with `inotify-tools`, `exiftool`, `coreutils`, `findutils`, `curl`, `jq`, `util-linux` (`flock`), `libraw-tools` (`raw-identify`, `simple_dcraw`). Runs as 99:100. Built by the root `Dockerfile`.
- **Panel** (`panel/app.py`, ~1,100 lines; `panel/index.html`): Python 3.12 on `python:3.12-alpine`, FastAPI 0.115, uvicorn 0.30, Pillow 10, `exiftool` via `subprocess`. Single process, no database, filesystem is the source of truth. Port 8484.
- **Frame.io mirror** (`frameio-mirror/app.py`, ~3,900 lines): Python 3.12, FastAPI, `httpx`, uvicorn. Webhook receiver plus reconcile loop; private staging mount; durable JSON state file.
- **FTP** (`pure-ftpd/`): vendored fork of pure-ftpd 1.0.50 with two patches (never publish aborted uploads; docker capabilities). `ADDED_FLAGS=-d -d -0`.
- **Ops scripts** (`contrib/unraid/*.sh`): Bash, run by root cron on Unraid; Telegram via `curl`; state under `/var/lib/ftpdropbox-health/` (root 0700).
- **Tests**: `tests/parallel-sort.sh` (Bash harness, 48 cases, Linux-only, runs inside the sorter image); `tests/unraid-*.sh` (Bash, inside the sorter image, stub `docker`/`curl` in `tests/fixtures/`); `frameio-mirror/tests/` (pytest, 57 tests); `tests/panel-static.sh` (node + python static contract check); `tests/pure-ftpd-abort.py` (live FTP abort probe, run from a LAN client).
- **Docker Compose** (`docker-compose.yml`) is the public install path; the production box uses CLI-created containers instead.

<!-- GSD:stack-end -->

<!-- GSD:conventions-start source:CONVENTIONS.md -->

## Conventions

## Bash (`sort.sh`, `contrib/unraid/*.sh`)

- `set -u`; every external string passes through `sanitize`/`log_value` before it reaches a log line or Telegram; `log` is the only output function.
- Paths are security boundaries: pin directories with `exec {fd}<dir`, operate through `/proc/$BASHPID/fd/N`, recheck `stat -c '%d:%i'` after every rename. Match the style of `move_with_suffix` when touching moves.
- Validators return 0 (accept), 1 (quarantine), or 75 (source changed, retry later). Keep that contract.
- Comments explain *why* (the observed failure that motivated the code), not what. A deliberate ceiling gets a `# ponytail:` note naming the upgrade path.
- Config knobs are `NAME="${NAME:-default}"` at the top and validated in the numeric loop; document new ones in the README table.
- Log line vocabulary is load-bearing for the harness and the healthcheck: `ok:`, `QUARANTINE:`, `DUPLICATE:`, `STUCK >Nmin:`, `skip unstable:`, `FAIL`, `validate:`. Keep prefixes stable.

## Python (`panel/app.py`, `frameio-mirror/app.py`)

- Stdlib first; the only third-party imports are FastAPI/Starlette, httpx (mirror), Pillow (panel). Do not add packages.
- Atomic writes: `tempfile.mkstemp` in the target dir → write → `fsync` → `os.replace`. Never `open(path, "w")` on shared state.
- Never log secrets or pre-signed URLs; log exceptions as `%s: %r` with `type(exc).__name__` so empty-message exceptions stay diagnosable.
- Path inputs from HTTP go through `safe_child` (panel) or the pinned-fd helpers (mirror). Reject, do not normalize.
- The panel's JSON API contract is consumed by `index.html` and checked by `tests/panel-static.sh`; keep field names stable and add, never rename.

## Tests

- Sorter and ops changes ship with a harness case in the same commit (`tests/parallel-sort.sh` or `tests/unraid-*.sh`), written as `PASS:`-printing blocks using the existing helpers (`wait_for_log`, `assert_log_absent_for`, fixture writers such as `write_valid_heif`).
- Mirror changes ship with a pytest in `frameio-mirror/tests/`; panel changes with a pytest in `panel/tests/` (new in this milestone) using `fastapi.testclient.TestClient` and `DATA_ROOT` pointing at a temp dir.
- Harnesses that need Linux run inside the sorter image (`docker build -t camera-sorter:test .`), never on the host shell.

## Git

- Commit subject: `<area>: <imperative summary>` where area is `sort.sh`, `panel`, `frameio-mirror`, `healthcheck`, `tests`, `docs`; body states the observed failure and the evidence.
- One logical change per commit; tests in the same commit as the code they cover.
- Never commit `.impeccable/`, `data/`, `*.failed.*`, or any credential file.

<!-- GSD:conventions-end -->

<!-- GSD:architecture-start source:ARCHITECTURE.md -->

## Architecture

## Data flow

```

```

## Directories on the data mount (`/data` = `/mnt/nvmenetworkstorage/FTPDropbox`)

## Trust boundaries (why the code is shaped the way it is)

- `/data` is SMB-writable by LAN clients: every sorter move pins the source directory and output directory by file descriptor, rechecks inode identity, and never clobbers. Do not "simplify" these paths.
- The panel has no auth (LAN trust) but a Host allowlist and an Origin check on writes; it has no docker socket and must not gain one.
- The mirror's webhook is internet-facing: HMAC signature and timestamp window are mandatory; the OAuth setup endpoint is gated by a header secret.
- The healthcheck state dir is root 0700 and the script enforces it; the panel therefore derives health from what it can see.

## Processes on tower

<!-- GSD:architecture-end -->

<!-- GSD:skills-start source:skills/ -->

## Project Skills

No project skills found. Add skills to any of: `.claude/skills/`, `.agents/skills/`, `.cursor/skills/`, `.github/skills/`, or `.codex/skills/` with a `SKILL.md` index file.
<!-- GSD:skills-end -->

<!-- GSD:workflow-start source:GSD defaults -->

## GSD Workflow Enforcement

Before using Edit, Write, or other file-changing tools, start work through a GSD command so planning artifacts and execution context stay in sync.

Use these entry points:

- `/gsd:quick` for small fixes, doc updates, and ad-hoc tasks
- `/gsd:debug` for investigation and bug fixing
- `/gsd:execute-phase` for planned phase work

Do not make direct repo edits outside a GSD workflow unless the user explicitly asks to bypass it.
<!-- GSD:workflow-end -->

<!-- GSD:profile-start -->

## Developer Profile

> Profile not yet configured. Run `/gsd:profile-user` to generate your developer profile.
> This section is managed by `generate-claude-profile` -- do not edit manually.
<!-- GSD:profile-end -->
