# frameio-mirror

Optional companion to the FTP Camera Dropbox: receives [Frame.io Camera-to-Cloud](https://frame.io/c2c) webhooks, downloads new assets into the same `incoming/` directory the sorter watches, and (optionally) deletes them from Frame.io to keep the 2 GB free-tier quota clear.

The sorter doesn't know or care that the file came from Frame.io instead of an FTP upload — it goes through the exact same `wait_stable → validate → date-sort → quarantine-or-sorted` pipeline. From your file tree's perspective, your camera's C2C feed and its FTP feed merge cleanly into one library.

## Why this exists

Frame.io's C2C is the cleanest cloud-upload path for a lot of modern bodies (Sony A1, A9 III, Z9 firmware 5+, plus phones via the Frame.io app). But the **free tier caps storage at 2 GB**. Without a mirror, you're stuck either paying or manually pulling files out and deleting them.

This service treats Frame.io as a transit medium, not storage. Files arrive → get mirrored to your NAS → optionally deleted upstream. Your library stays on your own disks, your quota stays empty.

## What you need (no webhook-only shortcut)

The Frame.io V4 webhook payload contains **only a resource ID** — no filename, size, or pre-signed URL ([docs](https://developer.adobe.com/frameio/api/current/guides/webhooks/): *"We do not include any additional information beyond the resource ID"*). So there is no "webhook-only" mode: every download goes through the authenticated V4 API. You need two things:

1. **A webhook signing secret** (`FRAMEIO_WEBHOOK_SECRET`). Frame.io shows it once when you create the webhook. The service **fails closed** (HTTP 503) on unsigned requests — required for a public endpoint.
2. **Adobe credentials** to call the API (fetch metadata + download URL, then delete). Two auth modes depending on your Adobe account type:

| Auth mode | For | How |
|---|---|---|
| **OAuth Server-to-Server** | Enterprise Adobe orgs | Paste `client_id` + `client_secret`; headless, set-and-forget |
| **OAuth Web App + refresh token** | Personal Adobe accounts (no S2S option) | One-time browser dance via `/oauth/start`; refresh token persisted, auto-refreshes forever |

Most individuals are the second case — see the Adobe Developer Console walkthrough below.

## Quickstart

From the repo root:

```bash
# 1. bring up the mirror alongside the FTP+sorter stack
docker compose --profile frameio up -d --build

# 2. confirm it's healthy
curl http://localhost:8000/health
# -> {"status":"ok","version":"1.0.0","uptime_seconds":3}
```

You now need to expose `:8000` to the public internet so Frame.io can POST to it. Cloudflare Tunnel is the cleanest path; ngrok works for testing; Caddy or Traefik with Let's Encrypt is fine for a permanent setup. The endpoint Frame.io will POST to is `https://your-domain.example.com/webhook`.

## Configure the webhook in Frame.io

1. Go to your Frame.io workspace settings → **Webhooks** → **Create New Webhook**.
2. **Name:** `camera-dropbox-mirror` (or whatever).
3. **Events:** pick the event that fires when a C2C asset finishes uploading. As of writing this is `file.ready` (sometimes labeled `asset.ready` in older docs).
4. **Webhook URL:** `https://your-domain.example.com/webhook`
5. **Status:** Enabled.
6. **Workspace:** select the one your C2C device is paired with.
7. Save. Frame.io shows the **webhook signing secret** on creation — copy it into `FRAMEIO_WEBHOOK_SECRET` (or `frameio.json`) and restart. **This is required**: the service rejects unsigned webhooks with HTTP 503 (fails closed), so without the secret nothing will process.

Now upload one frame from a C2C-paired device. Watch `docker logs -f frameio-mirror`. You should see:

```
[INFO] Signature verified (drift=0s)
[INFO] Webhook: type=file.ready resource.type=file resource.id=abc123 account.id=...
[INFO] Fetching file abc123
[INFO] Downloading DSC00042.ARW
[INFO] Downloaded 64618496 bytes for DSC00042.ARW
[INFO] Size verified for DSC00042.ARW (64618496 bytes)
[INFO] Asset abc123 deleted from Frame.io
```

Followed by the sorter picking it up:

```
[2026-05-17 20:14:32] ok: DSC00042.ARW -> 2026-05-17/raw/DSC00042.ARW
```

## Adobe Developer Console setup (only needed for auto-delete)

Frame.io's V4 API authenticates via Adobe IMS — there's no per-user API key anymore. One-time setup:

1. Go to <https://developer.adobe.com/console>, sign in with the same account that owns your Frame.io workspace.
2. **Create new project** → **Add API** → search for **Frame.io API** → Next.
3. **Server-to-Server OAuth** authentication → Next.
4. Pick the product profile that includes your Frame.io workspace → Save.
5. From the project's **Credentials** tab grab:
   - `Client ID` → `ADOBE_CLIENT_ID`
   - `Client Secret` → `ADOBE_CLIENT_SECRET`
6. Drop them in `.env` (or `frameio.json`) and restart: `docker compose --profile frameio up -d`.

Verify auth works:

```bash
docker logs frameio-mirror 2>&1 | grep -i "adobe ims"
# Adobe IMS token acquired; expires_in=86399s
```

## Configuration

| Variable | Default | Description |
|---|---|---|
| `INCOMING_DIR` | `/data/incoming` | Where to drop downloaded files (must match the sorter's `INCOMING`) |
| `FRAMEIO_WEBHOOK_SECRET` | *(unset)* | If set, every webhook is verified via HMAC-SHA256. Strongly recommended for any public endpoint. |
| `ADOBE_CLIENT_ID` | *(unset)* | Adobe Server-to-Server OAuth client ID. Without it, auto-delete is disabled. |
| `ADOBE_CLIENT_SECRET` | *(unset)* | Matching client secret. |
| `ADOBE_SCOPES` | `openid,AdobeID,additional_info.roles` | OAuth scopes requested for the token. |

Env vars take precedence over `frameio.json`. Mount the JSON for the secrets-on-disk pattern; use env vars in dev or for one-offs.

## Telegram alerts on failure (optional)

If you mount the same `telegram.json` the sorter uses at `/etc/telegram.json`, the mirror sends throttled ⚠️ alerts on:

| Failure | Throttle |
|---|---|
| `file.ready` arrived but Adobe credentials not configured | 1 / hour |
| Size mismatch (downloaded bytes ≠ metadata size) | 1 / 15 min |
| Frame.io API HTTP error (per status code) | 1 / 15 min |
| Unexpected exception during asset processing | 1 / 15 min |

Throttling is per-kind in memory, so a single broken state doesn't fan out into a spam loop. Resets on container restart (a fresh start gets one ping per error type even if you just saw one).

You also get a one-time 🟢 startup ping each time the container boots — confirms the credentials are reaching Telegram. If you don't see one, the mount isn't working.

The success path is silent. The sorter handles the "files landed" notifications via its own 5-min batched queue.

## Behavior notes

- **Size mismatch → no delete.** If the bytes downloaded don't match the size in the webhook payload, the file is kept in `incoming/` (sorter will quarantine it on size-floor failure) and the upstream asset is NOT deleted. You can re-trigger by replaying the webhook from Frame.io.
- **No webhook secret → warning logged, signature check skipped.** Inside a private network this is fine. On a public endpoint, set one.
- **Background-task download.** The webhook handler returns `{"status":"accepted"}` in <100 ms and downloads in a background task. Frame.io won't time out and won't retry-storm on slow uploads.
- **Token refresh is automatic.** The IMS token is cached and refreshed when within 5 minutes of expiry. No restart needed.
