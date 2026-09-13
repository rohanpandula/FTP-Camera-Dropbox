# Concerns (2026-09-01 review of the live deployment)

Evidence lives in PROJECT.md § Context. Summary of what this milestone addresses and what it deliberately leaves alone.

## Addressed in this milestone

1. **HEIF false quarantine** — `heif_container_validate` requires 8 bytes for every next box header; a valid X100VI file with three trailing pad bytes was quarantined (`DSCF8283.HIF`). Fix in Phase 2.
2. **Silent FTP aborts** — since the pure-ftpd fork stopped publishing aborted uploads, a 451 leaves no trace outside pure-ftpd's own log. Three files (DSC01931.ARW, DSC01932.ARW, C0090.MP4) were lost without an alert. Fix in Phase 3 via the root healthcheck cron.
3. **mtime as arrival time** — STUCK scan and panel age read mtime; SMB drags preserve capture-time mtime, producing false STUCK lines and a red lamp. Fix in Phases 2 and 3 with ctime.
4. **Empty exception messages** in mirror logs (httpx timeouts). Fix in Phase 3.
5. **"Verified" prune compares name+size** while the sorter compares bytes. Fix in Phase 3.
6. **Branch drift** — production runs an unmerged branch for the mirror; this checkout carried a stale panel draft. Fix in Phase 1.

## Left alone on purpose

- RAW size floors: the only small ARW in quarantine is genuinely truncated; sorted has 9 ARWs under 40 MB and 5 NEFs under 25 MB from other bodies or pre-floor days, none quarantined since.
- Panel lamp is "derived" on tower because the healthcheck dir is root 0700; the panel exposes that word in the header, which is honest.
- `/data/Vik`, `recovery/`, and pre-August lock debris in the data root: manual cleanup, offered as an optional checkpoint in Phase 4.

## Operational guardrails for agents

- Never run `docker stop|rm|rename|run` against the named production containers on tower outside a `checkpoint:human-verify` task in Phase 4.
- Never read or print `/mnt/user/appdata/*/frameio.json`, `telegram.json`, or `/mnt/cache/appdata/frameio-mirror/private/state.json`.
- Never modify anything under `/mnt/nvmenetworkstorage/FTPDropbox/sorted/`.
