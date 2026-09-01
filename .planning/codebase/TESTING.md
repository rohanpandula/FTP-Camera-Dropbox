# Testing

## Where each suite runs

| Suite | Command | Runs where |
|-------|---------|------------|
| Sorter harness (48 cases, ~10 min) | `docker build -t camera-sorter:test . && docker run --rm --entrypoint /bin/bash -e SORTER_UNDER_TEST=/sort.sh -v "$PWD:/work:ro" camera-sorter:test /work/tests/parallel-sort.sh` | Linux container only. No colima instance exists on this Mac; use `tests/run-on-tower.sh parallel-sort` which builds and runs a throwaway `--rm` container on tower and cleans up |
| Healthcheck / backup / fixperms | `TEST_IMAGE=camera-sorter:test tests/unraid-healthcheck.sh` (same for `unraid-backup.sh`, `unraid-fixperms.sh`) | Linux container (script re-execs itself inside the image as root); via `tests/run-on-tower.sh unraid-healthcheck` |
| Frame.io mirror | `cd frameio-mirror && python3 -m pytest -q` | Local; no `TMPDIR` override needed — tests resolve temp dirs with `os.path.realpath` |
| Panel static contract | `tests/panel-static.sh` | Local (needs `node`) |
| Panel pytest (new) | `cd panel && python3 -m pytest -q` | Local (needs `fastapi`, `pillow`; `pip install "fastapi==0.115.*" "pillow==10.*" httpx` in a venv if missing) |
| Live FTP abort probe | `python3 tests/pure-ftpd-abort.py ftp://cameras:cameras@10.0.0.101/` | From the Mac on the LAN (never from tower: macvlan) |

## Harness idioms (`tests/parallel-sort.sh`)

- Each case: prepare `$TEST_ROOT/data/incoming/...`, start the sorter with `STABLE_WAIT=1 RECONCILE_IDLE=...`, then `wait_for_log`, `wait_for_count`, `assert_log_absent_for`, and `find` on `sorted/`/`quarantine/`; print `PASS: <sentence>`; `fail "<reason>"` on any miss.
- Fixture writers build minimal ISO-BMFF files with `printf` (`write_valid_heif`, `write_truncated_heif`, lines 40–62). Add siblings next to them.
- `RECONCILE_IDLE` and `STUCK_AGE_MIN` are per-case env; the harness scales timeouts with `TEST_TIMEOUT_SCALE`.
- ctime cannot be set backwards; a positive "old ctime is flagged" case needs `STUCK_AGE_MIN=1` and a real wait. The mandatory case is the negative one: old mtime, fresh ctime, no `STUCK` line.

## Healthcheck harness (`tests/unraid-healthcheck.sh`)

- `run_check` runs the real script with `PATH="$FIXTURES:$PATH"`, so `docker` and `curl` resolve to `tests/fixtures/healthcheck/{docker,curl}`. The docker stub answers `info`, `inspect`, `start`, `exec` and exits 64 for anything else; add a `logs` branch driven by env (for example `FAKE_FTP_LOG_FILE`) before testing an abort alert.
- Telegram sends are asserted through `FAKE_CURL_LOG`; state files live under `$CASE_DIR/state`.

## Remote tower testing (tests/run-on-tower.sh)

Interface: `tests/run-on-tower.sh <parallel-sort|unraid-healthcheck|unraid-backup|unraid-fixperms>`.
Env: `TOWER` (default `root@10.0.0.100`), `TOWER_TMP` (default `/tmp`, validated against
`^/[A-Za-z0-9._/-]*$` before use). Requires passwordless `ssh -o BatchMode=yes` to tower plus
`rsync` and `docker` present there.

It rsyncs the current working tree (uncommitted changes included) to a throwaway
`$TOWER_TMP/gsd-test-<id>/` directory, excluding `.git`, `.planning`, `.impeccable`,
`__pycache__`, `.pytest_cache`, `.ruff_cache`, and `.venv*`; builds a throwaway
`gsd-test-<id>` image from it; runs the named harness in a `--rm` container; and always
removes both the directory and the image via an EXIT trap, pass or fail. The exit status
is the harness's, and the last line printed is `PASS <harness>` or `FAIL <harness> (rc=N)`.

It never names a production container or a host storage path — only `docker build`,
`docker run --rm`, and `docker rmi` of the `gsd-test-` tag are permitted.
