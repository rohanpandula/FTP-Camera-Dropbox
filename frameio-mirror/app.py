"""
frameio-mirror: FastAPI webhook receiver for Frame.io Camera-to-Cloud assets.

Receives Frame.io V4 webhooks, downloads the asset to incoming/, then
deletes it from Frame.io to keep the 2 GB free tier clear.

Config priority: env vars override /etc/frameio.json values.
"""

import asyncio
import hashlib
import hmac
import json
import logging
import os
import re
import time
from contextlib import asynccontextmanager
from pathlib import Path
from urllib.parse import urlencode

import httpx
from fastapi import BackgroundTasks, FastAPI, Header, HTTPException, Request
from fastapi.responses import HTMLResponse, RedirectResponse

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
)
log = logging.getLogger("frameio-mirror")

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------
_CONFIG_FILE = Path("/etc/frameio.json")

def _load_config() -> dict:
    file_cfg: dict = {}
    if _CONFIG_FILE.exists():
        try:
            file_cfg = json.loads(_CONFIG_FILE.read_text())
            log.info(
                "Config loaded from %s: adobe_client_id=%s, webhook_secret=%s",
                _CONFIG_FILE,
                "<set>" if file_cfg.get("adobe_client_id") else "<missing>",
                "<set>" if file_cfg.get("frameio_webhook_secret") else "<missing>",
            )
        except Exception as exc:
            log.warning("Failed to parse %s: %s", _CONFIG_FILE, exc)

    def _get(env_key: str, file_key: str, default: str = "") -> str:
        return os.environ.get(env_key) or file_cfg.get(file_key, default)

    return {
        "adobe_client_id": _get("ADOBE_CLIENT_ID", "adobe_client_id"),
        "adobe_client_secret": _get("ADOBE_CLIENT_SECRET", "adobe_client_secret"),
        "adobe_scopes": _get(
            "ADOBE_SCOPES", "adobe_scopes", "openid,AdobeID,additional_info.roles"
        ),
        "webhook_secret": _get("FRAMEIO_WEBHOOK_SECRET", "frameio_webhook_secret"),
        "incoming_dir": os.environ.get("INCOMING_DIR", "/data/incoming"),
        # OAuth Web App flow (used when S2S isn't available on the Adobe account):
        "oauth_redirect_uri": _get(
            "OAUTH_REDIRECT_URI", "oauth_redirect_uri",
            "https://c2c.roflix.club/oauth/callback",
        ),
        "refresh_token_file": os.environ.get(
            "REFRESH_TOKEN_FILE", "/etc/frameio-oauth-state.json"
        ),
    }


CFG = _load_config()

log.info(
    "Startup config: incoming_dir=%s, adobe_client_id=%s, webhook_secret=%s",
    CFG["incoming_dir"],
    "<set>" if CFG["adobe_client_id"] else "<NOT SET>",
    "<set>" if CFG["webhook_secret"] else "<NOT SET>",
)

# ---------------------------------------------------------------------------
# Adobe IMS token cache
# ---------------------------------------------------------------------------
_TOKEN_CACHE: dict = {"token": None, "expires_at": 0.0}
_TOKEN_LOCK = asyncio.Lock()

IMS_TOKEN_URL = "https://ims-na1.adobelogin.com/ims/token/v3"
IMS_AUTHORIZE_URL = "https://ims-na1.adobelogin.com/ims/authorize/v2"


def _load_refresh_token() -> str | None:
    """Read refresh_token from the writable tokens file (separate from frameio.json)."""
    path = Path(CFG["refresh_token_file"])
    if not path.exists():
        return None
    try:
        return json.loads(path.read_text()).get("refresh_token")
    except Exception as exc:
        log.warning("Failed to read refresh token from %s: %s", path, exc)
        return None


def _save_refresh_token(token: str) -> None:
    """In-place write of refresh_token to disk, mode 600.

    NOTE: Cannot use atomic temp+rename because Docker bind-mounted SINGLE files
    pin the destination inode (os.replace raises EBUSY). The file is mounted, not
    its directory, so we must write to the existing inode. Atomicity is lost but
    acceptable for this small infrequent write.
    """
    path = Path(CFG["refresh_token_file"])
    path.write_text(json.dumps({"refresh_token": token}))
    try:
        path.chmod(0o600)
    except Exception:
        pass  # bind-mounted file may not allow chmod
    log.info("Refresh token persisted to %s", path)


# ---------------------------------------------------------------------------
# Telegram alerts (optional — same telegram.json the sorter uses)
# ---------------------------------------------------------------------------
_TG_CONFIG_PATH = Path(os.environ.get("TG_CONFIG", "/etc/telegram.json"))
_TG: dict | None = None
_TG_THROTTLE: dict[str, float] = {}  # error-kind -> last-send monotonic ts
_TG_THROTTLE_LOCK = asyncio.Lock()


def _load_telegram() -> dict | None:
    if not _TG_CONFIG_PATH.exists():
        return None
    try:
        d = json.loads(_TG_CONFIG_PATH.read_text())
        if d.get("bot_token") and d.get("chat_id"):
            return {"bot_token": d["bot_token"], "chat_id": str(d["chat_id"])}
    except Exception as exc:
        log.warning("Failed to read telegram config %s: %s", _TG_CONFIG_PATH, exc)
    return None


_TG = _load_telegram()
log.info(
    "Telegram alerts: %s",
    f"enabled (chat={_TG['chat_id'][:4]}***)" if _TG else f"disabled (no {_TG_CONFIG_PATH})",
)


async def _tg_send(text: str) -> bool:
    """Direct send to Telegram (no throttle). Returns True on success."""
    if not _TG:
        return False
    async with httpx.AsyncClient() as client:
        try:
            resp = await client.post(
                f"https://api.telegram.org/bot{_TG['bot_token']}/sendMessage",
                data={"chat_id": _TG["chat_id"], "text": text},
                timeout=10,
            )
            if resp.status_code == 200:
                return True
            log.warning("Telegram send failed: HTTP %d %s", resp.status_code, resp.text[:200])
        except Exception as exc:
            log.warning("Telegram send exception: %s", exc)
    return False


async def notify_failure(kind: str, detail: str, throttle_minutes: int = 15) -> None:
    """Fire a throttled Telegram alert. Same kind within window is suppressed."""
    if not _TG:
        return
    async with _TG_THROTTLE_LOCK:
        now = time.monotonic()
        if now - _TG_THROTTLE.get(kind, 0) < throttle_minutes * 60:
            return
        _TG_THROTTLE[kind] = now
    text = f"⚠️ frameio-mirror: {kind}\n{detail[:500]}"
    if await _tg_send(text):
        log.info("Telegram alert sent: kind=%s", kind)


FRAMEIO_API = "https://api.frame.io/v4"
_REFRESH_BEFORE_EXPIRY = 300  # seconds


async def _fetch_token(client: httpx.AsyncClient) -> str:
    """Get an Adobe IMS Bearer token.

    Two grant types supported:
    - refresh_token (OAuth Web App, after one-time browser auth via /oauth/start)
    - client_credentials (S2S; only works on Enterprise Adobe orgs)
    """
    refresh_token = _load_refresh_token()
    if refresh_token:
        log.info("Using refresh_token grant (OAuth Web App flow)")
        data = {
            "grant_type": "refresh_token",
            "refresh_token": refresh_token,
            "client_id": CFG["adobe_client_id"],
            "client_secret": CFG["adobe_client_secret"],
        }
    else:
        log.info("Using client_credentials grant (S2S flow — requires Enterprise account)")
        data = {
            "grant_type": "client_credentials",
            "client_id": CFG["adobe_client_id"],
            "client_secret": CFG["adobe_client_secret"],
            "scope": CFG["adobe_scopes"],
        }

    resp = await client.post(
        IMS_TOKEN_URL,
        data=data,
        headers={"Content-Type": "application/x-www-form-urlencoded"},
        timeout=20,
    )
    if resp.status_code != 200:
        log.error("IMS token request failed: HTTP %d %s", resp.status_code, resp.text[:300])
        resp.raise_for_status()
    body = resp.json()
    token = body["access_token"]
    expires_in = int(body.get("expires_in", 3600))

    # Adobe IMS may rotate the refresh_token on each refresh — persist the new one
    if "refresh_token" in body and body["refresh_token"] != refresh_token:
        _save_refresh_token(body["refresh_token"])

    _TOKEN_CACHE["token"] = token
    _TOKEN_CACHE["expires_at"] = time.monotonic() + expires_in
    log.info("Adobe IMS token acquired; expires_in=%ds", expires_in)
    return token


async def get_token(client: httpx.AsyncClient) -> str:
    """Return a valid token, refreshing if within 5 min of expiry."""
    async with _TOKEN_LOCK:
        remaining = _TOKEN_CACHE["expires_at"] - time.monotonic()
        if _TOKEN_CACHE["token"] is None or remaining < _REFRESH_BEFORE_EXPIRY:
            log.info(
                "Token refresh triggered (remaining=%.0fs)", max(remaining, 0)
            )
            return await _fetch_token(client)
        return _TOKEN_CACHE["token"]


# ---------------------------------------------------------------------------
# FastAPI app
# ---------------------------------------------------------------------------
_START_TIME = time.monotonic()


@asynccontextmanager
async def lifespan(app: FastAPI):
    # One-time startup ping so user knows alerts are working
    if _TG:
        await _tg_send(
            "🟢 frameio-mirror online (alerts active — you'll see ⚠️ on real failures, throttled per kind)"
        )
    yield


app = FastAPI(title="frameio-mirror", version="1.0.0", lifespan=lifespan)


def _verify_signature(
    secret: str,
    raw_body: bytes,
    signature_header: str,
    timestamp_header: str,
) -> None:
    """Verify Frame.io V4 webhook signature.

    Per https://developer.adobe.com/frameio/api/current/guides/webhooks/:
    - Headers: X-Frameio-Signature ("v0=<hex>") + X-Frameio-Request-Timestamp (epoch)
    - Sign:    HMAC-SHA256(secret, "v0:<timestamp>:<body>") in latin-1
    - Reject if timestamp drifts more than 5 min (replay protection).
    """
    # Fail closed on missing secret — webhooks on a public endpoint without HMAC
    # verification is a serious vulnerability; refuse rather than degrade.
    if not secret:
        log.error("FRAMEIO_WEBHOOK_SECRET not configured — refusing webhook")
        raise HTTPException(status_code=503, detail="Webhook secret not configured")
    if not signature_header:
        raise HTTPException(status_code=403, detail="Missing X-Frameio-Signature header")
    if not timestamp_header:
        raise HTTPException(status_code=403, detail="Missing X-Frameio-Request-Timestamp header")

    try:
        req_time = int(timestamp_header)
    except ValueError:
        raise HTTPException(status_code=403, detail="Invalid timestamp format")

    drift = abs(int(time.time()) - req_time)
    if drift > 300:
        log.warning("Webhook timestamp drift %ds > 5 min — rejecting (possible replay)", drift)
        raise HTTPException(status_code=403, detail="Timestamp outside +/-5 min window")

    message = f"v0:{req_time}:".encode("latin-1") + raw_body
    expected = "v0=" + hmac.new(
        secret.encode("latin-1"), message, hashlib.sha256
    ).hexdigest()

    if not hmac.compare_digest(expected, signature_header):
        # Don't log signature prefixes — they're a weak side channel if logs leak
        log.warning("Signature mismatch (drift=%ds)", drift)
        raise HTTPException(status_code=403, detail="Invalid webhook signature")

    log.info("Signature verified (drift=%ds)", drift)


@app.get("/health")
async def health():
    uptime = int(time.monotonic() - _START_TIME)
    return {
        "status": "ok",
        "version": "1.0.0",
        "uptime_seconds": uptime,
        "has_refresh_token": _load_refresh_token() is not None,
    }


# ---------------------------------------------------------------------------
# OAuth Web App: one-time browser auth dance to obtain a refresh_token.
# Use this on personal Adobe accounts where S2S isn't available.
# ---------------------------------------------------------------------------
@app.get("/oauth/start")
async def oauth_start():
    """Redirect the user to Adobe IMS to grant access. Visit this URL in a browser
    after deploying the container; you'll be sent back to /oauth/callback with a code."""
    if not (CFG["adobe_client_id"] and CFG["adobe_client_secret"]):
        raise HTTPException(503, "Adobe client_id/secret not configured")
    params = {
        "client_id": CFG["adobe_client_id"],
        "scope": CFG["adobe_scopes"],
        "response_type": "code",
        "redirect_uri": CFG["oauth_redirect_uri"],
    }
    url = f"{IMS_AUTHORIZE_URL}?" + urlencode(params)
    log.info("Redirecting to IMS authorize: scope=%s", CFG["adobe_scopes"])
    return RedirectResponse(url, status_code=302)


@app.get("/oauth/callback")
async def oauth_callback(
    code: str = "",
    error: str = "",
    error_description: str = "",
):
    """Exchange the authorization code for tokens, persist the refresh_token."""
    if error:
        return HTMLResponse(
            f"<h1>Adobe auth failed</h1><p><b>{error}</b>: {error_description}</p>",
            status_code=400,
        )
    if not code:
        return HTMLResponse("<h1>Missing code parameter</h1>", status_code=400)

    async with httpx.AsyncClient() as client:
        resp = await client.post(
            IMS_TOKEN_URL,
            data={
                "grant_type": "authorization_code",
                "code": code,
                "client_id": CFG["adobe_client_id"],
                "client_secret": CFG["adobe_client_secret"],
                "redirect_uri": CFG["oauth_redirect_uri"],
            },
            headers={"Content-Type": "application/x-www-form-urlencoded"},
            timeout=30,
        )
        if resp.status_code != 200:
            log.error("Token exchange failed: HTTP %d %s", resp.status_code, resp.text[:300])
            return HTMLResponse(
                f"<h1>Token exchange failed</h1><pre>HTTP {resp.status_code}\n{resp.text[:1000]}</pre>",
                status_code=500,
            )
        body = resp.json()
        if "refresh_token" not in body:
            log.error("IMS response missing refresh_token: %s", {k: v for k, v in body.items() if k != "access_token"})
            return HTMLResponse(
                "<h1>No refresh_token in response</h1>"
                "<p>Adobe didn't return a refresh_token. Check the Web App credential's scopes — "
                "you may need <code>offline_access</code> or equivalent.</p>",
                status_code=500,
            )
        # Cache the access token FIRST — even if disk persist fails (e.g., readonly
        # mount, EBUSY), we want working creds for this process's lifetime.
        _TOKEN_CACHE["token"] = body["access_token"]
        _TOKEN_CACHE["expires_at"] = time.monotonic() + int(body.get("expires_in", 3600))

        try:
            _save_refresh_token(body["refresh_token"])
        except Exception as exc:
            log.error("Failed to persist refresh_token to disk: %s — token remains in memory only", exc)
            return HTMLResponse(
                "<h1>⚠️ Partial success</h1>"
                f"<p>Got tokens from Adobe but couldn't write to <code>{CFG['refresh_token_file']}</code>: <pre>{exc}</pre></p>"
                "<p>The access token works for this process only — container restart loses it. "
                "Check the mount, then re-visit /oauth/start.</p>",
                status_code=500,
            )

    return HTMLResponse(
        "<h1>✅ Auth complete</h1>"
        "<p>Refresh token persisted. The container can now call Frame.io API "
        "without further user input — including across restarts.</p>"
        "<p>You can close this tab. Trigger a Frame.io upload to test the full pipeline.</p>"
    )


@app.post("/webhook")
async def webhook(
    request: Request,
    background_tasks: BackgroundTasks,
    x_frameio_signature: str = Header(default=""),
    x_frameio_request_timestamp: str = Header(default=""),
):
    raw_body = await request.body()

    _verify_signature(
        CFG["webhook_secret"],
        raw_body,
        x_frameio_signature,
        x_frameio_request_timestamp,
    )

    try:
        payload = json.loads(raw_body)
    except json.JSONDecodeError:
        raise HTTPException(status_code=400, detail="Invalid JSON payload")

    event_type = payload.get("type", "")
    resource = payload.get("resource", {})
    resource_id = resource.get("id", "")
    resource_type = resource.get("type", "")
    # account_id is account-scoped on every V4 endpoint we'll call
    account_id = (payload.get("account") or {}).get("id", "")

    log.info(
        "Webhook: type=%s resource.type=%s resource.id=%s account.id=%s",
        event_type, resource_type, resource_id, account_id,
    )

    if event_type != "file.ready":
        return {"status": "ignored", "event_type": event_type}

    if not resource_id or resource_type != "file" or not account_id:
        log.error("Unexpected file.ready payload: %s", payload)
        raise HTTPException(status_code=422, detail="Missing or invalid resource/account")

    # Gracefully degrade if Adobe creds are missing — ack the webhook so Frame.io
    # doesn't retry-storm, but skip the download. (Without IMS we cannot call
    # the account-scoped file endpoints.)
    if not (CFG["adobe_client_id"] and CFG["adobe_client_secret"]):
        log.warning(
            "file.ready for %s but Adobe credentials not configured — cannot download",
            resource_id,
        )
        await notify_failure(
            "no_adobe_credentials",
            f"file.ready arrived (asset {resource_id[:8]}…) but ADOBE_CLIENT_ID/SECRET not set — file stays in Frame.io.",
            throttle_minutes=60,
        )
        return {"status": "acknowledged_skipped", "reason": "no_adobe_credentials"}

    background_tasks.add_task(process_asset, account_id, resource_id)
    return {"status": "accepted"}


# ---------------------------------------------------------------------------
# Background processing
# ---------------------------------------------------------------------------
def _pick(d: dict, *keys: str, default=None):
    """Return the first non-empty value among d[keys] or d['data'][keys]."""
    data = d.get("data") if isinstance(d.get("data"), dict) else {}
    for k in keys:
        v = d.get(k) or data.get(k)
        if v not in (None, "", 0):
            return v
    return default


def _safe_filename(name: str | None, fallback: str) -> str:
    """Strip path components and control chars; reject empty/dot results."""
    if not name:
        return fallback
    # basename only — defeats "../etc/passwd" and "/etc/passwd"
    base = Path(name).name
    # strip control chars (null, etc.) that some filesystems mishandle
    base = re.sub(r"[\x00-\x1f\x7f]", "", base)
    if not base or base in (".", ".."):
        return fallback
    # cap length to avoid filesystem limits
    return base[:240]


async def process_asset(account_id: str, asset_id: str) -> None:
    """Fetch metadata+download URL via the V4 account-scoped file endpoint
    (one call with ?include=media_links.original), stream to incoming, delete upstream."""
    incoming_dir = Path(CFG["incoming_dir"])
    incoming_dir.mkdir(parents=True, exist_ok=True)

    file_url = f"{FRAMEIO_API}/accounts/{account_id}/files/{asset_id}"

    async with httpx.AsyncClient(follow_redirects=True) as client:
        try:
            token = await get_token(client)
            auth = {"Authorization": f"Bearer {token}"}

            # Single call returns metadata + pre-signed download URL
            log.info("Fetching file %s", asset_id)
            meta_resp = await client.get(
                file_url,
                params={"include": "media_links.original"},
                headers=auth,
                timeout=30,
            )
            meta_resp.raise_for_status()
            body = meta_resp.json()

            filename_raw = _pick(body, "name", "filename", "file_name")
            filename = _safe_filename(filename_raw, fallback=f"{asset_id}.bin")
            if filename_raw and filename != filename_raw:
                log.warning("Filename sanitized: %r -> %r", filename_raw, filename)
            expected_size = _pick(body, "file_size", "filesize", "size")

            # media_links.original may be at top-level or under data.*
            data = body.get("data") if isinstance(body.get("data"), dict) else body
            media_links = (data.get("media_links") or {}) if isinstance(data, dict) else {}
            original = media_links.get("original") or {}
            if isinstance(original, str):
                download_url = original
            else:
                download_url = original.get("url") or original.get("download_url")
            if not download_url:
                log.error("No media_links.original URL in response for %s", asset_id)
                return

            dest = incoming_dir / filename
            tmp = incoming_dir / f".tmp.{filename}"

            # Stream to a hidden temp file (sorter ignores dotfiles), then atomic
            # rename so the sorter sees the file appear all at once.
            log.info("Downloading %s -> %s", filename, dest)
            downloaded = 0
            async with client.stream("GET", download_url, timeout=300) as stream:
                stream.raise_for_status()
                with tmp.open("wb") as fh:
                    async for chunk in stream.aiter_bytes(chunk_size=65536):
                        fh.write(chunk)
                        downloaded += len(chunk)
            log.info("Downloaded %d bytes for %s", downloaded, filename)

            if expected_size and downloaded != expected_size:
                log.warning(
                    "Size mismatch for %s: expected=%d got=%d — NOT deleting upstream",
                    filename, expected_size, downloaded,
                )
                await notify_failure(
                    "size_mismatch",
                    f"{filename}: expected {expected_size:,} bytes, got {downloaded:,}. Upstream not deleted; partial in {tmp.name}.",
                    throttle_minutes=15,
                )
                # keep the partial in tmp so we can inspect
                return
            if expected_size:
                log.info("Size verified for %s (%d bytes)", filename, downloaded)
            else:
                log.info("No size in metadata for %s — skipping size check", filename)

            tmp.replace(dest)  # atomic on same filesystem; sorter sees moved_to

            # Delete upstream to keep Frame.io free tier clear
            log.info("Deleting asset %s from Frame.io", asset_id)
            token = await get_token(client)
            del_resp = await client.delete(
                file_url,
                headers={"Authorization": f"Bearer {token}"},
                timeout=30,
            )
            if del_resp.status_code in (200, 204):
                log.info("Asset %s deleted from Frame.io", asset_id)
            else:
                log.error(
                    "Failed to delete asset %s: HTTP %d %s",
                    asset_id, del_resp.status_code, del_resp.text[:200],
                )

        except httpx.HTTPStatusError as exc:
            sc = exc.response.status_code
            log.error(
                "HTTP error processing asset %s: %s %s",
                asset_id, sc, exc.response.text[:200],
            )
            await notify_failure(
                f"http_{sc}",
                f"Asset {asset_id[:8]}…: HTTP {sc} from {exc.request.url}\n{exc.response.text[:300]}",
                throttle_minutes=15,
            )
        except Exception as exc:
            log.error("Unexpected error processing asset %s: %s", asset_id, exc, exc_info=True)
            await notify_failure(
                "asset_exception",
                f"Asset {asset_id[:8]}…: {type(exc).__name__}: {exc}",
                throttle_minutes=15,
            )
