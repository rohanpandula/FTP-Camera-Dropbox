# frameio-mirror

Optional companion to the FTP Camera Dropbox: receives [Frame.io Camera-to-Cloud](https://frame.io/c2c) webhooks and downloads new assets into the same `incoming/` directory the sorter watches. Frame.io retains its copy by default; quota-clearing deletion is an explicit opt-in.

The sorter doesn't know or care that a file came from Frame.io instead of FTP; it runs the same `wait_stable → validate → date-sort → quarantine-or-sorted` pipeline either way. As far as your file tree is concerned, the C2C feed and the FTP feed are one library.

## Why this exists

Frame.io's C2C is the cleanest cloud-upload path for a lot of modern bodies (Sony A1, A9 III, Z9 firmware 5+, plus phones via the Frame.io app). But the **free tier caps storage at 2 GB**. Without a mirror, you're stuck either paying or manually pulling files out and deleting them.

Files arrive → get mirrored to your NAS → optionally deleted upstream. The default keeps both copies. Set `DELETE_UPSTREAM=1` only when treating Frame.io as transit storage is intentional.

## What you need (no webhook-only shortcut)

The Frame.io V4 webhook payload contains **only a resource ID**: no filename, size, or pre-signed URL. The [docs](https://developer.adobe.com/frameio/api/current/guides/webhooks/) are explicit: *"We do not include any additional information beyond the resource ID."* So there's no "webhook-only" mode. Every download goes through the authenticated V4 API, and you need two things:

1. **A webhook signing secret** (`FRAMEIO_WEBHOOK_SECRET`). Frame.io shows it once when you create the webhook. The service **fails closed** (HTTP 503) on unsigned requests, which is what you want on a public endpoint.
2. **Adobe credentials** to call the API (fetch metadata + download URL, and optionally delete). Two auth modes depend on your Adobe account type:

| Auth mode | For | How |
|---|---|---|
| **OAuth Server-to-Server** | Enterprise Adobe orgs | Paste `client_id` + `client_secret`; headless, no further steps |
| **OAuth Web App + refresh token** | Personal Adobe accounts (no S2S option) | Set `OAUTH_SETUP_SECRET`, authenticate one `POST /oauth/start`, then open the returned Adobe URL; the refresh token is persisted and renews on its own |

Most individuals land in the second case. See the Adobe Developer Console walkthrough below.

## Quickstart

From the repo root:

```bash
# 1. bring up the mirror alongside the FTP+sorter stack
docker compose --profile frameio up -d --build

# 2. confirm it's healthy
curl http://localhost:8000/health
# -> status "ok" when credentials, intake, and private state are ready
```

The health check verifies credentials, writable intake, a writable private
staging directory on a separate mount, and the structure and writability of
durable state. Filesystem probes run outside the request loop and their result
is cached for five seconds, so a repaired condition can take one cache window
to show as healthy.

You now need to expose `:8000` to the public internet so Frame.io can POST to it. Cloudflare Tunnel is the cleanest path; ngrok works for testing; Caddy or Traefik with Let's Encrypt is fine for a permanent setup. The endpoint Frame.io will POST to is `https://your-domain.example.com/webhook`.

## Configure the webhook in Frame.io

1. Go to your Frame.io workspace settings → **Webhooks** → **Create New Webhook**.
2. **Name:** `camera-dropbox-mirror` (or whatever).
3. **Events:** pick the event that fires when a C2C asset finishes uploading. As of writing this is `file.ready` (sometimes labeled `asset.ready` in older docs).
4. **Webhook URL:** `https://your-domain.example.com/webhook`
5. **Status:** Enabled.
6. **Workspace:** select the one your C2C device is paired with.
7. Save. Frame.io shows the **webhook signing secret** on creation. Copy it into `FRAMEIO_WEBHOOK_SECRET` (or `frameio.json`) and restart. **This is required**: the service rejects unsigned webhooks with HTTP 503 (fails closed), so without the secret nothing will process.

Now upload one frame from a C2C-paired device. Watch `docker logs -f frameio-mirror`. You should see:

```
[INFO] Signature verified (drift=0s)
[INFO] Webhook: type=file.ready resource.type=file resource.id=abc123 account.id=...
[INFO] Fetching file abc123
[INFO] Downloading DSC00042.ARW
[INFO] Downloaded 64618496 bytes for DSC00042.ARW
[INFO] Size verified for DSC00042.ARW (64618496 bytes)
[INFO] Asset abc123 retained in Frame.io (retention policy)
```

Followed by the sorter picking it up:

```
[2026-05-17 20:14:32] ok: DSC00042.ARW -> 2026-05-17/raw/DSC00042.ARW
```

## Adobe Developer Console setup (required for API download access)

Frame.io's V4 API authenticates via Adobe IMS. There's no per-user API key anymore. One-time setup:

1. Go to <https://developer.adobe.com/console>, sign in with the same account that owns your Frame.io workspace.
2. **Create new project** → **Add API** → search for **Frame.io API** → Next.
3. **Server-to-Server OAuth** authentication → Next.
4. Pick the product profile that includes your Frame.io workspace → Save.
5. From the project's **Credentials** tab grab:
   - `Client ID` → `ADOBE_CLIENT_ID`
   - `Client Secret` → `ADOBE_CLIENT_SECRET`
6. Drop them in `.env` (or `frameio.json`) and restart: `docker compose --profile frameio up -d`.

For a personal account, choose **OAuth Web App** instead, register the exact
`OAUTH_REDIRECT_URI`, and set a long random `OAUTH_SETUP_SECRET`. After the
container starts, request a short-lived authorization URL without putting that
secret in a URL or shell history:

```bash
read -rs OAUTH_SETUP_SECRET
curl --fail --request POST \
  --header "X-Setup-Secret: ${OAUTH_SETUP_SECRET}" \
  https://your-host/oauth/start
unset OAUTH_SETUP_SECRET
```

Open the `authorize_url` from the JSON response and complete Adobe sign-in. The
callback saves the refresh token in the private state volume.

Verify auth works:

```bash
docker logs frameio-mirror 2>&1 | grep -i "adobe ims"
# Adobe IMS token acquired; expires_in=86399s
```

## Configuration

| Variable | Default | Description |
|---|---|---|
| `INCOMING_DIR` | `/data/incoming` | Where to drop downloaded files (must match the sorter's `INCOMING`) |
| `FRAMEIO_WEBHOOK_SECRET` | *(unset)* | **Required.** HMAC-SHA256 webhook signature key from Frame.io. The service **fails closed** (HTTP 503) on unsigned requests. |
| `ADOBE_CLIENT_ID` | *(unset)* | **Required.** Adobe OAuth client ID (S2S or Web App). |
| `ADOBE_CLIENT_SECRET` | *(unset)* | **Required.** Matching client secret. |
| `ADOBE_SCOPES` | `openid,AdobeID,additional_info.roles,offline_access,profile,email` | OAuth scopes. `offline_access` is required for the Web App refresh-token flow. |
| `OAUTH_REDIRECT_URI` | *(unset)* | Required for the Web App flow. Must exactly match the redirect URI registered in Adobe Dev Console, e.g. `https://your-host/oauth/callback`. |
| `OAUTH_SETUP_SECRET` | *(unset)* | **Required for OAuth Web App enrollment.** Send it only in `X-Setup-Secret` to `POST /oauth/start`; the response contains the Adobe authorization URL. |
| `DELETE_UPSTREAM` | `0` | `0` keeps the Frame.io copy. `1` deletes only after a durable hidden local copy passes exact positive size and SHA-256 revalidation. Full media validation still happens asynchronously in the sorter. |
| `REFRESH_TOKEN_FILE` | `/etc/frameio-oauth-state.json` | Writable JSON state for refresh tokens, durable webhook jobs, local-publication receipts, and reconciliation IDs. Its parent must be owner-only (or root-protected) and on a mount distinct from `INCOMING_DIR`. Compose overrides this to `/var/lib/frameio/state.json` on its private `frameio_state` volume. |
| `STAGING_DIR` | `/var/lib/frameio/staging` | Owner-only persistent download staging. It must be a different mount from `INCOMING_DIR`; Compose places it in `frameio_state`, outside the shared camera-data volume. Never put it beneath `/data`. |
| `WEBHOOK_MAX_BYTES` | `1000000` | Reject webhook bodies larger than this (Frame.io payloads are tiny). |
| `FRAMEIO_WORKERS` | `4` | Fixed number of asset workers shared by webhooks and reconciliation. This bounds simultaneous downloads and API work. |
| `FRAMEIO_QUEUE_SIZE` | `256` | Maximum jobs admitted to the in-memory worker queue. Accepted jobs are durable first, so a full queue leaves them for reconciliation instead of spawning unbounded request tasks. |
| `DOWNLOAD_MAX_BYTES` | `21474836480` | Hard per-asset download limit (20 GiB). Metadata already over the limit is rejected, and streaming stops before writing beyond it. |
| `DOWNLOAD_MAX_SECONDS` | `1800` | Overall per-asset download deadline in seconds (30 minutes), including a peer that sends bytes too slowly to hit a socket timeout. |
| `RECONCILE_INTERVAL_SECONDS` | `900` | How often the reconciliation sweep runs (see Reconciliation below). |
| `RECONCILE_MAX_PAGES` | `1000` | Maximum listing pages per cycle; a durable same-origin cursor resumes later pages. |
| `RECONCILE_MAX_ITEMS` | `100000` | Maximum listing items per cycle. |
| `RECONCILE_MAX_SECONDS` | `300` | Maximum wall time spent walking listing pages per cycle. |
| `DOWNLOAD_TMP_STALE_SECONDS` | `3600` | At startup and during reconciliation, reclaim exact-pattern unjournaled staging/handoff temps older than this after an interrupted process/host. |
| `FRAMEIO_C2C_FOLDER_ID` | *(auto)* | C2C ingest folder for reconciliation. Auto-discovered from the first webhook; set explicitly to override. |
| `FRAMEIO_C2C_ACCOUNT_ID` | *(auto)* | Account paired with an explicit folder override; normally auto-discovered. |

Env vars take precedence over `frameio.json`. Mount the JSON for the secrets-on-disk pattern; use env vars in dev or for one-offs.

## Security (the endpoint is public)

The `/webhook` and `/oauth/*` endpoints are reachable from the internet, so:

- **Webhook signatures fail closed.** No `FRAMEIO_WEBHOOK_SECRET` → every webhook is rejected with 503. Frame.io's `v0:<timestamp>:<body>` HMAC is verified with a ±5 min replay window.
- **OAuth enrollment is gated and CSRF-protected.** `OAUTH_SETUP_SECRET` is required in the `X-Setup-Secret` header for every `POST /oauth/start`; the flow also mints a random `state` that `/oauth/callback` verifies and consumes. This protects both first enrollment and re-enrollment on a public endpoint.
- **No secret leakage.** The setup secret never enters a request URL, Uvicorn access logging is disabled, error pages are HTML-escaped, and pre-signed download URLs are stripped of their query string before logging/alerting.
- **Private staged bytes.** Downloads stay in an owner-only persistent directory on a different mount from shared `incoming/`. Health reports the service as unhealthy and publication refuses to proceed if that isolation is missing, so another writer using the shared service UID cannot alter the only local copy before an upstream delete.
- **Runs non-root.** Deploy with `--user 99:100` (Unraid `nobody:users`); `umask 002` so downloads are group-writable (and SMB-deletable).

## Reconciliation (catch missed webhooks)

Frame.io retries a failed webhook 5 times, then gives up, so a long outage could orphan a file in Frame.io forever. A background sweep (every `RECONCILE_INTERVAL_SECONDS`, default 15 min) lists the C2C ingest folder and mirrors anything still sitting there.

- Every valid `file.ready` job is persisted **before** the webhook gets a 2xx response. That lets the very first asset retry after a token, metadata, network, or restart failure even before a folder ID has been discovered.
- The folder ID is auto-discovered from a successful metadata response and persisted. Override it with `FRAMEIO_C2C_FOLDER_ID`.
- Pagination has loop/same-origin guards plus generous page, item, and wall-clock limits. When a cycle reaches a limit, it persists the next cursor and resumes there later, so early retained assets cannot starve later pages.
- HTTP 403/404 failures are retried on later independent sweeps instead of being permanently skip-listed; a stale download URL must not strand media that becomes available later.
- When deletion is disabled, durable publication receipts distinguish already-mirrored assets from missed webhooks and prevent repeated suffixed downloads.
- An in-flight guard prevents a sweep and a live webhook from double-downloading the same asset.
- A fixed worker pool drains a bounded in-memory queue. Webhooks persist their job before acknowledgment; if that queue is full, reconciliation later admits the still-durable job instead of creating an unbounded task.

## Telegram alerts on failure (optional)

If you mount the same `telegram.json` the sorter uses at `/etc/telegram.json`, the mirror sends throttled ⚠️ alerts on:

| Failure | Throttle |
|---|---|
| `file.ready` arrived but Adobe credentials not configured | 1 / hour |
| Size mismatch (downloaded bytes ≠ metadata size) | 1 / 15 min |
| Frame.io API HTTP error (per status code) | 1 / 15 min |
| Unexpected exception during asset processing | 1 / 15 min |

Throttling is per-kind in memory, so a single broken state doesn't fan out into a spam loop. Resets on container restart (a fresh start gets one ping per error type even if you just saw one).

You also get a one-time 🟢 startup ping when the container boots. If it arrives, the credentials are reaching Telegram; if not, the mount isn't working.

The success path is silent. The sorter handles the "files landed" notifications via its own 5-min batched queue.

## Behavior notes

- **Deletion is opt-in and byte/hash-gated.** The default `DELETE_UPSTREAM=0` keeps Frame.io's copy. With `1`, bytes remain in the private persistent staging mount, are fsynced and journaled, then pass exact positive API-size and SHA-256 revalidation immediately before deletion. Only after the delete outcome is durable does the mirror copy the bytes to a unique hidden handoff in shared `incoming/`, verify that inode and digest, and atomically rename it without replacement. The private staged copy is removed only after the handoff and journal finalization succeed. Structural RAW/JPEG/video validation remains the sorter's next asynchronous step.
- **Size mismatch → bounded retry.** The partial hidden temp is removed, the durable job remains queued, and the upstream asset is not deleted.
- **No webhook secret → fail closed.** Without `FRAMEIO_WEBHOOK_SECRET` the service rejects every webhook with HTTP 503. There is no unsigned mode.
- **Bounded durable download work.** The webhook handler records the asset/account job before returning `{"status":"accepted"}`. A fixed worker pool drains a bounded queue; overflow remains in durable state for reconciliation. If state cannot be written, the request returns 503 so Frame.io retries instead of silently losing the first asset.
- **Bounded streams.** An advertised file over `DOWNLOAD_MAX_BYTES`, a stream that would cross that byte limit, or a transfer exceeding `DOWNLOAD_MAX_SECONDS` fails without deleting the upstream asset. Its durable job remains eligible for a later controlled retry.
- **Token refresh is automatic.** The IMS token is cached and refreshed within 5 minutes of expiry (Web App access tokens are 1 h; the refresh token is persisted and reused indefinitely). No restart needed.
- **Crash-safe, no-clobber publish.** The private state records the staged inode, size, digest, policy, hidden handoff, and exact collision candidate. Linux `renameat2(RENAME_NOREPLACE)` supplies final publication to the sorter; a crash at any transition resumes from verified private bytes without a second download or suffixed duplicate.
- **Interrupted temps are bounded.** Normal failures remove unjournaled staging and handoff temps immediately. After SIGKILL or host reboot, startup and every reconciliation cycle reclaim bytes only from exact-pattern, old, unlocked, single-link regular temps owned by the mirror. Active staged and handoff journal entries are always excluded; near-miss names and symlinks are untouched.
