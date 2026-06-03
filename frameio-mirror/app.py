"""
frameio-mirror: FastAPI webhook receiver for Frame.io Camera-to-Cloud assets.

Receives Frame.io V4 webhooks, downloads the asset to incoming/, then
deletes it from Frame.io to keep the 2 GB free tier clear.

Config priority: env vars override /etc/frameio.json values.
"""

import asyncio
import hashlib
import hmac
import html
import json
import logging
import os
import re
import secrets
import time
from contextlib import asynccontextmanager
from pathlib import Path
from urllib.parse import urlencode, urlsplit

import httpx
from fastapi import BackgroundTasks, FastAPI, Header, HTTPException, Request
from fastapi.responses import HTMLResponse, RedirectResponse


def _redact_url(url) -> str:
    """Strip query + fragment from a URL before logging/alerting — pre-signed
    download URLs carry temporary AWS credentials in the query string."""
    try:
        p = urlsplit(str(url))
        return f"{p.scheme}://{p.netloc}{p.path}"
    except Exception:
        return "<url>"

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
)
log = logging.getLogger("frameio-mirror")

# Group-writable output so downloaded files land as nobody:users 664 and are
# deletable over SMB (paired with running the container as 99:100).
os.umask(0o002)

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
        # offline_access is REQUIRED for the OAuth Web App flow to return a
        # refresh_token. Without it, the auth dance succeeds but the next
        # restart loses the access token. profile/email are harmless and
        # commonly expected by Adobe IMS. AdobeID/openid are standard.
        "adobe_scopes": _get(
            "ADOBE_SCOPES", "adobe_scopes",
            "openid,AdobeID,additional_info.roles,offline_access,profile,email",
        ),
        "webhook_secret": _get("FRAMEIO_WEBHOOK_SECRET", "frameio_webhook_secret"),
        "incoming_dir": os.environ.get("INCOMING_DIR", "/data/incoming"),
        # OAuth Web App flow (used when S2S isn't available on the Adobe account).
        # MUST be overridden to your own public HTTPS endpoint — there's no sane
        # generic default. The same value must be registered in Adobe Dev Console.
        "oauth_redirect_uri": _get("OAUTH_REDIRECT_URI", "oauth_redirect_uri", ""),
        # Optional shared secret gating /oauth/start on the public endpoint. If
        # set, /oauth/start requires ?setup=<secret>. Strongly recommended.
        "oauth_setup_secret": _get("OAUTH_SETUP_SECRET", "oauth_setup_secret", ""),
        # Reject webhook bodies larger than this (Frame.io payloads are tiny JSON).
        "webhook_max_bytes": int(os.environ.get("WEBHOOK_MAX_BYTES", "1000000")),
        "refresh_token_file": os.environ.get(
            "REFRESH_TOKEN_FILE", "/etc/frameio-oauth-state.json"
        ),
        # Reconciliation: env vars override; otherwise auto-discovered from
        # first file.ready webhook and persisted to the state file.
        "c2c_folder_id": _get("FRAMEIO_C2C_FOLDER_ID", "c2c_folder_id"),
        "c2c_account_id": _get("FRAMEIO_C2C_ACCOUNT_ID", "c2c_account_id"),
        "reconcile_interval_seconds": int(
            os.environ.get("RECONCILE_INTERVAL_SECONDS", "900")  # 15 min default
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


def _load_state() -> dict:
    """Read the writable state JSON.

    Contains refresh_token plus any auto-discovered settings (c2c_folder_id,
    c2c_account_id) persisted across container restarts.
    """
    path = Path(CFG["refresh_token_file"])
    if not path.exists():
        return {}
    try:
        return json.loads(path.read_text())
    except Exception as exc:
        log.warning("Failed to read state file %s: %s", path, exc)
        return {}


def _save_state(updates: dict) -> None:
    """Merge updates into the state file and write in-place, mode 600.

    NOTE: Cannot use atomic temp+rename because Docker bind-mounted SINGLE files
    pin the destination inode (os.replace raises EBUSY). The file is mounted, not
    its directory, so we must write to the existing inode. Atomicity is lost but
    acceptable for these small infrequent writes.
    """
    path = Path(CFG["refresh_token_file"])
    state = _load_state()
    state.update(updates)
    path.write_text(json.dumps(state))
    try:
        path.chmod(0o600)
    except Exception:
        pass  # bind-mounted file may not allow chmod


def _load_refresh_token() -> str | None:
    return _load_state().get("refresh_token")


def _save_refresh_token(token: str) -> None:
    _save_state({"refresh_token": token})
    log.info("Refresh token persisted to %s", CFG["refresh_token_file"])


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

# Per-asset in-flight set — prevents a webhook and a reconcile sweep from
# both downloading the same file concurrently (which would corrupt the .tmp).
_IN_FLIGHT: set[str] = set()
_IN_FLIGHT_LOCK = asyncio.Lock()


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
# Reconciliation: periodic sweep of the C2C folder to catch missed webhooks
# ---------------------------------------------------------------------------
async def reconcile_once() -> int:
    """Walk the C2C folder and process any orphan files. Returns count processed."""
    folder_id = CFG["c2c_folder_id"] or _load_state().get("c2c_folder_id")
    account_id = CFG["c2c_account_id"] or _load_state().get("c2c_account_id")
    if not (folder_id and account_id):
        log.debug("Reconcile skipped — no folder_id discovered yet")
        return 0
    if not (CFG["adobe_client_id"] and CFG["adobe_client_secret"]):
        return 0

    orphans: list[str] = []
    async with httpx.AsyncClient(follow_redirects=True) as client:
        token = await get_token(client)
        auth = {"Authorization": f"Bearer {token}"}
        # First page hits the canonical endpoint with our query params.
        # Subsequent pages: Frame.io returns `links.next` as a URL (relative or
        # absolute) that already encodes the `after` cursor — follow it directly
        # rather than parsing the cursor out. Cap at 20 pages = 2000 files.
        url: str = f"{FRAMEIO_API}/accounts/{account_id}/folders/{folder_id}/files"
        params: dict | None = {"page_size": 100}
        for _ in range(20):
            resp = await client.get(url, params=params, headers=auth, timeout=30)
            if resp.status_code != 200:
                log.error("Reconcile: list failed HTTP %d %s", resp.status_code, resp.text[:200])
                await notify_failure(
                    "reconcile_list_failed",
                    f"HTTP {resp.status_code} listing folder {folder_id[:8]}…: {resp.text[:200]}",
                    throttle_minutes=60,
                )
                return 0
            body = resp.json()
            for item in body.get("data", []) or []:
                if not isinstance(item, dict):
                    continue
                # Only top-level file assets — skip folders, version_stacks, unknown
                if item.get("type") != "file":
                    continue
                aid = item.get("id")
                if aid:
                    orphans.append(aid)
            next_link = (body.get("links") or {}).get("next") if isinstance(body.get("links"), dict) else None
            if not next_link:
                break
            url = next_link if next_link.startswith("http") else f"https://api.frame.io{next_link}"
            params = None  # cursor is now encoded in url

    if not orphans:
        log.debug("Reconcile: 0 orphans")
        return 0

    # Filter out (a) anything a webhook is already processing — timing overlap,
    # not a real orphan — and (b) assets we've already classified as unmirrorable
    # (persistent 403/404: ghost records whose underlying file never committed).
    # Without (b), a ghost reappears in every sweep, 403s, and re-alerts forever.
    async with _IN_FLIGHT_LOCK:
        in_flight_snapshot = set(_IN_FLIGHT)
    skip_set = set(_load_state().get("reconcile_skip", []))
    skipped_ghosts = [a for a in orphans if a in skip_set]
    if skipped_ghosts:
        log.info("Reconcile: %d known-unmirrorable ghost(s) skipped", len(skipped_ghosts))
    truly_orphaned = [
        aid for aid in orphans
        if aid not in in_flight_snapshot and aid not in skip_set
    ]
    if not truly_orphaned:
        log.info("Reconcile: %d file(s) in folder, none actionable (in-flight or ghosts)", len(orphans))
        return 0

    log.warning("Reconcile: found %d orphan file(s) — processing", len(truly_orphaned))
    await notify_failure(
        "reconcile_orphans_found",
        f"Reconciliation found {len(truly_orphaned)} file(s) in Frame.io "
        f"that should have been mirrored (webhook delivery gap?). Processing now.",
        throttle_minutes=15,
    )
    processed = 0
    newly_skipped: list[str] = []
    for aid in truly_orphaned:
        try:
            status = await process_asset(account_id, aid)
        except Exception as exc:
            log.error("Reconcile: process_asset(%s) raised %s", aid, exc)
            continue
        if status == "ok":
            processed += 1
        elif status in ("http_403", "http_404"):
            # Unmirrorable — record so future sweeps don't re-attempt or re-alert
            newly_skipped.append(aid)
    if newly_skipped:
        skip_set.update(newly_skipped)
        _save_state({"reconcile_skip": sorted(skip_set)})
        log.warning(
            "Reconcile: %d asset(s) unmirrorable (403/404) — added to skip-list: %s",
            len(newly_skipped), ", ".join(a[:8] for a in newly_skipped),
        )
        await notify_failure(
            "reconcile_ghost_skiplisted",
            f"{len(newly_skipped)} Frame.io asset(s) can't be downloaded (403/404 — "
            f"likely ghost records with no underlying file). Added to skip-list so "
            f"they won't re-alert. Delete them from Frame.io's UI when convenient.",
            throttle_minutes=1440,  # at most once a day
        )
    return processed


async def reconcile_loop() -> None:
    """Background loop: kicks off once after a short delay so discovery has a chance,
    then runs at CFG['reconcile_interval_seconds']. Errors don't kill the loop."""
    interval = max(60, CFG["reconcile_interval_seconds"])
    log.info("Reconcile loop armed (every %ds)", interval)
    # Wait briefly so the first webhook can populate discovery state before our first sweep
    await asyncio.sleep(30)
    while True:
        try:
            n = await reconcile_once()
            if n:
                log.info("Reconcile cycle processed %d orphan(s)", n)
        except Exception as exc:
            log.error("Reconcile loop exception: %s", exc, exc_info=True)
            await notify_failure("reconcile_exception", f"{type(exc).__name__}: {exc}", throttle_minutes=60)
        await asyncio.sleep(interval)


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
    # Start reconciliation loop in background
    task = asyncio.create_task(reconcile_loop())
    try:
        yield
    finally:
        task.cancel()
        try:
            await task
        except (asyncio.CancelledError, Exception):
            pass


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
#
# Security: these endpoints are internet-facing. Three protections:
#   1. Optional setup secret (?setup=...) gates /oauth/start.
#   2. CSRF state param: random state minted in /start, verified+consumed in
#      /callback (prevents a forged callback from injecting someone else's code).
#   3. Re-enrollment lockout: once a refresh_token exists, /start refuses unless
#      &force=1 — stops a visitor from overwriting our token with their own
#      Adobe account.
# ---------------------------------------------------------------------------
_OAUTH_STATES: dict[str, float] = {}  # state -> created monotonic ts
_OAUTH_STATE_TTL = 600  # 10 minutes


def _prune_oauth_states() -> None:
    now = time.monotonic()
    for s, ts in list(_OAUTH_STATES.items()):
        if now - ts > _OAUTH_STATE_TTL:
            _OAUTH_STATES.pop(s, None)


@app.get("/oauth/start")
async def oauth_start(setup: str = ""):
    """Redirect the user to Adobe IMS to grant access. Visit this URL in a browser
    after deploying the container; you'll be sent back to /oauth/callback with a code."""
    if not (CFG["adobe_client_id"] and CFG["adobe_client_secret"]):
        raise HTTPException(503, "Adobe client_id/secret not configured")
    if not CFG["oauth_redirect_uri"]:
        raise HTTPException(503, "oauth_redirect_uri not configured")

    # Enrollment authorization:
    #  - If OAUTH_SETUP_SECRET is configured, every enrollment (fresh or re-auth)
    #    must pass ?setup=<secret>. Strongest.
    #  - If no secret is configured, allow FRESH enrollment (first-time setup) but
    #    REFUSE re-enrollment once a refresh_token exists — otherwise a visitor
    #    could /oauth/start, authorize their own Adobe account, and break the
    #    mirror. To re-auth without a secret, clear refresh_token from the state
    #    file (filesystem access == admin boundary).
    setup_secret = CFG["oauth_setup_secret"]
    if setup_secret:
        if not secrets.compare_digest(setup, setup_secret):
            log.warning("oauth/start rejected — missing/invalid setup secret")
            raise HTTPException(403, "Missing or invalid setup secret")
    elif _load_refresh_token():
        raise HTTPException(
            409,
            "Already authenticated. To re-enroll: set OAUTH_SETUP_SECRET and pass "
            "?setup=..., or clear refresh_token from the state file first.",
        )

    _prune_oauth_states()
    state = secrets.token_urlsafe(32)
    _OAUTH_STATES[state] = time.monotonic()
    params = {
        "client_id": CFG["adobe_client_id"],
        "scope": CFG["adobe_scopes"],
        "response_type": "code",
        "redirect_uri": CFG["oauth_redirect_uri"],
        "state": state,
    }
    url = f"{IMS_AUTHORIZE_URL}?" + urlencode(params)
    log.info("Redirecting to IMS authorize: scope=%s", CFG["adobe_scopes"])
    return RedirectResponse(url, status_code=302)


@app.get("/oauth/callback")
async def oauth_callback(
    code: str = "",
    error: str = "",
    error_description: str = "",
    state: str = "",
):
    """Exchange the authorization code for tokens, persist the refresh_token."""
    if error:
        return HTMLResponse(
            f"<h1>Adobe auth failed</h1><p><b>{html.escape(error)}</b>: "
            f"{html.escape(error_description)}</p>",
            status_code=400,
        )
    # Verify + consume CSRF state
    _prune_oauth_states()
    if not state or _OAUTH_STATES.pop(state, None) is None:
        log.warning("oauth/callback rejected — invalid or expired state")
        return HTMLResponse(
            "<h1>Invalid or expired state</h1><p>Restart the flow from /oauth/start.</p>",
            status_code=403,
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
            # Generic browser-visible error; details are in the logs only
            return HTMLResponse(
                f"<h1>Token exchange failed</h1><p>HTTP {resp.status_code}. "
                "Check container logs for details.</p>",
                status_code=500,
            )
        body = resp.json()
        if "refresh_token" not in body:
            _SECRETISH = ("token", "secret", "code", "authorization")
            safe = {k: v for k, v in body.items()
                    if not any(s in k.lower() for s in _SECRETISH)}
            log.error("IMS response missing refresh_token; non-secret fields: %s", safe)
            return HTMLResponse(
                "<h1>No refresh_token in response</h1>"
                "<p>Adobe didn't return a refresh_token. Check the Web App credential's scopes — "
                "you need <code>offline_access</code>.</p>",
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
                "<p>Got tokens from Adobe but couldn't write the state file "
                "(check the mount). The access token works for this process only — "
                "a container restart loses it. Fix the mount, then re-visit /oauth/start.</p>",
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
    # Bound the body before reading it — unauthenticated public endpoint, don't
    # let a huge POST exhaust memory before HMAC rejection. Frame.io payloads are
    # a few hundred bytes.
    max_bytes = CFG["webhook_max_bytes"]
    clen = request.headers.get("content-length")
    if clen and clen.isdigit() and int(clen) > max_bytes:
        raise HTTPException(status_code=413, detail="Payload too large")
    raw_body = await request.body()
    if len(raw_body) > max_bytes:
        raise HTTPException(status_code=413, detail="Payload too large")

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
    # In-flight dedup: skip if another task is already processing this asset
    async with _IN_FLIGHT_LOCK:
        if asset_id in _IN_FLIGHT:
            log.info("Asset %s already in-flight — skipping duplicate", asset_id)
            return "in_flight"
        _IN_FLIGHT.add(asset_id)
    try:
        return await _process_asset_inner(account_id, asset_id)
    finally:
        async with _IN_FLIGHT_LOCK:
            _IN_FLIGHT.discard(asset_id)


async def _process_asset_inner(account_id: str, asset_id: str) -> str:
    """Returns a status string: 'ok', 'no_url', 'size_mismatch',
    'collision_overflow', 'http_<code>', or 'error'."""
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

            # Discover the C2C ingest folder for reconciliation, persist on first hit
            data_obj = body.get("data") if isinstance(body.get("data"), dict) else body
            parent_folder = (
                (data_obj.get("parent_id") if isinstance(data_obj, dict) else None)
                or (data_obj.get("folder_id") if isinstance(data_obj, dict) else None)
                or ((data_obj.get("parent") or {}).get("id") if isinstance(data_obj, dict) else None)
            )
            if parent_folder:
                state = _load_state()
                if not state.get("c2c_folder_id"):
                    _save_state({"c2c_folder_id": parent_folder, "c2c_account_id": account_id})
                    log.info(
                        "Discovered C2C ingest folder: %s (account=%s) — reconciliation enabled",
                        parent_folder, account_id,
                    )

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
                return "no_url"

            # Asset-id-prefixed tmp so two assets with same filename don't race
            # on the same .tmp path during a webhook+reconcile overlap.
            tmp = incoming_dir / f".tmp.{asset_id}.{filename}"

            # Stream to the hidden temp file (sorter ignores dotfiles), then atomic
            # rename so the sorter sees the file appear all at once. The final name
            # is resolved at publish time below — NOT here — to avoid clobbering a
            # file another path (FTP) creates during the download window.
            log.info("Downloading %s", filename)
            downloaded = 0
            async with client.stream("GET", download_url, timeout=300) as stream:
                # On a streaming response, raise_for_status() can't include the
                # body unless we read it first — otherwise httpx throws a confusing
                # "Attempted to access streaming response content" error instead of
                # a clean HTTPStatusError. Read the body on non-2xx so the proper
                # except httpx.HTTPStatusError handler catches it (e.g. a 403 on a
                # stale/ghost pre-signed URL during reconciliation).
                if stream.status_code >= 400:
                    await stream.aread()
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
                return "size_mismatch"
            if expected_size:
                log.info("Size verified for %s (%d bytes)", filename, downloaded)
            else:
                log.info("No size in metadata for %s — skipping size check", filename)

            # Publish: resolve the final name NOW (not before the download). FTP or
            # another task may have created the same name during the multi-second
            # download window. The exists()→replace() window here is microseconds,
            # and the sorter's xxhash dedup is the backstop for a true simultaneous
            # collision. replace() (rename) fires inotify moved_to → instant pickup.
            stem, ext = Path(filename).stem, Path(filename).suffix
            dest = incoming_dir / filename
            n = 2
            while dest.exists():
                dest = incoming_dir / f"{stem}_{n}{ext}"
                n += 1
                if n > 100:
                    log.error("Too many incoming/ collisions for %s — leaving tmp", filename)
                    return "collision_overflow"
            if dest.name != filename:
                log.warning("Filename collision in incoming/: %s -> %s", filename, dest.name)
            tmp.replace(dest)  # rename → sorter sees moved_to
            log.info("Published %s", dest.name)

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
            return "ok"

        except httpx.HTTPStatusError as exc:
            sc = exc.response.status_code
            safe_url = _redact_url(exc.request.url)  # strip pre-signed AWS creds in query
            log.error(
                "HTTP error processing asset %s: %s %s (%s)",
                asset_id, sc, exc.response.text[:200], safe_url,
            )
            await notify_failure(
                f"http_{sc}",
                f"Asset {asset_id[:8]}…: HTTP {sc} from {safe_url}\n{exc.response.text[:300]}",
                throttle_minutes=15,
            )
            return f"http_{sc}"
        except Exception as exc:
            log.error("Unexpected error processing asset %s: %s", asset_id, exc, exc_info=True)
            await notify_failure(
                "asset_exception",
                f"Asset {asset_id[:8]}…: {type(exc).__name__}: {str(exc)[:300]}",
                throttle_minutes=15,
            )
            return "error"
            await notify_failure(
                "asset_exception",
                f"Asset {asset_id[:8]}…: {type(exc).__name__}: {exc}",
                throttle_minutes=15,
            )
