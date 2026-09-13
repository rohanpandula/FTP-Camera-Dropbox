# Phase 3: Observability and Panel Honesty - Context

**Gathered:** 2026-09-01
**Status:** Ready for planning
**Source:** Orchestrator decisions from the 2026-09-01 live-deployment review (every decision below is locked)

<domain>
## Phase Boundary

Three independent plans that touch disjoint files: (a) the root healthcheck cron alerts once per aborted FTP upload; (b) the panel reports arrival age from ctime and stops calling a name+size match "identical"; prune compares bytes before deleting; (c) the Frame.io mirror logs exception types. Each ships with tests. No change to `sort.sh`, `pure-ftpd/`, or deployment.

</domain>

<decisions>
## Implementation Decisions

### Plan A — FTP abort alert in `contrib/unraid/ftpdropbox-healthcheck.sh` (OBS-01)
- **D-01:** Add a probe block after the "FTP actually listening" probe, guarded by the same conditions (Docker up, `$ftp_container` resolved and running). It runs `docker_cmd logs --since "${ABORT_WINDOW:-15m}" "$ftp_container" 2>&1` and parses the pure-ftpd log. Production line shapes, verbatim:
  ```
  2026-08-31T11:00:41.202201-07:00 af0a0c2db5cb pure-ftpd: (cameras@SonyImagingDevice.localdomain) [NOTICE] /home/ftpusers/cameras//C0090.MP4 uploaded  (60889848 bytes, 65.32KB/sec)
  2026-08-31T11:00:41.213809-07:00 af0a0c2db5cb pure-ftpd: (cameras@SonyImagingDevice.localdomain) [DEBUG] 451-Timeout
  2026-08-31T11:00:41.213815-07:00 af0a0c2db5cb pure-ftpd: (cameras@SonyImagingDevice.localdomain) [DEBUG] 451-Transfer aborted
  ```
  A successful transfer logs the same NOTICE followed by `[DEBUG] 226-File successfully transferred`. An abort is a `451-Transfer aborted` line; its file is the nearest preceding `uploaded  (N bytes, X KB/sec)` NOTICE from the same `(user@host)` session. Note the double space before `(` and the `//` in the path; take the basename.
- **D-02:** Dedup with a fingerprint file `${STATE%/*}/ftp-aborts.seen` (same root 0700 dir as the state file, created 0600 via `umask 077`). Fingerprint = `sha256sum` of `<timestamp of the 451 line>|<basename>|<bytes>`. Skip aborts whose fingerprint is present; append new ones; keep only the last 500 lines. The window (15 minutes, three cron intervals) plus the fingerprint means a skipped run misses nothing and an overlap repeats nothing.
- **D-03:** Send one Telegram message per new abort, directly via `tg`, independent of the state-change mechanism (`$problems`/`commit_state` stay untouched; an abort is an event, not a persistent state). Exact wording:
  `⚠️ FTP upload aborted: C0090.MP4 — 60.9 MB received at 65 KB/s before pure-ftpd gave up (451). The file was not saved. Re-send it from the card.`
  Bytes rendered with one decimal in MB (`awk`), speed as the integer KB/s from the log line. If the NOTICE line cannot be paired, still alert with the 451 timestamp and "unknown file".
- **D-04:** If `docker logs` fails or `$ftp_container` is unresolved, do nothing (no problem line, no alert); the container probes already cover that failure mode. Never let this block change the script's exit status.
- **D-05:** Tests in `tests/unraid-healthcheck.sh` with the docker stub gaining a `logs)` branch that prints `${FAKE_FTP_LOG_FILE}` (or nothing when unset): case 1, a log with one abort sequence → exactly one curl call whose `text=` contains `C0090.MP4`, `60.9 MB`, and `65 KB/s`; case 2, the same log again with the same `$CASE_DIR/state` → no new curl call; case 3, a log with a `226` success only → no curl call; case 4, two aborts in one window → two messages. Existing cases must keep passing. Run with `tests/run-on-tower.sh unraid-healthcheck`.
- **D-06:** Update the script's header comment (what it alerts on) and the "Install" note that the file must be copied to `/boot/config/scripts/` (deployment happens in Phase 4).

### Plan B — Panel arrival age and byte-verified prune (OBS-02, PANEL-01)
- **D-07:** In `api_status`, `age_s` becomes `int(now - st.st_ctime)`; the derived-health branch keeps using `age_s` unchanged. Keep the JSON field name `age_s`. In `index.html`, wherever an incoming row renders that age, the copy says "arrived … ago" (grep for `age_s` and `age(`); if no copy names it, leave the HTML alone.
- **D-08:** `_library_name_sizes` stays as the cheap name→sizes index. `api_quarantine` keeps emitting `in_library` (same name and size exists) but the UI stops overclaiming: in `index.html` the badge text `Copy in library` becomes `Same name+size filed`, and the row detail `an identical copy is already filed` becomes `a same-size copy is filed; prune compares bytes before deleting`. The prune bar sentence becomes `{n} file(s) have a same-name, same-size copy filed in the library.` and the button stays `Prune verified copies` because prune now verifies.
- **D-09:** `prune_verified` compares bytes before deleting: for each quarantined regular file with a same-name, same-size library candidate, delete only if `filecmp.cmp(quar_path, candidate, shallow=False)` is true for at least one candidate. To find candidates, extend the cached index to map `name -> {size: [paths]}` (or add a parallel `name -> [paths]` map) inside `_library_name_sizes`; keep the 60-second cache. Response becomes `{"ok": true, "removed": n, "kept": m}` where `kept` counts same-size files whose bytes differed; the UI status line (grep `Pruned ${result.removed}`) mentions kept when it is nonzero, e.g. `Pruned 3 verified copies; kept 1 whose bytes differed`. Add a `# ponytail:` note that prune reads each candidate once and that a hash cache is the upgrade if quarantine ever holds hundreds of RAWs.
- **D-10:** New pytest suite `panel/tests/test_quarantine.py` (create `panel/tests/__init__.py` if needed). Set `os.environ["DATA_ROOT"]` to a temp dir BEFORE importing `app` (module-level constants read it). Do not rely on the startup hook; create `sorted/2026-01-01/raw/`, `quarantine/2026-01-01/`, and `.panel/` directly. Cases: (1) identical bytes → `prune_verified` removes the quarantined file and reports `removed == 1, kept == 0`; (2) same size, different bytes → file survives, `kept == 1`; (3) `GET /api/quarantine` marks both as `in_library` true (name+size hint); (4) `GET /api/status` for a file in `incoming/` whose mtime was set three hours back with `os.utime` reports `age_s < 60`. Use `fastapi.testclient.TestClient(app)` without the context manager; POST JSON to `/api/quarantine/action` (no Origin header is needed, the CSRF guard passes curl-style requests).
- **D-11:** Dependencies for the panel tests come from a venv the executor creates at `panel/.venv` (`python3 -m venv panel/.venv && panel/.venv/bin/pip install "fastapi==0.115.*" "pillow==10.*" httpx pytest`); add `.venv*/` to `.gitignore`. `tests/panel-static.sh` must still pass after the HTML copy changes (it asserts specific markers; the ones it lists must remain).

### Plan C — Exception types in mirror logs (OBS-03)
- **D-12:** In `frameio-mirror/app.py` change `log.error("Reconcile listing failed: %s", exc)` (in `reconcile_once`) to `log.error("Reconcile listing failed: %s: %r", type(exc).__name__, exc)` and `log.warning("Telegram send exception: %s", exc)` (in `_tg_send`) to the same `%s: %r` shape. Leave lines that already pass `exc_info=True` alone. Cause: httpx timeout exceptions stringify to an empty message, which produced `Reconcile listing failed: ` on 2026-08-23.
- **D-13:** Test `frameio-mirror/tests/test_logging.py` using pytest `caplog`: (1) monkeypatch `app.get_token` to raise `httpx.ReadTimeout("")` and set enough state for `reconcile_once` to reach the listing (see how `test_app.py` prepares `CFG` and state; reuse its fixture pattern), assert `"ReadTimeout"` in `caplog.text`; (2) monkeypatch `httpx.AsyncClient.post` to raise `httpx.ConnectTimeout("")` with `app._TG` set, call `_tg_send("x")`, assert `"ConnectTimeout"` in `caplog.text`. Full suite stays green (57 + new tests).

### Claude's Discretion
- awk/sed versus pure Bash for the log parser (Bash `while read` with regex is fine; the log is small).
- Whether the abort probe lives in a function; naming.
- Test file organization inside `panel/tests/`.

</decisions>

<specifics>
## Specific Ideas

- The healthcheck already has `docker_cmd`, `tg`, `add`, `prepare_state_storage`, and a run lock; reuse them. `STATE` is a file path and its parent is the protected dir.
- The docker stub (`tests/fixtures/healthcheck/docker`) exits 64 for unknown subcommands, so `logs` must be added before any abort case can pass.
- Real aborts to sanity-check the parser against (all from tower's pure-ftpd log): DSC01932.ARW 3317368 bytes 3.57KB/sec (Aug 22 18:26), DSC01932.ARW 32711768 bytes 34.45KB/sec (Aug 22 19:19), DSC01931.ARW 43150400 bytes 45.32KB/sec (Aug 22 19:19), DSC01931.ARW 3084240 bytes 9097.19KB/sec with no `451-Timeout` line (Aug 23 09:47), C0090.MP4 60889848 bytes 65.32KB/sec (Aug 31 11:00).
- Panel copy today (index.html ~line 1335 and 1343-1347, 1641) is what D-08/D-09 edit.

</specifics>

<canonical_refs>
## Canonical References

**Downstream agents MUST read these before planning or implementing.**

### Healthcheck
- `contrib/unraid/ftpdropbox-healthcheck.sh` — structure, `tg`, `docker_cmd`, state handling
- `tests/unraid-healthcheck.sh` and `tests/fixtures/healthcheck/{docker,curl}` — harness and stubs
- `pure-ftpd/patches/0001-no-publish-aborted-uploads.patch` — why an abort leaves no file behind

### Panel
- `panel/app.py` — `api_status`, `_library_name_sizes`, `api_quarantine`, `api_quarantine_action`, `walk_files`, `csrf_guard`
- `panel/index.html` — quarantine rows, prune bar, status messages (grep `in_library`, `prune_verified`, `Pruned`)
- `tests/panel-static.sh` — the HTML contract that must keep passing
- `PRODUCT.md` — principle 2: never overclaim verification

### Mirror
- `frameio-mirror/app.py` — `_tg_send`, `reconcile_once`
- `frameio-mirror/tests/test_app.py` — fixture pattern for `CFG`/state setup

### Milestone
- `.planning/PROJECT.md` — Key Decisions and § Context findings 2, 3, 4, 5
- `.planning/codebase/CONVENTIONS.md`, `.planning/codebase/TESTING.md`

</canonical_refs>

<code_context>
## Existing Code Insights

### Reusable Assets
- `sanitize`-style discipline is not needed in the healthcheck for the filename (Telegram receives plain text via `--data-urlencode`), but strip control characters anyway with `tr -d '\000-\037\177'` as the sorter does.
- Panel `noclobber_move`, `safe_child`, `err`, `no_store` are the helpers to keep using.

### Established Patterns
- Healthcheck alerts go through `tg` and return nonzero on failure; the abort probe must tolerate a failed send (retry next run because the fingerprint is only recorded after a successful send).
- Panel writes are atomic (`mkstemp` + `os.replace`); prune only unlinks, no writes.

### Integration Points
- The panel's `/api/quarantine/action` is the only caller of prune; `index.html` reads `removed` from the response.
- Phase 4 copies the healthcheck script to `/boot/config/scripts/` on tower; nothing else consumes it.

</code_context>

<deferred>
## Deferred Ideas

- Panel listing of aborted uploads (OBS-04) and a panel-readable healthcheck feed (OBS-05): deferred milestone.
- Compose-file wiring of the abort probe (`camera-ftp` container name is already a candidate in the script).

</deferred>

---

*Phase: 03-observability-and-panel-honesty*
*Context gathered: 2026-09-01 by the orchestrator*
