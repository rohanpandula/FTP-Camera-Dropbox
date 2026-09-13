# Conventions

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
