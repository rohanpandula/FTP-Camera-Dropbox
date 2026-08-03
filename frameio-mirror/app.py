"""
frameio-mirror: FastAPI webhook receiver for Frame.io Camera-to-Cloud assets.

Receives Frame.io V4 webhooks and downloads each asset to incoming/. Optional
upstream deletion is disabled by default and requires an exact API size match.

Config priority: env vars override /etc/frameio.json values.
"""

import asyncio
import ctypes
import errno
import fcntl
import hashlib
import hmac
import html
import json
import logging
import os
import re
import secrets
import stat
import time
from contextlib import asynccontextmanager
from pathlib import Path
from urllib.parse import urlencode, urljoin, urlsplit

import httpx
from fastapi import BackgroundTasks, FastAPI, Header, HTTPException, Request
from fastapi.responses import HTMLResponse, JSONResponse


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
# Request URLs can contain credentials in their path (notably Telegram bot
# tokens), so transport libraries must never inherit the application's INFO
# level. Application-owned logs record the useful outcome without the secret.
logging.getLogger("httpx").setLevel(logging.WARNING)
logging.getLogger("httpcore").setLevel(logging.WARNING)
log = logging.getLogger("frameio-mirror")

# Group-writable output so downloaded files land as nobody:users 664 and are
# deletable over SMB (paired with running the container as 99:100).
os.umask(0o002)

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------
_CONFIG_FILE = Path("/etc/frameio.json")


def _strict_bool(value, name: str) -> bool:
    if isinstance(value, bool):
        return value
    normalized = str(value).strip().lower()
    if normalized in ("1", "true", "yes", "on"):
        return True
    if normalized in ("0", "false", "no", "off"):
        return False
    raise ValueError(f"{name} must be one of 0/1, true/false, yes/no, on/off")


def _bounded_int(value, name: str, minimum: int, maximum: int) -> int:
    try:
        parsed = int(str(value), 10)
    except (TypeError, ValueError) as exc:
        raise ValueError(f"{name} must be an integer") from exc
    if not minimum <= parsed <= maximum:
        raise ValueError(f"{name} must be between {minimum} and {maximum}")
    return parsed

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
        # Shared secret gating the POST-only /oauth/start enrollment endpoint.
        # It is sent in X-Setup-Secret so it never enters URL/access logs.
        "oauth_setup_secret": _get("OAUTH_SETUP_SECRET", "oauth_setup_secret", ""),
        # Reject webhook bodies larger than this (Frame.io payloads are tiny JSON).
        "webhook_max_bytes": _bounded_int(
            _get("WEBHOOK_MAX_BYTES", "webhook_max_bytes", "1000000"),
            "WEBHOOK_MAX_BYTES",
            1,
            10_000_000,
        ),
        # Deletion is deliberately opt-in. The mirror proves size equality and
        # re-hashes the pinned hidden bytes immediately before deletion; full
        # media validation remains the sorter's asynchronous responsibility.
        "delete_upstream": _strict_bool(
            _get("DELETE_UPSTREAM", "delete_upstream", "0"),
            "DELETE_UPSTREAM",
        ),
        "refresh_token_file": os.environ.get(
            "REFRESH_TOKEN_FILE", "/etc/frameio-oauth-state.json"
        ),
        # Durable bytes live on the private state mount until the sorter handoff
        # is complete. This must be a different container mount from /data.
        "staging_dir": os.environ.get(
            "STAGING_DIR", "/var/lib/frameio/staging"
        ),
        # Reconciliation: env vars override; otherwise auto-discovered from
        # first file.ready webhook and persisted to the state file.
        "c2c_folder_id": _get("FRAMEIO_C2C_FOLDER_ID", "c2c_folder_id"),
        "c2c_account_id": _get("FRAMEIO_C2C_ACCOUNT_ID", "c2c_account_id"),
        "reconcile_interval_seconds": _bounded_int(
            _get("RECONCILE_INTERVAL_SECONDS", "reconcile_interval_seconds", "900"),
            "RECONCILE_INTERVAL_SECONDS",
            60,
            86_400,
        ),
        "reconcile_max_pages": _bounded_int(
            _get("RECONCILE_MAX_PAGES", "reconcile_max_pages", "1000"),
            "RECONCILE_MAX_PAGES",
            1,
            10_000,
        ),
        "reconcile_max_items": _bounded_int(
            _get("RECONCILE_MAX_ITEMS", "reconcile_max_items", "100000"),
            "RECONCILE_MAX_ITEMS",
            1,
            1_000_000,
        ),
        "reconcile_max_seconds": _bounded_int(
            _get("RECONCILE_MAX_SECONDS", "reconcile_max_seconds", "300"),
            "RECONCILE_MAX_SECONDS",
            1,
            3_600,
        ),
        "frameio_workers": _bounded_int(
            _get("FRAMEIO_WORKERS", "frameio_workers", "4"),
            "FRAMEIO_WORKERS",
            1,
            64,
        ),
        "frameio_queue_size": _bounded_int(
            _get("FRAMEIO_QUEUE_SIZE", "frameio_queue_size", "256"),
            "FRAMEIO_QUEUE_SIZE",
            1,
            10_000,
        ),
        "download_tmp_stale_seconds": _bounded_int(
            _get("DOWNLOAD_TMP_STALE_SECONDS", "download_tmp_stale_seconds", "3600"),
            "DOWNLOAD_TMP_STALE_SECONDS",
            300,
            604_800,
        ),
        "download_max_bytes": _bounded_int(
            _get("DOWNLOAD_MAX_BYTES", "download_max_bytes", "21474836480"),
            "DOWNLOAD_MAX_BYTES",
            1_048_576,
            1_099_511_627_776,
        ),
        "download_max_seconds": _bounded_int(
            _get("DOWNLOAD_MAX_SECONDS", "download_max_seconds", "1800"),
            "DOWNLOAD_MAX_SECONDS",
            30,
            86_400,
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
_REFRESH_TOKEN_MEMORY: str | None = None
_REFRESH_TOKEN_PERSIST_ERROR = False

IMS_TOKEN_URL = "https://ims-na1.adobelogin.com/ims/token/v3"
IMS_AUTHORIZE_URL = "https://ims-na1.adobelogin.com/ims/authorize/v2"


def _state_path_parts() -> tuple[Path, Path, str]:
    path = Path(CFG["refresh_token_file"])
    raw = str(path)
    if (
        not path.is_absolute()
        or raw != os.path.normpath(raw)
        or path.name in ("", ".", "..")
        or len(os.fsencode(path.name)) > 240
    ):
        raise OSError(errno.EINVAL, "unsafe state path", raw)
    return path, path.parent, path.name


def _state_parent_path_is_canonical(parent: Path) -> bool:
    return os.path.realpath(parent) == str(parent)


def _open_state_parent() -> tuple[int, os.stat_result, str]:
    """Pin a state parent inaccessible to actors on the shared data mount."""
    path, parent, leaf = _state_path_parts()
    if not _state_parent_path_is_canonical(parent):
        raise OSError(errno.EPERM, "state parent contains a symlink", str(parent))
    flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC
    parent_fd = os.open(parent, flags)
    incoming_fd: int | None = None
    try:
        expected = os.fstat(parent_fd)
        current = os.stat(parent, follow_symlinks=False)
        owned_private = (
            expected.st_uid == os.geteuid() and not expected.st_mode & 0o077
        )
        root_protected = expected.st_uid == 0 and not expected.st_mode & 0o022
        if (
            not stat.S_ISDIR(expected.st_mode)
            or not _same_directory(current, expected)
            or not (owned_private or root_protected)
        ):
            raise OSError(
                errno.EPERM,
                "state parent must be private-owned or root-protected",
                str(parent),
            )
        incoming_fd, _expected_incoming = _open_incoming_dir(
            Path(CFG["incoming_dir"])
        )
        _require_private_staging_mount(
            parent_fd, incoming_fd, label="REFRESH_TOKEN_FILE parent"
        )
        return parent_fd, expected, leaf
    except Exception:
        os.close(parent_fd)
        raise
    finally:
        if incoming_fd is not None:
            os.close(incoming_fd)


def _state_parent_is_canonical(
    parent_fd: int, expected: os.stat_result
) -> bool:
    try:
        _path, parent, _leaf = _state_path_parts()
        current = os.stat(parent, follow_symlinks=False)
        pinned = os.fstat(parent_fd)
    except OSError:
        return False
    owned_private = pinned.st_uid == os.geteuid() and not pinned.st_mode & 0o077
    root_protected = pinned.st_uid == 0 and not pinned.st_mode & 0o022
    return (
        _state_parent_path_is_canonical(parent)
        and _same_directory(current, expected)
        and _same_directory(pinned, expected)
        and (owned_private or root_protected)
    )


def _load_state(*, strict: bool = False) -> dict:
    """Read the writable state JSON.

    Contains refresh_token plus any auto-discovered settings (c2c_folder_id,
    c2c_account_id) persisted across container restarts.
    """
    path = Path(CFG["refresh_token_file"])
    parent_fd: int | None = None
    fd: int | None = None
    try:
        parent_fd, expected_parent, leaf = _open_state_parent()
        try:
            fd = os.open(
                leaf,
                os.O_RDONLY | os.O_NONBLOCK | os.O_NOFOLLOW | os.O_CLOEXEC,
                dir_fd=parent_fd,
            )
        except FileNotFoundError:
            return {}
        node = os.fstat(fd)
        if (
            not stat.S_ISREG(node.st_mode)
            or node.st_nlink != 1
            or node.st_uid != os.geteuid()
            or node.st_mode & 0o077
            or node.st_size > 1_000_000
        ):
            raise ValueError("state must be a private, owned, single-link regular file")
        chunks: list[bytes] = []
        remaining = node.st_size + 1
        while remaining > 0:
            chunk = os.read(fd, min(remaining, 65536))
            if not chunk:
                break
            chunks.append(chunk)
            remaining -= len(chunk)
        raw = b"".join(chunks)
        if len(raw) > 1_000_000:
            raise ValueError("state exceeds 1 MB")
        path_node = os.stat(leaf, dir_fd=parent_fd, follow_symlinks=False)
        if (
            not _same_inode(path_node, node)
            or not _state_parent_is_canonical(parent_fd, expected_parent)
        ):
            raise OSError(errno.EPERM, "state path changed during read", str(path))
        parsed = json.loads(raw.decode("utf-8"))
        if not isinstance(parsed, dict):
            raise ValueError("state JSON root must be an object")
        return parsed
    except FileNotFoundError:
        return {}
    except Exception as exc:
        if strict:
            raise
        log.warning("Failed to read state file %s: %s", path, exc)
        return {}
    finally:
        if fd is not None:
            os.close(fd)
        if parent_fd is not None:
            os.close(parent_fd)


def _save_state(updates: dict, *, base_state: dict | None = None) -> None:
    """Merge and durably save private state, with a legacy bind-file fallback."""
    path, _parent, _leaf = _state_path_parts()
    # Never turn a read/I/O/JSON error into an empty authoritative state: doing
    # so could erase the refresh token and durable retry/publication receipts.
    state = _load_state(strict=True) if base_state is None else dict(base_state)
    state.update(updates)
    payload = json.dumps(state, separators=(",", ":")).encode("utf-8")
    if len(payload) > 1_000_000:
        raise ValueError("state exceeds 1 MB")
    parent_fd, expected_parent, leaf = _open_state_parent()

    def write_legacy_bind_file() -> None:
        target_fd = os.open(
            leaf,
            os.O_WRONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC,
            dir_fd=parent_fd,
        )
        try:
            target_node = os.fstat(target_fd)
            path_node = os.stat(
                leaf, dir_fd=parent_fd, follow_symlinks=False
            )
            if (
                not stat.S_ISREG(target_node.st_mode)
                or not _same_inode(path_node, target_node)
                or target_node.st_nlink != 1
                or target_node.st_uid != os.geteuid()
                or target_node.st_mode & 0o077
                or not _state_parent_is_canonical(parent_fd, expected_parent)
            ):
                raise OSError(errno.EPERM, "state bind target is not private and owned")
            os.ftruncate(target_fd, 0)
            target_view = memoryview(payload)
            while target_view:
                written = os.write(target_fd, target_view)
                target_view = target_view[written:]
            os.fchmod(target_fd, 0o600)
            os.fsync(target_fd)
            os.fsync(parent_fd)
        finally:
            os.close(target_fd)

    temp_fd = -1
    temp_name: str | None = None
    try:
        for _ in range(100):
            temp_name = f".{leaf}.{secrets.token_hex(8)}"
            try:
                temp_fd = os.open(
                    temp_name,
                    os.O_RDWR
                    | os.O_CREAT
                    | os.O_EXCL
                    | os.O_NOFOLLOW
                    | os.O_CLOEXEC,
                    0o600,
                    dir_fd=parent_fd,
                )
                break
            except FileExistsError:
                continue
            except OSError as exc:
                if exc.errno not in (errno.EACCES, errno.EROFS):
                    raise
                write_legacy_bind_file()
                return
        if temp_fd < 0 or temp_name is None:
            raise FileExistsError("could not allocate private state temp")
        os.fchmod(temp_fd, 0o600)
        view = memoryview(payload)
        while view:
            written = os.write(temp_fd, view)
            view = view[written:]
        os.fsync(temp_fd)
        os.close(temp_fd)
        temp_fd = -1
        if not _state_parent_is_canonical(parent_fd, expected_parent):
            raise OSError(errno.EPERM, "state parent changed before replace")
        try:
            os.replace(
                temp_name,
                leaf,
                src_dir_fd=parent_fd,
                dst_dir_fd=parent_fd,
            )
        except OSError as exc:
            if exc.errno != errno.EBUSY:
                raise
            # Docker single-file bind mounts cannot be replaced (EBUSY). Keep
            # compatibility, but open the pinned regular target without
            # symlink-following and fsync the in-place fallback.
            write_legacy_bind_file()
            os.unlink(temp_name, dir_fd=parent_fd)
            temp_name = None
        if not _state_parent_is_canonical(parent_fd, expected_parent):
            raise OSError(errno.EPERM, "state parent changed after replace")
        os.fsync(parent_fd)
    finally:
        if temp_fd >= 0:
            os.close(temp_fd)
        if temp_name is not None:
            try:
                os.unlink(temp_name, dir_fd=parent_fd)
            except FileNotFoundError:
                pass
        os.close(parent_fd)


def _load_refresh_token(*, strict: bool = False) -> str | None:
    token = _load_state(strict=strict).get("refresh_token")
    if token is None:
        return None
    if not isinstance(token, str) or not token:
        if strict:
            raise ValueError("refresh_token state must be a non-empty string")
        return None
    return token


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


async def _remember_c2c_folder(parent_folder: str | None, account_id: str) -> None:
    """Remember reconciliation identifiers without blocking this download."""
    if not parent_folder:
        return
    state = _load_state()
    current_folder = CFG["c2c_folder_id"] or state.get("c2c_folder_id")
    current_account = CFG["c2c_account_id"] or state.get("c2c_account_id")
    updates: dict[str, str] = {}
    if not current_folder:
        updates["c2c_folder_id"] = parent_folder
        CFG["c2c_folder_id"] = parent_folder
    if not current_account:
        updates["c2c_account_id"] = account_id
        CFG["c2c_account_id"] = account_id
    if not updates:
        return
    try:
        _save_state(updates)
    except Exception as exc:
        log.warning(
            "Could not persist C2C reconciliation state (%s); continuing this download",
            exc,
        )
        await notify_failure(
            "state_persist",
            "C2C folder/account IDs could not be saved. This download continues, "
            "but missed-webhook reconciliation will not survive a restart.",
            throttle_minutes=60,
        )
        return
    log.info(
        "Discovered C2C ingest folder: %s (account=%s) — reconciliation enabled",
        CFG["c2c_folder_id"] or current_folder,
        CFG["c2c_account_id"] or current_account,
    )


FRAMEIO_API = "https://api.frame.io/v4"
_REFRESH_BEFORE_EXPIRY = 300  # seconds

# Per-asset in-flight set — prevents a webhook and a reconcile sweep from
# both downloading the same file concurrently (which would corrupt the .tmp).
_IN_FLIGHT: set[str] = set()
_IN_FLIGHT_LOCK = asyncio.Lock()
_PROCESS_SEMAPHORE = asyncio.Semaphore(CFG["frameio_workers"])
_JOB_QUEUE: asyncio.Queue[tuple[str, str]] = asyncio.Queue(
    maxsize=CFG["frameio_queue_size"]
)
_QUEUED_ASSETS: set[str] = set()
_QUEUE_LOCK = asyncio.Lock()
_PENDING_DOWNLOADS: dict[str, str] = {}
_PENDING_DELETES: dict[str, str] = {}
_RETAINED_ASSETS: set[str] = set()
_COMPLETED_DELETES: dict[str, int] = {}
_RECONCILE_ROTATION = 0


async def _enqueue_asset_job(account_id: str, asset_id: str) -> bool:
    """Queue bounded in-process work; durable state remains the overflow queue."""
    async with _QUEUE_LOCK:
        if asset_id in _QUEUED_ASSETS or asset_id in _IN_FLIGHT:
            return True
        try:
            _JOB_QUEUE.put_nowait((account_id, asset_id))
        except asyncio.QueueFull:
            return False
        _QUEUED_ASSETS.add(asset_id)
        return True


async def _asset_worker(worker_number: int) -> None:
    while True:
        account_id, asset_id = await _JOB_QUEUE.get()
        try:
            await process_asset(account_id, asset_id)
        except asyncio.CancelledError:
            raise
        except Exception:
            log.exception("Frame.io worker %d failed asset %s", worker_number, asset_id)
        finally:
            async with _QUEUE_LOCK:
                _QUEUED_ASSETS.discard(asset_id)
            _JOB_QUEUE.task_done()


def _pending_downloads(*, strict: bool = False) -> dict[str, str]:
    persisted = _load_state(strict=strict).get("pending_downloads", {})
    merged: dict[str, str] = {}
    if not isinstance(persisted, dict):
        if strict:
            raise ValueError("pending_downloads state must be an object")
    else:
        for asset_id, account_id in persisted.items():
            valid = (
                isinstance(asset_id, str)
                and bool(asset_id)
                and len(asset_id) <= 200
                and isinstance(account_id, str)
                and bool(account_id)
                and len(account_id) <= 200
            )
            if not valid:
                if strict:
                    raise ValueError("pending_downloads entries are invalid")
                continue
            merged[asset_id] = account_id
    merged.update(_PENDING_DOWNLOADS)
    return merged


def _save_pending_download(asset_id: str, account_id: str) -> None:
    """Durably record work before acknowledging the public webhook."""
    _PENDING_DOWNLOADS[asset_id] = account_id
    try:
        state = _load_state(strict=True)
        persisted = state.get("pending_downloads", {})
        if not isinstance(persisted, dict):
            raise ValueError("pending_downloads state must be an object")
        pending = dict(persisted)
        pending.update(_PENDING_DOWNLOADS)
        _save_state({"pending_downloads": pending}, base_state=state)
    except Exception:
        _PENDING_DOWNLOADS.pop(asset_id, None)
        raise


async def _clear_pending_download(asset_id: str) -> None:
    _PENDING_DOWNLOADS.pop(asset_id, None)
    try:
        state = _load_state(strict=True)
        persisted = state.get("pending_downloads", {})
        if not isinstance(persisted, dict):
            raise ValueError("pending_downloads state must be an object")
        pending = dict(persisted)
        pending.update(_PENDING_DOWNLOADS)
        pending.pop(asset_id, None)
        _save_state({"pending_downloads": pending}, base_state=state)
    except Exception as exc:
        # A stale job is safe: retained/pending-delete receipts prevent a second
        # local download, and a 404 upstream delete is idempotent.
        log.warning("Could not clear pending download %s: %s", asset_id, exc)


def _pending_deletes(*, strict: bool = False) -> dict[str, str]:
    persisted = _load_state(strict=strict).get("pending_deletes", {})
    merged: dict[str, str] = {}
    if not isinstance(persisted, dict):
        if strict:
            raise ValueError("pending_deletes state must be an object")
    else:
        for asset_id, account_id in persisted.items():
            valid = (
                isinstance(asset_id, str)
                and bool(asset_id)
                and len(asset_id) <= 200
                and isinstance(account_id, str)
                and bool(account_id)
                and len(account_id) <= 200
            )
            if not valid:
                if strict:
                    raise ValueError("pending_deletes entries are invalid")
                continue
            merged[asset_id] = account_id
    merged.update(_PENDING_DELETES)
    return merged


async def _clear_pending_delete(asset_id: str) -> None:
    _PENDING_DELETES.pop(asset_id, None)
    try:
        state = _load_state(strict=True)
        persisted = state.get("pending_deletes", {})
        if not isinstance(persisted, dict):
            raise ValueError("pending_deletes state must be an object")
        pending = dict(persisted)
        pending.update(_PENDING_DELETES)
        pending.pop(asset_id, None)
        _save_state({"pending_deletes": pending}, base_state=state)
    except Exception as exc:
        log.warning("Could not clear legacy pending-delete state for %s: %s", asset_id, exc)


def _completed_deletes(*, strict: bool = False) -> dict[str, int]:
    persisted = _load_state(strict=strict).get("completed_deletes", {})
    if not isinstance(persisted, dict):
        if strict:
            raise ValueError("completed_deletes state must be an object")
        persisted = {}
    completed: dict[str, int] = {}
    for asset_id, timestamp in persisted.items():
        if (
            not isinstance(asset_id, str)
            or not asset_id
            or len(asset_id) > 200
            or not isinstance(timestamp, int)
            or isinstance(timestamp, bool)
            or timestamp <= 0
        ):
            if strict:
                raise ValueError("completed_deletes entries are invalid")
            continue
        completed[asset_id] = timestamp
    completed.update(_COMPLETED_DELETES)
    return completed


def _retained_assets(*, strict: bool = False) -> set[str]:
    """Assets intentionally left upstream after a successful local publish."""
    persisted = _load_state(strict=strict).get("retained_assets", [])
    merged = set(_RETAINED_ASSETS)
    if not isinstance(persisted, list):
        if strict:
            raise ValueError("retained_assets state must be an array")
    else:
        for asset_id in persisted:
            if (
                not isinstance(asset_id, str)
                or not asset_id
                or len(asset_id) > 200
            ):
                if strict:
                    raise ValueError("retained_assets entries are invalid")
                continue
            merged.add(asset_id)
    return merged


def _retained_asset_is_durable(asset_id: str, *, strict: bool = False) -> bool:
    persisted = _load_state(strict=strict).get("retained_assets", [])
    if not isinstance(persisted, list):
        if strict:
            raise ValueError("retained_assets state must be an array")
        return False
    return asset_id in persisted


async def _save_retained_asset(asset_id: str) -> bool:
    _RETAINED_ASSETS.add(asset_id)
    try:
        state = _load_state(strict=True)
    except Exception as exc:
        log.warning("Could not read state before retaining asset %s: %s", asset_id, exc)
        return False
    persisted = state.get("retained_assets", [])
    if not isinstance(persisted, list):
        log.warning("retained_assets state is not an array; refusing to overwrite it")
        return False
    retained_set = set(_RETAINED_ASSETS)
    retained_set.update(str(item) for item in persisted if item)
    retained = sorted(retained_set)
    # A normal Frame.io folder is far smaller (and free accounts are quota
    # limited), but keep corrupted/hostile API data from exhausting state.
    if len(retained) > 10_000:
        log.error("Retained-asset receipt limit reached; keeping retry job durable")
        await notify_failure(
            "state_capacity",
            "Frame.io retained-asset state reached 10,000 entries. No upstream "
            "asset was deleted; manually clean the ingest folder/state.",
            throttle_minutes=1440,
        )
        return False
    try:
        _save_state({"retained_assets": retained}, base_state=state)
        return True
    except Exception as exc:
        log.warning("Could not persist retained asset %s: %s", asset_id, exc)
        await notify_failure(
            "state_persist",
            "A locally mirrored asset's retention receipt could not be saved. "
            "The in-memory receipt remains active until restart.",
            throttle_minutes=60,
        )
        return False


async def _prune_retained_assets(visible_assets: set[str], listing_complete: bool) -> None:
    """Drop receipts only when a complete folder walk proves upstream is gone."""
    if not listing_complete:
        return
    try:
        state = _load_state(strict=True)
    except Exception as exc:
        log.warning("Could not read state before pruning retained assets: %s", exc)
        return
    persisted = state.get("retained_assets", [])
    if not isinstance(persisted, list):
        log.warning("retained_assets state is not an array; refusing to prune it")
        return
    retained = set(_RETAINED_ASSETS)
    retained.update(str(item) for item in persisted if item)
    try:
        active_publications = set(_pending_publications(strict=True))
    except Exception as exc:
        log.warning("Could not validate publication journal before pruning: %s", exc)
        return
    pruned = retained.intersection(visible_assets | active_publications)
    if pruned == retained:
        return
    _RETAINED_ASSETS.clear()
    _RETAINED_ASSETS.update(pruned)
    try:
        _save_state({"retained_assets": sorted(pruned)}, base_state=state)
    except Exception as exc:
        log.warning("Could not prune retained-asset receipts: %s", exc)


async def _fd_to_thread(func, *args, cancel_cleanup=None, **kwargs):
    """Join descriptor-owning thread work before propagating cancellation.

    Cancelling `asyncio.to_thread` does not stop its OS thread. Callers normally
    close their descriptors in `finally`, so an ordinary cancelled await could
    let that thread write through a closed/reused fd. Shield and join it first.
    """
    operation = asyncio.create_task(asyncio.to_thread(func, *args, **kwargs))
    try:
        return await asyncio.shield(operation)
    except asyncio.CancelledError as cancelled:
        while not operation.done():
            try:
                await asyncio.shield(operation)
            except asyncio.CancelledError:
                continue
        try:
            result = operation.result()
        except Exception as exc:
            log.warning(
                "Descriptor operation failed while cancellation was pending: %s",
                exc,
            )
        else:
            if cancel_cleanup is not None:
                try:
                    cancel_cleanup(result)
                except Exception as exc:
                    log.warning(
                        "Descriptor cancellation cleanup failed: %s", exc
                    )
        raise cancelled


async def _delete_upstream(
    client: httpx.AsyncClient, account_id: str, asset_id: str, local_guard=None
) -> bool | None:
    file_url = f"{FRAMEIO_API}/accounts/{account_id}/files/{asset_id}"
    try:
        token = await get_token(client)
        if local_guard is not None and not await _fd_to_thread(local_guard):
            log.error("Hidden local bytes changed before upstream delete")
            await notify_failure(
                "local_validation_failed",
                "A downloaded asset failed its pinned size/SHA-256 validation "
                "immediately before Frame.io deletion. Upstream was preserved.",
                throttle_minutes=15,
            )
            return None
        response = await client.delete(
            file_url,
            headers={"Authorization": f"Bearer {token}"},
            timeout=30,
        )
    except Exception as exc:
        log.error("Failed to delete asset %s: %s", asset_id, exc)
        await notify_failure(
            "delete_failed",
            f"Asset {asset_id[:8]}… is downloaded locally but its upstream delete failed: "
            f"{type(exc).__name__}. Reconciliation will retry without downloading again.",
            throttle_minutes=15,
        )
        return False
    if response.status_code in (200, 204, 404):
        log.info("Asset %s deleted from Frame.io", asset_id)
        return True
    log.error(
        "Failed to delete asset %s: HTTP %d %s",
        asset_id,
        response.status_code,
        response.text[:200],
    )
    await notify_failure(
        "delete_failed",
        f"Asset {asset_id[:8]}… is downloaded locally but Frame.io delete returned "
        f"HTTP {response.status_code}. Reconciliation will retry without downloading again.",
        throttle_minutes=15,
    )
    return False


async def _fetch_token(client: httpx.AsyncClient) -> str:
    """Get an Adobe IMS Bearer token.

    Two grant types supported:
    - refresh_token (OAuth Web App, after one-time browser auth via /oauth/start)
    - client_credentials (S2S; only works on Enterprise Adobe orgs)
    """
    global _REFRESH_TOKEN_MEMORY, _REFRESH_TOKEN_PERSIST_ERROR
    refresh_token = _REFRESH_TOKEN_MEMORY or _load_refresh_token(strict=True)
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
    if not isinstance(body, dict):
        raise ValueError("IMS token response must be an object")
    token = body.get("access_token")
    if not isinstance(token, str) or not token:
        raise ValueError("IMS token response lacks a valid access_token")
    expires_raw = body.get("expires_in", 3600)
    if (
        not isinstance(expires_raw, int)
        or isinstance(expires_raw, bool)
        or not 1 <= expires_raw <= 604_800
    ):
        raise ValueError("IMS token response has an invalid expires_in")
    expires_in = expires_raw

    # Cache the valid access token before any fallible disk persistence. IMS
    # may invalidate the old refresh token as soon as it rotates, so a full or
    # temporarily unavailable state mount must not discard current auth too.
    _TOKEN_CACHE["token"] = token
    _TOKEN_CACHE["expires_at"] = time.monotonic() + expires_in
    rotated = body.get("refresh_token")
    rotated_invalid = rotated is not None and (
        not isinstance(rotated, str) or not rotated
    )
    if rotated_invalid:
        _REFRESH_TOKEN_PERSIST_ERROR = True
        await notify_failure(
            "refresh_token_invalid",
            "Adobe returned an invalid rotated refresh token. The current access "
            "token remains usable, but durable authentication needs attention.",
            throttle_minutes=60,
        )
    elif isinstance(rotated, str):
        _REFRESH_TOKEN_MEMORY = rotated
    if (
        not _REFRESH_TOKEN_PERSIST_ERROR
        and isinstance(rotated, str)
        and rotated != refresh_token
    ):
        # Force the persistence attempt for a newly rotated credential.
        _REFRESH_TOKEN_PERSIST_ERROR = True
    if (
        not rotated_invalid
        and _REFRESH_TOKEN_MEMORY
        and _REFRESH_TOKEN_PERSIST_ERROR
    ):
        try:
            _save_refresh_token(_REFRESH_TOKEN_MEMORY)
        except Exception as exc:
            _REFRESH_TOKEN_PERSIST_ERROR = True
            log.error("Could not persist rotated refresh token: %s", exc)
            await notify_failure(
                "refresh_token_persist",
                "Adobe rotated the refresh token, but private state persistence "
                "failed. The current credentials remain in memory; fix the state "
                "volume before this container restarts.",
                throttle_minutes=15,
            )
        else:
            _REFRESH_TOKEN_PERSIST_ERROR = False
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
def _validated_next_page_url(current_url: str, next_link: str, endpoint: str) -> str:
    """Resolve pagination without leaking the bearer token off api.frame.io."""
    candidate = urljoin(current_url, next_link)
    parsed = urlsplit(candidate)
    expected = urlsplit(endpoint)
    if (
        parsed.scheme != "https"
        or parsed.netloc != "api.frame.io"
        or parsed.username is not None
        or parsed.password is not None
        or parsed.fragment
        or parsed.path != expected.path
    ):
        raise ValueError("unsafe Frame.io pagination link")
    return candidate


def _parse_listing_page(body) -> tuple[list[str], str | None, int]:
    """Validate a complete Frame.io listing page before trusting exhaustion."""
    if not isinstance(body, dict):
        raise ValueError("listing response must be an object")
    data = body.get("data")
    if not isinstance(data, list):
        raise ValueError("listing data must be an array")
    if "links" in body:
        links = body["links"]
        if not isinstance(links, dict):
            raise ValueError("listing links must be an object")
    else:
        links = {}
    next_link = links.get("next")
    if next_link is not None and (
        not isinstance(next_link, str) or not next_link.strip()
    ):
        raise ValueError("listing next link must be a non-empty string or null")

    asset_ids: list[str] = []
    for item in data:
        if not isinstance(item, dict):
            raise ValueError("listing items must be objects")
        if item.get("type") != "file":
            continue
        asset_id = item.get("id")
        if not isinstance(asset_id, str) or not asset_id or len(asset_id) > 200:
            raise ValueError("listing file item has an invalid id")
        asset_ids.append(asset_id)
    return asset_ids, next_link, len(data)


def _load_reconcile_cursor(
    account_id: str, folder_id: str, endpoint: str
) -> str | None:
    cursor = _load_state(strict=True).get("reconcile_cursor", {})
    if cursor in ({}, None):
        return None
    if not isinstance(cursor, dict):
        raise ValueError("reconcile_cursor state must be an object")
    if cursor.get("account_id") != account_id or cursor.get("folder_id") != folder_id:
        return None
    url = cursor.get("url")
    if not isinstance(url, str) or not url:
        raise ValueError("reconcile_cursor URL is invalid")
    return _validated_next_page_url(endpoint, url, endpoint)


def _save_reconcile_cursor(
    url: str | None, account_id: str, folder_id: str
) -> None:
    state = _load_state(strict=True)
    value = (
        {"url": url, "account_id": account_id, "folder_id": folder_id}
        if url
        else {}
    )
    _save_state({"reconcile_cursor": value}, base_state=state)


async def _process_reconcile_jobs(jobs: list[tuple[str, str]]) -> int:
    """Admit one fair batch to fixed workers without blocking the next sweep."""
    global _RECONCILE_ROTATION
    deduplicated: dict[str, str] = {}
    for asset_id, account_id in jobs:
        deduplicated.setdefault(asset_id, account_id)
    ordered = list(deduplicated.items())
    async with _QUEUE_LOCK:
        # Reconciliation may fill only one worker-width of the shared admission
        # set. Webhooks can still queue behind running jobs, while later sweeps
        # never build an ever-growing reconcile backlog.
        limit = max(0, CFG["frameio_workers"] - len(_QUEUED_ASSETS))
    limit = min(limit, CFG["frameio_queue_size"])
    if ordered:
        start = _RECONCILE_ROTATION % len(ordered)
        rotated = ordered[start:] + ordered[:start]
        batch = rotated[:limit]
        _RECONCILE_ROTATION = (start + len(batch)) % len(ordered)
    else:
        batch = []
    if len(deduplicated) > len(batch):
        log.warning(
            "Reconcile admission budget reached: queueing %d of %d asset(s)",
            len(batch),
            len(deduplicated),
        )
    admitted = 0
    for asset_id, account_id in batch:
        if await _enqueue_asset_job(account_id, asset_id):
            admitted += 1
    return admitted


async def reconcile_once() -> int:
    """Walk the C2C folder and queue orphan files. Returns count admitted."""
    if not (CFG["adobe_client_id"] and CFG["adobe_client_secret"]):
        return 0

    # Snapshot durable jobs first, but list before running them when discovery
    # exists. This prevents a large/slow retry set from permanently starving the
    # folder sweep that finds webhook delivery gaps.
    pending_snapshot = _pending_downloads(strict=True)
    for publication_id, publication in _pending_publications(strict=True).items():
        pending_snapshot.setdefault(publication_id, publication["account_id"])

    folder_id = CFG["c2c_folder_id"] or _load_state().get("c2c_folder_id")
    account_id = CFG["c2c_account_id"] or _load_state().get("c2c_account_id")
    if not (folder_id and account_id):
        log.debug("Reconcile listing skipped — no folder_id discovered yet")
        return await _process_reconcile_jobs(list(pending_snapshot.items()))

    orphans: list[str] = []
    listing_complete = False
    try:
        async with httpx.AsyncClient(follow_redirects=True) as client:
            token = await get_token(client)
            auth = {"Authorization": f"Bearer {token}"}
            endpoint = (
                f"{FRAMEIO_API}/accounts/{account_id}/folders/{folder_id}/files"
            )
            resumed = False
            try:
                cursor_url = _load_reconcile_cursor(account_id, folder_id, endpoint)
            except Exception as exc:
                log.error("Reconcile: invalid persisted cursor: %s", exc)
                await notify_failure(
                    "reconcile_cursor_invalid",
                    "The saved Frame.io pagination cursor is invalid. Starting a "
                    "safe full sweep without pruning receipts.",
                    throttle_minutes=60,
                )
                cursor_url = None
            if cursor_url:
                url = cursor_url
                params: dict | None = None
                resumed = True
            else:
                url = endpoint
                params = {"page_size": 100}
            seen_page_urls = {url}
            pages_seen = 0
            items_seen = 0
            deadline = time.monotonic() + CFG["reconcile_max_seconds"]
            while True:
                resp = await client.get(url, params=params, headers=auth, timeout=30)
                if resp.status_code != 200:
                    if resumed and pages_seen == 0 and resp.status_code in (400, 404, 410):
                        log.warning(
                            "Reconcile cursor expired with HTTP %d; restarting from folder root",
                            resp.status_code,
                        )
                        _save_reconcile_cursor(None, account_id, folder_id)
                        url = endpoint
                        params = {"page_size": 100}
                        resumed = False
                        seen_page_urls = {endpoint}
                        continue
                    log.error(
                        "Reconcile: list failed HTTP %d %s",
                        resp.status_code,
                        resp.text[:200],
                    )
                    await notify_failure(
                        "reconcile_list_failed",
                        f"HTTP {resp.status_code} listing folder {folder_id[:8]}…: "
                        f"{resp.text[:200]}",
                        throttle_minutes=60,
                    )
                    break
                try:
                    page_assets, next_link, page_items = _parse_listing_page(resp.json())
                except (TypeError, ValueError, json.JSONDecodeError) as exc:
                    log.error("Reconcile: malformed listing page: %s", exc)
                    try:
                        _save_reconcile_cursor(url, account_id, folder_id)
                    except Exception:
                        log.exception("Could not preserve reconcile cursor after malformed page")
                    await notify_failure(
                        "reconcile_listing_invalid",
                        "Frame.io returned a malformed HTTP-200 folder listing. The "
                        "partial sweep was not used to prune receipts and this page will retry.",
                        throttle_minutes=60,
                    )
                    break
                orphans.extend(page_assets)
                pages_seen += 1
                items_seen += page_items
                if next_link is None:
                    listing_complete = not resumed
                    if resumed:
                        try:
                            _save_reconcile_cursor(None, account_id, folder_id)
                        except Exception:
                            log.exception("Could not clear completed reconcile cursor")
                    break
                try:
                    next_url = _validated_next_page_url(url, next_link, endpoint)
                except ValueError as exc:
                    log.error("Reconcile: %s", exc)
                    await notify_failure(
                        "reconcile_pagination_invalid",
                        "Frame.io returned an unsafe pagination link; processing only "
                        "the pages already fetched and preserving all receipts.",
                        throttle_minutes=60,
                    )
                    break
                if next_url in seen_page_urls:
                    log.error("Reconcile: pagination loop detected")
                    await notify_failure(
                        "reconcile_pagination_loop",
                        "Frame.io pagination repeated a page URL; processing the pages "
                        "already fetched and preserving all receipts.",
                        throttle_minutes=60,
                    )
                    break
                seen_page_urls.add(next_url)
                if (
                    pages_seen >= CFG["reconcile_max_pages"]
                    or items_seen >= CFG["reconcile_max_items"]
                    or time.monotonic() >= deadline
                ):
                    try:
                        _save_reconcile_cursor(next_url, account_id, folder_id)
                    except Exception:
                        log.exception("Could not persist bounded reconcile cursor")
                    log.warning(
                        "Reconcile budget reached after %d page(s)/%d item(s); "
                        "resuming next cycle",
                        pages_seen,
                        items_seen,
                    )
                    await notify_failure(
                        "reconcile_budget",
                        "The Frame.io folder exceeded one reconcile cycle's safety "
                        "budget. Progress was saved and the next cycle will resume "
                        "without pruning receipts.",
                        throttle_minutes=60,
                    )
                    break
                url = next_url
                params = None
    except Exception as exc:
        log.error("Reconcile listing failed: %s", exc)
        await notify_failure(
            "reconcile_list_failed",
            f"Frame.io folder listing raised {type(exc).__name__}; durable jobs will still retry.",
            throttle_minutes=60,
        )

    visible_assets = set(orphans)
    await _prune_retained_assets(visible_assets, listing_complete)

    # Filter out anything a webhook is already processing and assets deliberately
    # retained upstream after a successful local publish. HTTP 403/404 responses
    # are never permanently skip-listed: a stale pre-signed URL can recover on a
    # later independent sweep, and missing media is worse than a bounded retry.
    async with _IN_FLIGHT_LOCK:
        in_flight_snapshot = set(_IN_FLIGHT)
    already_mirrored = _retained_assets(strict=True)
    if not CFG["delete_upstream"]:
        # A pending-delete receipt from an older delete-enabled deployment is
        # also proof of local publication. Disabling deletion must not consume
        # upstream or download a duplicate.
        already_mirrored.update(_pending_deletes(strict=True))
    retained_visible = [a for a in orphans if a in already_mirrored]
    if retained_visible:
        log.info("Reconcile: %d intentionally retained mirrored asset(s) skipped", len(retained_visible))
    truly_orphaned = [
        aid for aid in orphans
        if aid not in in_flight_snapshot and aid not in already_mirrored
    ]
    if truly_orphaned:
        log.warning("Reconcile: found %d orphan file(s) — processing", len(truly_orphaned))
        await notify_failure(
            "reconcile_orphans_found",
            f"Reconciliation found {len(truly_orphaned)} file(s) in Frame.io "
            f"that should have been mirrored (webhook delivery gap?). Processing now.",
            throttle_minutes=15,
        )
    elif orphans:
        log.info("Reconcile: %d file(s) in folder, none newly actionable", len(orphans))
    else:
        log.debug("Reconcile: 0 listed files")

    jobs = list(pending_snapshot.items())
    pending_ids = set(pending_snapshot)
    jobs.extend(
        (asset_id, account_id)
        for asset_id in truly_orphaned
        if asset_id not in pending_ids
    )
    return await _process_reconcile_jobs(jobs)


async def reconcile_loop() -> None:
    """Background loop: kicks off once after a short delay so discovery has a chance,
    then runs at CFG['reconcile_interval_seconds']. Errors don't kill the loop."""
    interval = max(60, CFG["reconcile_interval_seconds"])
    log.info("Reconcile loop armed (every %ds)", interval)
    # Wait briefly so the first webhook can populate discovery state before our first sweep
    await asyncio.sleep(30)
    while True:
        try:
            reclaimed = _cleanup_stale_download_temps()
            if reclaimed:
                log.warning(
                    "Reclaimed bytes from %d stale interrupted download temp(s)",
                    reclaimed,
                )
            n = await reconcile_once()
            if n:
                log.info("Reconcile cycle queued %d asset job(s)", n)
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
    try:
        reclaimed = _cleanup_stale_download_temps()
        if reclaimed:
            log.warning(
                "Reclaimed bytes from %d stale interrupted download temp(s)",
                reclaimed,
            )
    except Exception as exc:
        log.error("Could not inspect stale download temps: %s", exc)
        await notify_failure(
            "temp_cleanup_failed",
            f"Interrupted-download cleanup failed: {type(exc).__name__}. Check the incoming mount.",
            throttle_minutes=60,
        )
    # Fixed workers prevent a webhook burst from creating unbounded download
    # tasks. Durable pending_downloads remains the overflow/restart queue.
    worker_tasks = [
        asyncio.create_task(_asset_worker(index + 1))
        for index in range(CFG["frameio_workers"])
    ]
    reconcile_task = asyncio.create_task(reconcile_loop())
    try:
        yield
    finally:
        reconcile_task.cancel()
        for worker_task in worker_tasks:
            worker_task.cancel()
        for task in [reconcile_task, *worker_tasks]:
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


async def _read_bounded_body(request: Request, max_bytes: int) -> bytes:
    """Stream a public request body with a hard cumulative memory bound."""
    content_length = request.headers.get("content-length")
    if content_length:
        try:
            declared = int(content_length, 10)
        except ValueError as exc:
            raise HTTPException(status_code=400, detail="Invalid Content-Length") from exc
        if declared < 0:
            raise HTTPException(status_code=400, detail="Invalid Content-Length")
        if declared > max_bytes:
            raise HTTPException(status_code=413, detail="Payload too large")

    body = bytearray()
    async for chunk in request.stream():
        if len(body) + len(chunk) > max_bytes:
            raise HTTPException(status_code=413, detail="Payload too large")
        body.extend(chunk)
    return bytes(body)


def _probe_incoming_write() -> tuple[bool, str | None]:
    incoming = Path(CFG["incoming_dir"])
    directory_fd: int | None = None
    probe_fd: int | None = None
    probe_name: str | None = None
    expected_probe: os.stat_result | None = None
    try:
        directory_fd, expected_directory = _open_incoming_dir(incoming)
        probe_fd, probe_name, expected_probe = _create_download_temp(
            directory_fd, "health"
        )
        os.write(probe_fd, b"ok")
        os.fsync(probe_fd)
        if not _incoming_publish_is_reachable(
            incoming,
            directory_fd,
            expected_directory,
            probe_name,
            os.fstat(probe_fd),
        ):
            return False, "incoming directory changed during write probe"
        return True, None
    except Exception as exc:
        detail = exc.strerror if isinstance(exc, OSError) else type(exc).__name__
        return False, f"incoming directory is not writable: {detail or type(exc).__name__}"
    finally:
        if probe_fd is not None:
            os.close(probe_fd)
        if directory_fd is not None and probe_name is not None and expected_probe is not None:
            _remove_temp_if_same(directory_fd, probe_name, expected_probe)
        if directory_fd is not None:
            os.close(directory_fd)


def _probe_state_write() -> bool:
    parent_fd: int | None = None
    probe_fd: int | None = None
    probe_name: str | None = None
    try:
        parent_fd, expected_parent, leaf = _open_state_parent()
        try:
            fd = os.open(
                leaf,
                os.O_WRONLY
                | os.O_APPEND
                | os.O_NONBLOCK
                | os.O_NOFOLLOW
                | os.O_CLOEXEC,
                dir_fd=parent_fd,
            )
        except FileNotFoundError:
            for _ in range(100):
                probe_name = f".state-health.{secrets.token_hex(8)}"
                try:
                    probe_fd = os.open(
                        probe_name,
                        os.O_WRONLY
                        | os.O_CREAT
                        | os.O_EXCL
                        | os.O_NOFOLLOW
                        | os.O_CLOEXEC,
                        0o600,
                        dir_fd=parent_fd,
                    )
                    break
                except FileExistsError:
                    continue
            if probe_fd is None:
                return False
            os.fchmod(probe_fd, 0o600)
            os.fsync(probe_fd)
            return _state_parent_is_canonical(parent_fd, expected_parent)
        else:
            try:
                node = os.fstat(fd)
            finally:
                os.close(fd)
            if (
                not stat.S_ISREG(node.st_mode)
                or node.st_nlink != 1
                or node.st_uid != os.geteuid()
                or node.st_mode & 0o077
                or not _state_parent_is_canonical(parent_fd, expected_parent)
            ):
                return False
            try:
                _load_state(strict=True)
            except Exception:
                return False
            return True
    except (OSError, RuntimeError):
        return False
    finally:
        if probe_fd is not None:
            os.close(probe_fd)
        if parent_fd is not None and probe_name is not None:
            try:
                os.unlink(probe_name, dir_fd=parent_fd)
            except FileNotFoundError:
                pass
        if parent_fd is not None:
            os.close(parent_fd)


def _probe_private_staging() -> tuple[bool, str | None]:
    staging = Path(CFG["staging_dir"])
    incoming = Path(CFG["incoming_dir"])
    staging_fd: int | None = None
    incoming_fd: int | None = None
    probe_fd: int | None = None
    probe_name: str | None = None
    expected_probe: os.stat_result | None = None
    try:
        staging_fd, _expected_staging = _open_private_staging_dir(staging)
        incoming_fd, _expected_incoming = _open_incoming_dir(incoming)
        _require_private_staging_mount(staging_fd, incoming_fd)
        probe_fd, probe_name, _created = _create_download_temp(
            staging_fd, "stagehealth"
        )
        os.write(probe_fd, b"ok")
        os.fsync(probe_fd)
        os.fsync(staging_fd)
        expected_probe = os.fstat(probe_fd)
        return True, None
    except Exception as exc:
        detail = exc.strerror if isinstance(exc, OSError) else str(exc)
        return False, f"private staging is unavailable: {detail or type(exc).__name__}"
    finally:
        if probe_fd is not None:
            os.close(probe_fd)
        if staging_fd is not None and probe_name and expected_probe is not None:
            _remove_temp_if_same(staging_fd, probe_name, expected_probe)
        if incoming_fd is not None:
            os.close(incoming_fd)
        if staging_fd is not None:
            os.close(staging_fd)


def _validate_durable_state_semantics() -> None:
    state = _load_state(strict=True)
    token = state.get("refresh_token")
    if token is not None and (not isinstance(token, str) or not token):
        raise ValueError("refresh_token state is invalid")
    # Reuse the exact schemas that workers trust so health cannot report 200
    # while reconciliation immediately rejects the same durable receipts.
    _pending_downloads(strict=True)
    _pending_deletes(strict=True)
    _completed_deletes(strict=True)
    _retained_assets(strict=True)
    _pending_publications(strict=True)
    cursor = state.get("reconcile_cursor", {})
    if cursor not in ({}, None):
        if not isinstance(cursor, dict):
            raise ValueError("reconcile_cursor state must be an object")
        if set(cursor) != {"url", "account_id", "folder_id"} or not all(
            isinstance(cursor.get(key), str) and cursor[key]
            for key in ("url", "account_id", "folder_id")
        ):
            raise ValueError("reconcile_cursor state is invalid")
        if (
            len(cursor["url"]) > 8192
            or len(cursor["account_id"]) > 200
            or len(cursor["folder_id"]) > 200
        ):
            raise ValueError("reconcile_cursor state exceeds field limits")


def _collect_health() -> tuple[int, dict]:
    uptime = int(time.monotonic() - _START_TIME)
    errors: list[str] = []
    if not CFG["webhook_secret"]:
        errors.append("FRAMEIO_WEBHOOK_SECRET is missing")
    if not (CFG["adobe_client_id"] and CFG["adobe_client_secret"]):
        errors.append("Adobe client credentials are missing")
    if _REFRESH_TOKEN_PERSIST_ERROR:
        errors.append("rotated refresh token is not durably persisted")
    incoming_ready, incoming_error = _probe_incoming_write()
    if not incoming_ready and incoming_error:
        errors.append(incoming_error)
    staging_ready, staging_error = _probe_private_staging()
    if not staging_ready and staging_error:
        errors.append(staging_error)
    state_persistent = _probe_state_write()
    if state_persistent:
        try:
            _validate_durable_state_semantics()
        except Exception:
            state_persistent = False
    if not state_persistent:
        errors.append("private state is unavailable, unsafe, or invalid")
    status = "unhealthy" if errors else "ok"
    return (503 if errors else 200), {
        "status": status,
        "version": "1.0.0",
        "uptime_seconds": uptime,
        "has_refresh_token": (
            _REFRESH_TOKEN_MEMORY is not None
            or _load_refresh_token() is not None
        ),
        "state_persistent": state_persistent,
        "staging_private": staging_ready,
        "errors": errors,
    }


_HEALTH_LOCK = asyncio.Lock()
_HEALTH_CACHE: dict = {"expires_at": 0.0, "status_code": 503, "body": {}}
_HEALTH_PROBE_TASK: asyncio.Task | None = None
_HEALTH_PROBE_TIMEOUT_SECONDS = 5.0


@app.get("/health")
async def health():
    global _HEALTH_PROBE_TASK
    now = time.monotonic()
    async with _HEALTH_LOCK:
        if now < _HEALTH_CACHE["expires_at"]:
            return JSONResponse(
                status_code=_HEALTH_CACHE["status_code"],
                content=_HEALTH_CACHE["body"],
            )
        if _HEALTH_PROBE_TASK is None:
            _HEALTH_PROBE_TASK = asyncio.create_task(
                asyncio.to_thread(_collect_health)
            )
        probe = _HEALTH_PROBE_TASK

    try:
        status_code, body = await asyncio.wait_for(
            asyncio.shield(probe), timeout=_HEALTH_PROBE_TIMEOUT_SECONDS
        )
    except TimeoutError:
        async with _HEALTH_LOCK:
            timeout_body = dict(_HEALTH_CACHE.get("body") or {})
            timeout_body.update(
                status="unhealthy",
                version="1.0.0",
                uptime_seconds=int(time.monotonic() - _START_TIME),
            )
            errors = list(timeout_body.get("errors") or [])
            if "health filesystem probe timed out" not in errors:
                errors.append("health filesystem probe timed out")
            timeout_body["errors"] = errors
            _HEALTH_CACHE.update(
                expires_at=time.monotonic() + 5,
                status_code=503,
                body=timeout_body,
            )
            return JSONResponse(status_code=503, content=timeout_body)
    except Exception as exc:
        async with _HEALTH_LOCK:
            if _HEALTH_PROBE_TASK is probe:
                _HEALTH_PROBE_TASK = None
            body = {
                "status": "unhealthy",
                "version": "1.0.0",
                "uptime_seconds": int(time.monotonic() - _START_TIME),
                "errors": [f"health probe failed: {type(exc).__name__}"],
            }
            _HEALTH_CACHE.update(
                expires_at=time.monotonic() + 5,
                status_code=503,
                body=body,
            )
            return JSONResponse(status_code=503, content=body)
    else:
        async with _HEALTH_LOCK:
            if _HEALTH_PROBE_TASK is probe:
                _HEALTH_PROBE_TASK = None
            _HEALTH_CACHE.update(
                expires_at=time.monotonic() + 5,
                status_code=status_code,
                body=body,
            )
            return JSONResponse(status_code=status_code, content=body)


# ---------------------------------------------------------------------------
# OAuth Web App: one-time browser auth dance to obtain a refresh_token.
# Use this on personal Adobe accounts where S2S isn't available.
#
# Security: these endpoints are internet-facing. Three protections:
#   1. Required X-Setup-Secret header gates POST /oauth/start without placing
#      the enrollment secret in a URL, browser history, or access log.
#   2. CSRF state param: random state minted in /start, verified+consumed in
#      /callback (prevents a forged callback from injecting someone else's code).
#   3. Every fresh or repeated enrollment requires that setup secret.
# ---------------------------------------------------------------------------
_OAUTH_STATES: dict[str, float] = {}  # state -> created monotonic ts
_OAUTH_STATE_TTL = 600  # 10 minutes


def _prune_oauth_states() -> None:
    now = time.monotonic()
    for s, ts in list(_OAUTH_STATES.items()):
        if now - ts > _OAUTH_STATE_TTL:
            _OAUTH_STATES.pop(s, None)


@app.post("/oauth/start")
async def oauth_start(
    x_setup_secret: str = Header(default="", alias="X-Setup-Secret"),
):
    """Mint a short-lived Adobe authorization URL after header authentication."""
    if not (CFG["adobe_client_id"] and CFG["adobe_client_secret"]):
        raise HTTPException(503, "Adobe client_id/secret not configured")
    if not CFG["oauth_redirect_uri"]:
        raise HTTPException(503, "oauth_redirect_uri not configured")

    # Enrollment authorization: this endpoint is normally public beside the
    # webhook, so first enrollment must be gated too. Otherwise the first visitor
    # could bind the mirror to their Adobe account before the owner does.
    setup_secret = CFG["oauth_setup_secret"]
    if not setup_secret:
        raise HTTPException(503, "OAUTH_SETUP_SECRET is required for enrollment")
    if not secrets.compare_digest(x_setup_secret, setup_secret):
        log.warning("oauth/start rejected — missing/invalid setup secret")
        raise HTTPException(403, "Missing or invalid setup secret")

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
    return {"authorize_url": url}


@app.get("/oauth/callback")
async def oauth_callback(
    code: str = "",
    error: str = "",
    error_description: str = "",
    state: str = "",
):
    """Exchange the authorization code for tokens, persist the refresh_token."""
    global _REFRESH_TOKEN_MEMORY, _REFRESH_TOKEN_PERSIST_ERROR
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
        if not isinstance(body, dict):
            return HTMLResponse("<h1>Invalid token response</h1>", status_code=500)
        refresh_value = body.get("refresh_token")
        access_value = body.get("access_token")
        expires_value = body.get("expires_in", 3600)
        if not isinstance(refresh_value, str) or not refresh_value:
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
        if (
            not isinstance(access_value, str)
            or not access_value
            or not isinstance(expires_value, int)
            or isinstance(expires_value, bool)
            or not 1 <= expires_value <= 604_800
        ):
            return HTMLResponse("<h1>Invalid token response</h1>", status_code=500)
        # Cache the access token FIRST — even if disk persist fails (e.g., readonly
        # mount, EBUSY), we want working creds for this process's lifetime.
        _TOKEN_CACHE["token"] = access_value
        _TOKEN_CACHE["expires_at"] = time.monotonic() + expires_value
        _REFRESH_TOKEN_MEMORY = refresh_value
        _REFRESH_TOKEN_PERSIST_ERROR = True

        try:
            _save_refresh_token(refresh_value)
        except Exception as exc:
            log.error("Failed to persist refresh_token to disk: %s — token remains in memory only", exc)
            return HTMLResponse(
                "<h1>⚠️ Partial success</h1>"
                "<p>Got tokens from Adobe but couldn't write the state file "
                "(check the mount). The access token works for this process only — "
                "a container restart loses it. Fix the mount, then re-visit /oauth/start.</p>",
                status_code=500,
            )
        _REFRESH_TOKEN_PERSIST_ERROR = False

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
    del background_tasks  # fixed lifespan workers own execution, not request tasks
    # Stream with a cumulative cap. Chunked requests have no Content-Length and
    # must not be buffered without a bound before HMAC rejection.
    raw_body = await _read_bounded_body(request, CFG["webhook_max_bytes"])

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
    if not isinstance(payload, dict):
        raise HTTPException(status_code=400, detail="Webhook JSON must be an object")

    event_type = payload.get("type", "")
    resource = payload.get("resource", {})
    if not isinstance(resource, dict):
        resource = {}
    resource_id = resource.get("id", "")
    resource_type = resource.get("type", "")
    # account_id is account-scoped on every V4 endpoint we'll call
    account = payload.get("account") or {}
    if not isinstance(account, dict):
        account = {}
    account_id = account.get("id", "")

    log.info(
        "Webhook: type=%s resource.type=%s resource.id=%s account.id=%s",
        event_type, resource_type, resource_id, account_id,
    )

    if event_type != "file.ready":
        return {"status": "ignored", "event_type": event_type}

    if (
        not isinstance(resource_id, str)
        or not resource_id
        or len(resource_id) > 200
        or resource_type != "file"
        or not isinstance(account_id, str)
        or not account_id
        or len(account_id) > 200
    ):
        log.error("Unexpected file.ready payload: %s", payload)
        raise HTTPException(status_code=422, detail="Missing or invalid resource/account")

    # Persist retry work before returning 2xx. In particular, the first webhook
    # can arrive before credentials or folder auto-discovery are ready.
    try:
        _save_pending_download(resource_id, account_id)
    except Exception as exc:
        log.error("Cannot persist webhook job for %s: %s", resource_id, exc)
        await notify_failure(
            "state_persist",
            "A Frame.io webhook could not be queued durably; returning 503 so "
            "Frame.io retries it.",
            throttle_minutes=15,
        )
        raise HTTPException(status_code=503, detail="Cannot persist webhook job")

    # Missing credentials are recoverable configuration: keep the durable job
    # queued and acknowledge it. Reconciliation processes it after credentials
    # become available, even if this was the first/only asset.
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
        return {"status": "accepted_queued", "reason": "no_adobe_credentials"}

    if await _enqueue_asset_job(account_id, resource_id):
        return {"status": "accepted"}
    log.warning("Worker queue full; durable asset %s will reconcile later", resource_id)
    return {"status": "accepted_queued", "reason": "worker_queue_full"}


# ---------------------------------------------------------------------------
# Background processing
# ---------------------------------------------------------------------------
class DownloadSafetyError(RuntimeError):
    pass


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
    # The sorter intentionally ignores hidden/in-progress sentinel names. Make
    # a mirrored asset visible to its intake contract before deleting upstream.
    if base.startswith("."):
        base = f"camera_{base.lstrip('.')}"
    if base == "Thumbs.db" or base.endswith((".tmp", ".part", ".filepart")):
        base = f"{base}.camera"

    # Leave room under Linux NAME_MAX for `.tmp.<16-hex>.` and collision
    # suffixes, and cap encoded bytes (not Python characters). Preserve a short
    # camera extension when possible.
    max_bytes = 220
    suffix = Path(base).suffix
    suffix_bytes = len(suffix.encode("utf-8"))
    if not suffix or suffix_bytes > 20:
        suffix = ""
        suffix_bytes = 0
    stem = base[:-len(suffix)] if suffix else base
    stem_budget = max_bytes - suffix_bytes
    stem = stem.encode("utf-8")[:stem_budget].decode("utf-8", errors="ignore")
    safe = f"{stem}{suffix}"
    return safe if safe not in ("", ".", "..") else fallback


def _same_inode(node: os.stat_result, expected: os.stat_result) -> bool:
    return (
        node.st_dev == expected.st_dev
        and node.st_ino == expected.st_ino
        and stat.S_ISREG(node.st_mode)
    )


def _same_directory(node: os.stat_result, expected: os.stat_result) -> bool:
    return (
        node.st_dev == expected.st_dev
        and node.st_ino == expected.st_ino
        and stat.S_ISDIR(node.st_mode)
    )


def _open_incoming_dir(incoming: Path) -> tuple[int, os.stat_result]:
    """Pin the configured intake directory without following its final leaf."""
    if not incoming.is_absolute():
        raise OSError(errno.EINVAL, "INCOMING_DIR must be absolute", str(incoming))
    flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC
    directory_fd = os.open(incoming, flags)
    expected = os.fstat(directory_fd)
    current = os.stat(incoming, follow_symlinks=False)
    if not _same_directory(current, expected):
        os.close(directory_fd)
        raise OSError(errno.EPERM, "unsafe or unstable incoming directory", str(incoming))
    return directory_fd, expected


def _open_private_staging_dir(staging: Path) -> tuple[int, os.stat_result]:
    """Pin the owner-only persistent staging directory."""
    if not staging.is_absolute():
        raise OSError(errno.EINVAL, "STAGING_DIR must be absolute", str(staging))
    flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC
    directory_fd = os.open(staging, flags)
    expected = os.fstat(directory_fd)
    current = os.stat(staging, follow_symlinks=False)
    if (
        not _same_directory(current, expected)
        or expected.st_uid != os.geteuid()
        or expected.st_mode & 0o077
    ):
        os.close(directory_fd)
        raise OSError(
            errno.EPERM,
            "staging directory must be private, owned, and stable",
            str(staging),
        )
    return directory_fd, expected


def _fd_mount_id(fd: int) -> int:
    """Return Linux mount ID for a pinned descriptor."""
    with open(f"/proc/self/fdinfo/{fd}", encoding="ascii") as info:
        for line in info:
            if line.startswith("mnt_id:"):
                return int(line.split(":", 1)[1].strip())
    raise RuntimeError("kernel did not expose a mount ID")


def _require_private_staging_mount(
    staging_fd: int, incoming_fd: int, *, label: str = "STAGING_DIR"
) -> None:
    if _fd_mount_id(staging_fd) == _fd_mount_id(incoming_fd):
        raise RuntimeError(
            f"{label} must be a separate private mount from INCOMING_DIR"
        )


def _incoming_directory_is_canonical(
    incoming: Path, directory_fd: int, expected_directory: os.stat_result
) -> bool:
    try:
        pinned = os.fstat(directory_fd)
        current = os.stat(incoming, follow_symlinks=False)
    except OSError:
        return False
    return (
        _same_directory(pinned, expected_directory)
        and _same_directory(current, expected_directory)
    )


def _incoming_publish_is_reachable(
    incoming: Path,
    directory_fd: int,
    expected_directory: os.stat_result,
    destination_name: str,
    expected_file: os.stat_result,
) -> bool:
    """Prove the pinned publication is still visible at configured intake."""
    try:
        destination = os.stat(
            destination_name, dir_fd=directory_fd, follow_symlinks=False
        )
    except OSError:
        return False
    return (
        _incoming_directory_is_canonical(incoming, directory_fd, expected_directory)
        and _same_inode(destination, expected_file)
    )


_DOWNLOAD_TEMP_RE = re.compile(r"^\.tmp\.[0-9a-f]{16}\.[0-9a-f]{16}$")


def _cleanup_stale_temps_in_dir(
    directory: Path,
    directory_fd: int,
    expected_directory: os.stat_result,
    protected_names: set[str],
    *,
    private: bool,
) -> int:
    """Reclaim old unjournaled temps through pinned descriptors."""
    reclaimed = 0
    cutoff = time.time() - CFG["download_tmp_stale_seconds"]
    for name in os.listdir(directory_fd):
        if not _DOWNLOAD_TEMP_RE.fullmatch(name) or name in protected_names:
            continue
        try:
            node = os.stat(name, dir_fd=directory_fd, follow_symlinks=False)
        except OSError:
            continue
        if (
            not stat.S_ISREG(node.st_mode)
            or node.st_nlink != 1
            or node.st_uid != os.geteuid()
            or node.st_mtime > cutoff
            or node.st_size == 0
            or (private and node.st_mode & 0o077)
        ):
            continue
        canonical = (
            _private_staging_is_canonical(
                directory, directory_fd, expected_directory
            )
            if private
            else _incoming_directory_is_canonical(
                directory, directory_fd, expected_directory
            )
        )
        if not canonical:
            raise RuntimeError("download temp directory changed during cleanup")
        temp_fd: int | None = None
        try:
            temp_fd = os.open(
                name,
                os.O_WRONLY | os.O_NONBLOCK | os.O_NOFOLLOW | os.O_CLOEXEC,
                dir_fd=directory_fd,
            )
            fcntl.flock(temp_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            current = os.fstat(temp_fd)
            path_node = os.stat(
                name, dir_fd=directory_fd, follow_symlinks=False
            )
            if (
                not _same_inode(current, node)
                or not _same_inode(path_node, node)
                or current.st_nlink != 1
                or current.st_uid != os.geteuid()
                or current.st_mtime != node.st_mtime
                or current.st_size != node.st_size
            ):
                continue
            # Truncate the pinned inode before removing its proven pathname.
            # On the shared intake this makes a same-UID substitution harmless;
            # on private staging it also returns space before a directory fsync.
            os.ftruncate(temp_fd, 0)
            os.fsync(temp_fd)
            # Leave a zero-byte tombstone. Unlinking a shared pathname after a
            # check would reopen a substitution race; randomized O_EXCL names
            # mean the tombstone cannot block a later download.
            reclaimed += 1
        except (FileNotFoundError, BlockingIOError):
            continue
        finally:
            if temp_fd is not None:
                os.close(temp_fd)
    return reclaimed


def _cleanup_stale_download_temps() -> int:
    """Clean private download stages and shared hidden handoff copies."""
    incoming = Path(CFG["incoming_dir"])
    staging = Path(CFG["staging_dir"])
    # Fail closed if the journal is unreadable or malformed. Each directory has
    # a different protected namespace: private stages versus shared handoffs.
    publications = _pending_publications(strict=True)
    protected_stages = {entry["temp_name"] for entry in publications.values()}
    protected_handoffs = {
        entry["handoff_name"]
        for entry in publications.values()
        if entry.get("handoff_name") is not None
    }
    incoming_fd, expected_incoming = _open_incoming_dir(incoming)
    staging_fd: int | None = None
    try:
        staging_fd, expected_staging = _open_private_staging_dir(staging)
        _require_private_staging_mount(staging_fd, incoming_fd)
        return _cleanup_stale_temps_in_dir(
            staging,
            staging_fd,
            expected_staging,
            protected_stages,
            private=True,
        ) + _cleanup_stale_temps_in_dir(
            incoming,
            incoming_fd,
            expected_incoming,
            protected_handoffs,
            private=False,
        )
    finally:
        if staging_fd is not None:
            os.close(staging_fd)
        os.close(incoming_fd)


def _create_download_temp(
    directory_fd: int, asset_key: str
) -> tuple[int, str, os.stat_result]:
    """Create an unpredictable, single-link temp relative to the pinned intake."""
    flags = os.O_RDWR | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC
    for _ in range(100):
        name = f".tmp.{asset_key}.{secrets.token_hex(8)}"
        try:
            temp_fd = os.open(name, flags, 0o600, dir_fd=directory_fd)
        except FileExistsError:
            continue
        node = os.fstat(temp_fd)
        if stat.S_ISREG(node.st_mode) and node.st_nlink == 1:
            # Keep content owner-only and hidden until the retention/delete
            # decision is durable. The final handoff changes it to 0664.
            os.fchmod(temp_fd, 0o600)
            fcntl.flock(temp_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            return temp_fd, name, node
        os.close(temp_fd)
        try:
            os.unlink(name, dir_fd=directory_fd)
        except Exception:
            pass
        raise RuntimeError("new download temp is not a single-link regular file")
    raise FileExistsError("could not allocate a unique incoming temp name")


def _remove_temp_if_same(
    directory_fd: int, temp_name: str, expected: os.stat_result
) -> None:
    """Remove only the exact hidden inode created by this process."""
    try:
        node = os.stat(temp_name, dir_fd=directory_fd, follow_symlinks=False)
        if _same_inode(node, expected) and node.st_nlink == 1:
            os.unlink(temp_name, dir_fd=directory_fd)
    except FileNotFoundError:
        pass
    except OSError as exc:
        log.warning("Could not clean download temp %s: %s", temp_name, exc)


def _sha256_fd(fd: int) -> str:
    """Hash a pinned regular file without changing the caller's file offset."""
    original_offset = os.lseek(fd, 0, os.SEEK_CUR)
    digest = hashlib.sha256()
    try:
        os.lseek(fd, 0, os.SEEK_SET)
        while True:
            chunk = os.read(fd, 1024 * 1024)
            if not chunk:
                break
            digest.update(chunk)
    finally:
        os.lseek(fd, original_offset, os.SEEK_SET)
    return digest.hexdigest()


def _verify_temp_fd(
    directory_fd: int,
    temp_fd: int,
    temp_name: str,
    expected: os.stat_result,
    expected_size: int,
    expected_sha256: str,
) -> bool:
    """Revalidate path, inode, ownership, mode, size, and bytes via pinned FDs."""
    try:
        node = os.fstat(temp_fd)
        path_node = os.stat(temp_name, dir_fd=directory_fd, follow_symlinks=False)
    except OSError:
        return False
    if (
        not _same_inode(node, expected)
        or not _same_inode(path_node, expected)
        or node.st_nlink != 1
        or path_node.st_nlink != 1
        or node.st_uid != os.geteuid()
        or node.st_mode & 0o077
        or node.st_size != expected_size
    ):
        return False
    try:
        return hmac.compare_digest(_sha256_fd(temp_fd), expected_sha256)
    except OSError:
        return False


_LIBC = ctypes.CDLL(None, use_errno=True)
_RENAMEAT2 = getattr(_LIBC, "renameat2", None)
if _RENAMEAT2 is not None:
    _RENAMEAT2.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_uint]
    _RENAMEAT2.restype = ctypes.c_int
_RENAME_NOREPLACE_FILESYSTEMS: set[int] = set()


def _rename_noreplace(directory_fd: int, source: str, destination: str) -> None:
    """Atomically rename inside a pinned directory without replacing a leaf."""
    if _RENAMEAT2 is None:
        raise OSError(errno.ENOSYS, "renameat2(RENAME_NOREPLACE) is unavailable")
    result = _RENAMEAT2(
        directory_fd,
        os.fsencode(source),
        directory_fd,
        os.fsencode(destination),
        1,  # RENAME_NOREPLACE
    )
    if result != 0:
        error = ctypes.get_errno()
        raise OSError(error, os.strerror(error), destination)


def _require_rename_noreplace(directory_fd: int) -> None:
    """Probe the actual intake filesystem before any optional upstream delete."""
    filesystem = os.fstat(directory_fd).st_dev
    if filesystem in _RENAME_NOREPLACE_FILESYSTEMS:
        return
    source = f".tmp.rename-probe.{secrets.token_hex(8)}"
    occupied = f".tmp.rename-probe.{secrets.token_hex(8)}"
    destination = f".tmp.rename-probe.{secrets.token_hex(8)}"
    source_fd: int | None = None
    occupied_fd: int | None = None
    try:
        flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC
        source_fd = os.open(source, flags, 0o600, dir_fd=directory_fd)
        occupied_fd = os.open(occupied, flags, 0o600, dir_fd=directory_fd)
        try:
            _rename_noreplace(directory_fd, source, occupied)
        except OSError as exc:
            if exc.errno != errno.EEXIST:
                raise
        else:
            raise OSError(errno.ENOTSUP, "RENAME_NOREPLACE replaced an existing file")
        _rename_noreplace(directory_fd, source, destination)
        _RENAME_NOREPLACE_FILESYSTEMS.add(filesystem)
    finally:
        if source_fd is not None:
            os.close(source_fd)
        if occupied_fd is not None:
            os.close(occupied_fd)
        for name in (source, occupied, destination):
            try:
                os.unlink(name, dir_fd=directory_fd)
            except FileNotFoundError:
                pass


def _publish_no_clobber(
    directory_fd: int,
    temp_fd: int,
    temp_name: str,
    filename: str,
    expected: os.stat_result,
    *,
    before_publish=None,
    after_publish=None,
    expected_size: int | None = None,
    expected_sha256: str | None = None,
    finalize_mode: bool = True,
) -> str | None:
    """Expose a pinned temp atomically after journaling each destination choice."""
    stem, ext = Path(filename).stem, Path(filename).suffix
    for number in range(1, 100):
        dest_name = filename if number == 1 else f"{stem}_{number}{ext}"
        try:
            source_node = os.stat(
                temp_name, dir_fd=directory_fd, follow_symlinks=False
            )
        except FileNotFoundError as exc:
            raise RuntimeError("download temp disappeared before publish") from exc
        pinned_node = os.fstat(temp_fd)
        if (
            not _same_inode(source_node, expected)
            or not _same_inode(pinned_node, expected)
            or source_node.st_nlink != 1
        ):
            raise RuntimeError("download temp inode changed before publish")
        if expected_size is not None and expected_sha256 is not None and not _verify_temp_fd(
            directory_fd,
            temp_fd,
            temp_name,
            expected,
            expected_size,
            expected_sha256,
        ):
            raise RuntimeError("download temp content changed before publish")
        if before_publish is not None:
            before_publish(dest_name)
        source_node = os.stat(temp_name, dir_fd=directory_fd, follow_symlinks=False)
        if not _same_inode(source_node, expected) or source_node.st_nlink != 1:
            raise RuntimeError("download temp changed after destination journaling")
        try:
            _rename_noreplace(directory_fd, temp_name, dest_name)
        except OSError as exc:
            if exc.errno != errno.EEXIST:
                raise
            continue
        # Signal immediately after the atomic namespace change, before any
        # durability fsync that can report an error after the rename is already
        # visible (and potentially consumed by the sorter).
        if after_publish is not None:
            after_publish(dest_name)
        # renameat2 emits IN_MOVED_TO, which is the sorter's atomic handoff.
        # Revalidate through our still-open inode, then make the final file
        # group-writable only after no upstream-risking action remains.
        if expected_size is not None and (
            os.fstat(temp_fd).st_size != expected_size
            or expected_sha256 is None
            or not hmac.compare_digest(_sha256_fd(temp_fd), expected_sha256)
        ):
            raise RuntimeError("published content changed during handoff")
        if finalize_mode:
            os.fchmod(temp_fd, 0o664)
            os.fsync(temp_fd)
        os.fsync(directory_fd)
        return dest_name
    return None


def _validate_publication(asset_id: str, raw) -> dict:
    """Return a normalized publication journal entry or fail closed."""
    if not isinstance(raw, dict) or raw.get("version") != 1:
        raise ValueError(f"publication {asset_id!r} has an invalid version")
    entry = dict(raw)
    account_id = entry.get("account_id")
    temp_name = entry.get("temp_name")
    filename = entry.get("filename")
    destination_name = entry.get("destination_name")
    handoff_name = entry.get("handoff_name")
    handoff_dev = entry.get("handoff_dev")
    handoff_ino = entry.get("handoff_ino")
    size = entry.get("size")
    digest = entry.get("sha256")
    expected_size = entry.get("expected_size")
    policy = entry.get("policy")
    phase = entry.get("phase")
    if not isinstance(account_id, str) or not account_id or len(account_id) > 200:
        raise ValueError(f"publication {asset_id!r} has an invalid account")
    if not isinstance(temp_name, str) or not _DOWNLOAD_TEMP_RE.fullmatch(temp_name):
        raise ValueError(f"publication {asset_id!r} has an invalid temp name")
    if (
        not isinstance(filename, str)
        or not filename
        or Path(filename).name != filename
        or len(filename.encode("utf-8")) > 220
        or _safe_filename(filename, "invalid.bin") != filename
    ):
        raise ValueError(f"publication {asset_id!r} has an invalid filename")
    if destination_name is not None and (
        not isinstance(destination_name, str)
        or not destination_name
        or Path(destination_name).name != destination_name
        or len(destination_name.encode("utf-8")) > 255
        or destination_name.startswith(".")
        or destination_name == "Thumbs.db"
        or destination_name.endswith((".tmp", ".part", ".filepart"))
    ):
        raise ValueError(f"publication {asset_id!r} has an invalid destination")
    if any(value is not None for value in (handoff_name, handoff_dev, handoff_ino)):
        if (
            not isinstance(handoff_name, str)
            or not _DOWNLOAD_TEMP_RE.fullmatch(handoff_name)
            or not isinstance(handoff_dev, int)
            or isinstance(handoff_dev, bool)
            or handoff_dev < 0
            or not isinstance(handoff_ino, int)
            or isinstance(handoff_ino, bool)
            or handoff_ino <= 0
        ):
            raise ValueError(f"publication {asset_id!r} has invalid handoff fields")
    if (
        not isinstance(entry.get("dev"), int)
        or isinstance(entry["dev"], bool)
        or entry["dev"] < 0
    ):
        raise ValueError(f"publication {asset_id!r} has an invalid device")
    if (
        not isinstance(entry.get("ino"), int)
        or isinstance(entry["ino"], bool)
        or entry["ino"] <= 0
    ):
        raise ValueError(f"publication {asset_id!r} has an invalid inode")
    if not isinstance(size, int) or isinstance(size, bool) or size <= 0:
        raise ValueError(f"publication {asset_id!r} has an invalid size")
    if not isinstance(digest, str) or not re.fullmatch(r"[0-9a-f]{64}", digest):
        raise ValueError(f"publication {asset_id!r} has an invalid SHA-256")
    if expected_size is not None and (
        not isinstance(expected_size, int)
        or isinstance(expected_size, bool)
        or expected_size <= 0
    ):
        raise ValueError(f"publication {asset_id!r} has an invalid expected size")
    if policy not in ("retain", "delete"):
        raise ValueError(f"publication {asset_id!r} has an invalid policy")
    if phase not in ("delete_pending", "ready", "renaming"):
        raise ValueError(f"publication {asset_id!r} has an invalid phase")
    if policy == "retain" and phase == "delete_pending":
        raise ValueError(f"publication {asset_id!r} has an inconsistent phase")
    if policy == "delete" and expected_size != size:
        raise ValueError(f"publication {asset_id!r} lacks exact delete size evidence")
    if phase == "renaming" and (
        destination_name is None or handoff_name is None
    ):
        raise ValueError(f"publication {asset_id!r} lacks handoff evidence")
    created_at = entry.get("created_at")
    if not isinstance(created_at, int) or isinstance(created_at, bool) or created_at <= 0:
        raise ValueError(f"publication {asset_id!r} has an invalid creation time")
    return entry


def _pending_publications(*, strict: bool = False) -> dict[str, dict]:
    raw = _load_state(strict=strict).get("pending_publications", {})
    if not isinstance(raw, dict):
        if strict:
            raise ValueError("pending_publications state must be an object")
        return {}
    if len(raw) > 1000:
        if strict:
            raise ValueError("pending_publications exceeds 1,000 entries")
        return {}
    validated: dict[str, dict] = {}
    for asset_id, entry in raw.items():
        try:
            if not isinstance(asset_id, str) or not asset_id or len(asset_id) > 200:
                raise ValueError("publication asset id is invalid")
            validated[asset_id] = _validate_publication(asset_id, entry)
        except ValueError:
            if strict:
                raise
    return validated


def _publication_receipt_is_durable(asset_id: str, entry: dict, state: dict) -> bool:
    if entry["policy"] == "retain":
        retained = state.get("retained_assets", [])
        return isinstance(retained, list) and asset_id in retained
    if entry["phase"] not in ("ready", "renaming"):
        return False
    completed = state.get("completed_deletes", {})
    return isinstance(completed, dict) and asset_id in completed


async def _begin_publication(
    asset_id: str,
    account_id: str,
    temp_name: str,
    filename: str,
    node: os.stat_result,
    size: int,
    digest: str,
    expected_size: int | None,
    policy: str,
) -> dict | None:
    """Atomically journal hidden bytes and their retention/delete policy."""
    try:
        state = _load_state(strict=True)
        raw_publications = state.get("pending_publications", {})
        pending_deletes = state.get("pending_deletes", {})
        retained_assets = state.get("retained_assets", [])
        if not isinstance(raw_publications, dict):
            raise ValueError("pending_publications state must be an object")
        if len(raw_publications) >= 1000 and asset_id not in raw_publications:
            raise ValueError("pending_publications capacity reached")
        if not isinstance(pending_deletes, dict):
            raise ValueError("pending_deletes state must be an object")
        if not isinstance(retained_assets, list):
            raise ValueError("retained_assets state must be an array")
        publications = dict(raw_publications)
        if asset_id in publications:
            raise ValueError("publication already exists")
        entry = {
            "version": 1,
            "account_id": account_id,
            "temp_name": temp_name,
            "filename": filename,
            "destination_name": None,
            "handoff_name": None,
            "handoff_dev": None,
            "handoff_ino": None,
            "dev": node.st_dev,
            "ino": node.st_ino,
            "size": size,
            "sha256": digest,
            "expected_size": expected_size,
            "policy": policy,
            "phase": "delete_pending" if policy == "delete" else "ready",
            "created_at": int(time.time()),
        }
        _validate_publication(asset_id, entry)
        publications[asset_id] = entry
        updates: dict = {"pending_publications": publications}
        if policy == "delete":
            pending = dict(pending_deletes)
            pending[asset_id] = account_id
            updates["pending_deletes"] = pending
        else:
            retained = set(str(item) for item in retained_assets if item)
            retained.add(asset_id)
            if len(retained) > 10_000:
                raise ValueError("retained_assets capacity reached")
            updates["retained_assets"] = sorted(retained)
        _save_state(updates, base_state=state)
    except Exception as exc:
        log.warning("Could not journal publication for %s: %s", asset_id, exc)
        await notify_failure(
            "state_persist",
            "Downloaded Frame.io bytes could not be journaled safely. Upstream was "
            "preserved and the durable webhook job will retry.",
            throttle_minutes=60,
        )
        return None
    if policy == "delete":
        _PENDING_DELETES[asset_id] = account_id
    else:
        _RETAINED_ASSETS.add(asset_id)
    return entry


def _publication_stage_visibility(
    asset_id: str,
    account_id: str,
    stage_name: str,
    node: os.stat_result,
    size: int,
    digest: str,
) -> bool | None:
    """Classify a failed begin as committed, absent, or unreadable/uncertain."""
    try:
        entry = _pending_publications(strict=True).get(asset_id)
    except Exception:
        return None
    if entry is None:
        return False
    return (
        entry["account_id"] == account_id
        and entry["temp_name"] == stage_name
        and entry["dev"] == node.st_dev
        and entry["ino"] == node.st_ino
        and entry["size"] == size
        and hmac.compare_digest(entry["sha256"], digest)
    )


def _set_publication_destination(
    asset_id: str,
    destination_name: str,
    handoff_name: str,
    handoff_node: os.stat_result,
) -> dict:
    state = _load_state(strict=True)
    raw_publications = state.get("pending_publications", {})
    if not isinstance(raw_publications, dict) or asset_id not in raw_publications:
        raise ValueError("publication journal disappeared before handoff")
    publications = dict(raw_publications)
    entry = _validate_publication(asset_id, publications[asset_id])
    entry["destination_name"] = destination_name
    entry["handoff_name"] = handoff_name
    entry["handoff_dev"] = handoff_node.st_dev
    entry["handoff_ino"] = handoff_node.st_ino
    entry["phase"] = "renaming"
    _validate_publication(asset_id, entry)
    publications[asset_id] = entry
    _save_state({"pending_publications": publications}, base_state=state)
    return entry


async def _convert_publication_to_retain(asset_id: str) -> dict | None:
    """Honor a later DELETE_UPSTREAM=0 before deletion has occurred."""
    try:
        state = _load_state(strict=True)
        raw_publications = state.get("pending_publications", {})
        raw_pending_deletes = state.get("pending_deletes", {})
        raw_retained = state.get("retained_assets", [])
        if not isinstance(raw_publications, dict):
            raise ValueError("pending_publications state must be an object")
        if not isinstance(raw_pending_deletes, dict):
            raise ValueError("pending_deletes state must be an object")
        if not isinstance(raw_retained, list):
            raise ValueError("retained_assets state must be an array")
        publications = dict(raw_publications)
        pending_deletes = dict(raw_pending_deletes)
        retained = set(str(item) for item in raw_retained if item)
        entry = _validate_publication(asset_id, publications[asset_id])
        entry.update(
            policy="retain",
            phase="ready",
            destination_name=None,
            handoff_name=None,
            handoff_dev=None,
            handoff_ino=None,
        )
        publications[asset_id] = entry
        pending_deletes.pop(asset_id, None)
        retained.add(asset_id)
        if len(retained) > 10_000:
            raise ValueError("retained_assets capacity reached")
        _save_state(
            {
                "pending_publications": publications,
                "pending_deletes": pending_deletes,
                "retained_assets": sorted(retained),
            },
            base_state=state,
        )
    except Exception as exc:
        log.warning("Could not downgrade publication %s to retention: %s", asset_id, exc)
        return None
    _PENDING_DELETES.pop(asset_id, None)
    _RETAINED_ASSETS.add(asset_id)
    return entry


async def _record_publication_deleted(asset_id: str) -> dict | None:
    """Persist DELETE success while retaining the publication recovery job."""
    try:
        state = _load_state(strict=True)
        raw_publications = state.get("pending_publications", {})
        raw_pending_deletes = state.get("pending_deletes", {})
        completed = state.get("completed_deletes", {})
        if not isinstance(raw_publications, dict):
            raise ValueError("pending_publications state must be an object")
        if not isinstance(raw_pending_deletes, dict):
            raise ValueError("pending_deletes state must be an object")
        if not isinstance(completed, dict):
            raise ValueError("completed_deletes state must be an object")
        publications = dict(raw_publications)
        pending_deletes = dict(raw_pending_deletes)
        entry = _validate_publication(asset_id, publications[asset_id])
        if entry["policy"] != "delete":
            raise ValueError("cannot record deletion for a retained publication")
        entry.update(
            phase="ready",
            destination_name=None,
            handoff_name=None,
            handoff_dev=None,
            handoff_ino=None,
        )
        publications[asset_id] = entry
        pending_deletes.pop(asset_id, None)
        parsed_completed = {
            str(key): int(value)
            for key, value in completed.items()
            if key and int(value) > 0
        }
        parsed_completed[asset_id] = int(time.time())
        if len(parsed_completed) > 10_000:
            removable = sorted(
                (
                    (key, timestamp)
                    for key, timestamp in parsed_completed.items()
                    if key != asset_id
                ),
                key=lambda item: (item[1], item[0]),
            )
            while len(parsed_completed) > 10_000 and removable:
                oldest_id, _timestamp = removable.pop(0)
                parsed_completed.pop(oldest_id, None)
        _save_state(
            {
                "pending_publications": publications,
                "pending_deletes": pending_deletes,
                "completed_deletes": parsed_completed,
            },
            base_state=state,
        )
    except Exception as exc:
        log.warning("Could not record completed delete for %s: %s", asset_id, exc)
        await notify_failure(
            "state_persist",
            "Frame.io deletion succeeded but the hidden local publication could not "
            "advance. A 404-safe retry remains durable.",
            throttle_minutes=60,
        )
        return None
    _PENDING_DELETES.pop(asset_id, None)
    _COMPLETED_DELETES.clear()
    _COMPLETED_DELETES.update(parsed_completed)
    return entry


async def _finish_publication(asset_id: str) -> bool:
    """Atomically clear journal and retry jobs only after durable exposure."""
    try:
        state = _load_state(strict=True)
        publications = state.get("pending_publications", {})
        pending_downloads = state.get("pending_downloads", {})
        pending_deletes = state.get("pending_deletes", {})
        if not isinstance(publications, dict):
            raise ValueError("pending_publications state must be an object")
        if not isinstance(pending_downloads, dict):
            raise ValueError("pending_downloads state must be an object")
        if not isinstance(pending_deletes, dict):
            raise ValueError("pending_deletes state must be an object")
        publications = dict(publications)
        pending_downloads = dict(pending_downloads)
        pending_downloads.update(_PENDING_DOWNLOADS)
        pending_deletes = dict(pending_deletes)
        pending_deletes.update(_PENDING_DELETES)
        publications.pop(asset_id, None)
        pending_downloads.pop(asset_id, None)
        pending_deletes.pop(asset_id, None)
        _save_state(
            {
                "pending_publications": publications,
                "pending_downloads": pending_downloads,
                "pending_deletes": pending_deletes,
            },
            base_state=state,
        )
    except Exception as exc:
        log.warning("Could not finalize publication %s: %s", asset_id, exc)
        await notify_failure(
            "state_persist",
            "A Frame.io file was handed to the sorter but its recovery journal "
            "could not be cleared. Retry will not download a duplicate.",
            throttle_minutes=60,
        )
        return False
    _PENDING_DOWNLOADS.pop(asset_id, None)
    _PENDING_DELETES.pop(asset_id, None)
    return True


def _publication_fd_matches(temp_fd: int, entry: dict, *, private: bool) -> bool:
    try:
        node = os.fstat(temp_fd)
    except OSError:
        return False
    if (
        not stat.S_ISREG(node.st_mode)
        or node.st_dev != entry["dev"]
        or node.st_ino != entry["ino"]
        or node.st_nlink != 1
        or node.st_uid != os.geteuid()
        or node.st_size != entry["size"]
        or (private and node.st_mode & 0o077)
    ):
        return False
    try:
        return hmac.compare_digest(_sha256_fd(temp_fd), entry["sha256"])
    except OSError:
        return False


def _handoff_fd_matches(handoff_fd: int, entry: dict, *, private: bool) -> bool:
    try:
        node = os.fstat(handoff_fd)
    except OSError:
        return False
    if (
        not stat.S_ISREG(node.st_mode)
        or node.st_dev != entry.get("handoff_dev")
        or node.st_ino != entry.get("handoff_ino")
        or node.st_nlink != 1
        or node.st_uid != os.geteuid()
        or node.st_size != entry["size"]
        or (private and node.st_mode & 0o077)
    ):
        return False
    try:
        return hmac.compare_digest(_sha256_fd(handoff_fd), entry["sha256"])
    except OSError:
        return False


def _private_staging_is_canonical(
    staging: Path, directory_fd: int, expected_directory: os.stat_result
) -> bool:
    try:
        pinned = os.fstat(directory_fd)
        current = os.stat(staging, follow_symlinks=False)
    except OSError:
        return False
    return (
        _same_directory(pinned, expected_directory)
        and _same_directory(current, expected_directory)
        and pinned.st_uid == os.geteuid()
        and not pinned.st_mode & 0o077
    )


def _open_publication_temp(staging_fd: int, entry: dict) -> int:
    temp_fd = os.open(
        entry["temp_name"],
        os.O_RDWR | os.O_NONBLOCK | os.O_NOFOLLOW | os.O_CLOEXEC,
        dir_fd=staging_fd,
    )
    try:
        fcntl.flock(temp_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        path_node = os.stat(
            entry["temp_name"], dir_fd=staging_fd, follow_symlinks=False
        )
        if (
            path_node.st_dev != entry["dev"]
            or path_node.st_ino != entry["ino"]
            or not _publication_fd_matches(temp_fd, entry, private=True)
        ):
            raise RuntimeError("journaled temp failed inode/content validation")
        return temp_fd
    except Exception:
        os.close(temp_fd)
        raise


def _copy_stage_to_handoff(
    stage_fd: int, incoming_fd: int, asset_id: str, entry: dict
) -> tuple[int, str, os.stat_result]:
    asset_key = hashlib.sha256(asset_id.encode("utf-8")).hexdigest()[:16]
    handoff_fd, handoff_name, _created = _create_download_temp(incoming_fd, asset_key)
    try:
        offset = 0
        digest = hashlib.sha256()
        while offset < entry["size"]:
            chunk = os.pread(stage_fd, min(1024 * 1024, entry["size"] - offset), offset)
            if not chunk:
                raise RuntimeError("private staged file ended during handoff copy")
            digest.update(chunk)
            view = memoryview(chunk)
            while view:
                written = os.write(handoff_fd, view)
                view = view[written:]
            offset += len(chunk)
        if offset != entry["size"] or not hmac.compare_digest(
            digest.hexdigest(), entry["sha256"]
        ):
            raise RuntimeError("private staged bytes changed during handoff copy")
        os.fsync(handoff_fd)
        os.fsync(incoming_fd)
        return handoff_fd, handoff_name, os.fstat(handoff_fd)
    except Exception:
        expected = os.fstat(handoff_fd)
        os.close(handoff_fd)
        _remove_temp_if_same(incoming_fd, handoff_name, expected)
        raise


def _remove_private_stage_if_same(
    staging_fd: int, stage_name: str, expected: os.stat_result
) -> None:
    try:
        current = os.stat(stage_name, dir_fd=staging_fd, follow_symlinks=False)
        if _same_inode(current, expected) and current.st_nlink == 1:
            os.unlink(stage_name, dir_fd=staging_fd)
            os.fsync(staging_fd)
    except FileNotFoundError:
        pass
    except OSError as exc:
        log.warning("Could not remove completed private stage %s: %s", stage_name, exc)


def _reset_publication_handoff(
    asset_id: str,
    entry: dict,
    handoff_name: str,
    handoff_node: os.stat_result,
) -> bool:
    """Return a failed pre-publish journal to its private-stage phase."""
    state = _load_state(strict=True)
    raw_publications = state.get("pending_publications", {})
    if not isinstance(raw_publications, dict) or asset_id not in raw_publications:
        return False
    publications = dict(raw_publications)
    current = _validate_publication(asset_id, publications[asset_id])
    if current["phase"] != "renaming":
        return current["phase"] == "ready"
    if (
        current.get("handoff_name") != handoff_name
        or current.get("handoff_dev") != handoff_node.st_dev
        or current.get("handoff_ino") != handoff_node.st_ino
    ):
        return False
    current.update(
        phase="ready",
        destination_name=None,
        handoff_name=None,
        handoff_dev=None,
        handoff_ino=None,
    )
    _validate_publication(asset_id, current)
    publications[asset_id] = current
    _save_state({"pending_publications": publications}, base_state=state)
    entry.clear()
    entry.update(current)
    return True


async def _commit_handoff(
    asset_id: str,
    entry: dict,
    incoming_dir: Path,
    incoming_fd: int,
    expected_incoming: os.stat_result,
    staging_fd: int,
    stage_fd: int,
    handoff_fd: int,
    handoff_name: str,
    handoff_node: os.stat_result,
    *,
    on_committed=None,
) -> str:
    if not _incoming_directory_is_canonical(
        incoming_dir, incoming_fd, expected_incoming
    ):
        return "error"
    _require_rename_noreplace(incoming_fd)

    def journal_destination(destination_name: str) -> None:
        updated = _set_publication_destination(
            asset_id, destination_name, handoff_name, handoff_node
        )
        entry.clear()
        entry.update(updated)

    destination_name = _publish_no_clobber(
        incoming_fd,
        handoff_fd,
        handoff_name,
        entry["filename"],
        handoff_node,
        before_publish=journal_destination,
        after_publish=(lambda _destination: on_committed())
        if on_committed is not None
        else None,
        finalize_mode=False,
    )
    if destination_name is None:
        return "collision_overflow"
    if not await _fd_to_thread(
        _handoff_fd_matches, handoff_fd, entry, private=True
    ):
        await notify_failure(
            "handoff_validation_failed",
            f"Asset {asset_id[:8]}… changed during sorter handoff. Its private "
            "staged copy was preserved for manual recovery.",
            throttle_minutes=15,
        )
        return "publication_invalid"
    os.fchmod(handoff_fd, 0o664)
    os.fsync(handoff_fd)
    os.fsync(incoming_fd)
    if not await _finish_publication(asset_id):
        return "publication_finalize_failed"
    stage_node = os.fstat(stage_fd)
    _remove_private_stage_if_same(staging_fd, entry["temp_name"], stage_node)
    log.info("Published %s", destination_name)
    if entry["policy"] == "retain":
        log.info("Asset %s retained in Frame.io (retention policy)", asset_id)
        return "retained"
    return "ok"


async def _expose_publication(
    asset_id: str,
    entry: dict,
    incoming_dir: Path,
    incoming_fd: int,
    expected_incoming: os.stat_result,
    staging_fd: int,
    stage_fd: int,
) -> str:
    state = _load_state(strict=True)
    if not _publication_receipt_is_durable(asset_id, entry, state):
        return "receipt_failed"
    if not await _fd_to_thread(
        _publication_fd_matches, stage_fd, entry, private=True
    ):
        return "publication_invalid"
    handoff_fd: int | None = None
    handoff_name: str | None = None
    handoff_node: os.stat_result | None = None
    published = False
    safe_to_remove_handoff = False
    try:
        def discard_cancelled_handoff(result) -> None:
            cancelled_fd, cancelled_name, cancelled_node = result
            try:
                _remove_temp_if_same(
                    incoming_fd, cancelled_name, cancelled_node
                )
            finally:
                os.close(cancelled_fd)

        handoff_fd, handoff_name, handoff_node = await _fd_to_thread(
            _copy_stage_to_handoff,
            stage_fd,
            incoming_fd,
            asset_id,
            entry,
            cancel_cleanup=discard_cancelled_handoff,
        )

        def mark_committed() -> None:
            nonlocal published
            published = True

        result = await _commit_handoff(
            asset_id,
            entry,
            incoming_dir,
            incoming_fd,
            expected_incoming,
            staging_fd,
            stage_fd,
            handoff_fd,
            handoff_name,
            handoff_node,
            on_committed=mark_committed,
        )
        return result
    finally:
        if not published and handoff_name is not None and handoff_node is not None:
            try:
                # The state replace may have committed even if its directory
                # fsync raised before `_set_publication_destination` returned,
                # so the local entry phase is not authoritative here. Consult
                # and reset the persisted exact handoff on every failure.
                # State transactions stay on the event-loop thread beside all
                # other read/modify/write operations.
                safe_to_remove_handoff = _reset_publication_handoff(
                    asset_id, entry, handoff_name, handoff_node
                )
            except Exception:
                log.exception(
                    "Could not reset failed handoff journal for %s", asset_id
                )
            if safe_to_remove_handoff:
                _remove_temp_if_same(incoming_fd, handoff_name, handoff_node)
        if handoff_fd is not None:
            os.close(handoff_fd)


async def _resume_publication(
    client: httpx.AsyncClient, account_id: str, asset_id: str
) -> str | None:
    publications = _pending_publications(strict=True)
    entry = publications.get(asset_id)
    if entry is None:
        return None
    incoming_dir = Path(CFG["incoming_dir"])
    staging_dir = Path(CFG["staging_dir"])
    incoming_fd: int | None = None
    expected_incoming: os.stat_result | None = None
    staging_fd: int | None = None
    expected_staging: os.stat_result | None = None
    stage_fd: int | None = None
    handoff_fd: int | None = None
    try:
        incoming_fd, expected_incoming = _open_incoming_dir(incoming_dir)
        staging_fd, expected_staging = _open_private_staging_dir(staging_dir)
        _require_private_staging_mount(staging_fd, incoming_fd)
        try:
            # Opening includes a full SHA-256 pass, which can be large enough to
            # block public webhook/health handling if done on the event loop.
            stage_fd = await _fd_to_thread(
                _open_publication_temp,
                staging_fd,
                entry,
                cancel_cleanup=os.close,
            )
        except FileNotFoundError:
            await notify_failure(
                "publication_missing",
                f"Asset {asset_id[:8]}… has a recovery journal but its private "
                "staged copy is missing. No retry state was cleared.",
                throttle_minutes=60,
            )
            return "publication_missing"

        if not _private_staging_is_canonical(
            staging_dir, staging_fd, expected_staging
        ):
            return "publication_invalid"

        if entry["phase"] == "renaming":
            try:
                handoff_fd = os.open(
                    entry["handoff_name"],
                    os.O_RDWR | os.O_NONBLOCK | os.O_NOFOLLOW | os.O_CLOEXEC,
                    dir_fd=incoming_fd,
                )
            except FileNotFoundError:
                destination_name = entry["destination_name"]
                try:
                    destination_fd = os.open(
                        destination_name,
                        os.O_RDWR | os.O_NONBLOCK | os.O_NOFOLLOW | os.O_CLOEXEC,
                        dir_fd=incoming_fd,
                    )
                except FileNotFoundError:
                    await notify_failure(
                        "handoff_ambiguous",
                        f"Asset {asset_id[:8]}… was in final handoff but neither "
                        "journaled intake name remains. The private staged copy is "
                        "preserved; inspect sorted/quarantine before retrying.",
                        throttle_minutes=60,
                    )
                    return "publication_missing"
                try:
                    if not await _fd_to_thread(
                        _handoff_fd_matches, destination_fd, entry, private=False
                    ):
                        return "publication_invalid"
                    os.fchmod(destination_fd, 0o664)
                    os.fsync(destination_fd)
                    os.fsync(incoming_fd)
                finally:
                    os.close(destination_fd)
                if not await _finish_publication(asset_id):
                    return "publication_finalize_failed"
                _remove_private_stage_if_same(
                    staging_fd, entry["temp_name"], os.fstat(stage_fd)
                )
                return "retained" if entry["policy"] == "retain" else "ok"
            else:
                try:
                    if not await _fd_to_thread(
                        _handoff_fd_matches, handoff_fd, entry, private=True
                    ):
                        return "publication_invalid"
                    handoff_node = os.fstat(handoff_fd)
                    return await _commit_handoff(
                        asset_id,
                        entry,
                        incoming_dir,
                        incoming_fd,
                        expected_incoming,
                        staging_fd,
                        stage_fd,
                        handoff_fd,
                        entry["handoff_name"],
                        handoff_node,
                    )
                finally:
                    os.close(handoff_fd)
                    handoff_fd = None

        if entry["policy"] == "delete" and entry["phase"] == "delete_pending":
            if not CFG["delete_upstream"]:
                converted = await _convert_publication_to_retain(asset_id)
                if converted is None:
                    return "receipt_failed"
                entry = converted
            else:
                _require_rename_noreplace(incoming_fd)

                def local_guard() -> bool:
                    try:
                        path_node = os.stat(
                            entry["temp_name"],
                            dir_fd=staging_fd,
                            follow_symlinks=False,
                        )
                    except OSError:
                        return False
                    return (
                        _private_staging_is_canonical(
                            staging_dir, staging_fd, expected_staging
                        )
                        and path_node.st_dev == entry["dev"]
                        and path_node.st_ino == entry["ino"]
                        and _publication_fd_matches(stage_fd, entry, private=True)
                    )

                delete_result = await _delete_upstream(
                    client, entry["account_id"], asset_id, local_guard=local_guard
                )
                if delete_result is not True:
                    return "error" if delete_result is None else "delete_failed"
                advanced = await _record_publication_deleted(asset_id)
                if advanced is None:
                    return "delete_finalize_failed"
                entry = advanced
        return await _expose_publication(
            asset_id,
            entry,
            incoming_dir,
            incoming_fd,
            expected_incoming,
            staging_fd,
            stage_fd,
        )
    finally:
        if handoff_fd is not None:
            os.close(handoff_fd)
        if stage_fd is not None:
            os.close(stage_fd)
        if staging_fd is not None:
            os.close(staging_fd)
        if incoming_fd is not None:
            os.close(incoming_fd)


async def process_asset(account_id: str, asset_id: str) -> str:
    """Fetch metadata+download URL via the V4 account-scoped file endpoint
    (one call with ?include=media_links.original) and stream to incoming."""
    # In-flight dedup: skip if another task is already processing this asset
    async with _IN_FLIGHT_LOCK:
        if asset_id in _IN_FLIGHT:
            log.info("Asset %s already in-flight — skipping duplicate", asset_id)
            return "in_flight"
        _IN_FLIGHT.add(asset_id)
    try:
        async with _PROCESS_SEMAPHORE:
            result = await _process_asset_inner(account_id, asset_id)
        return result
    finally:
        async with _IN_FLIGHT_LOCK:
            _IN_FLIGHT.discard(asset_id)


def _write_all(fd: int, data: bytes) -> None:
    view = memoryview(data)
    while view:
        written = os.write(fd, view)
        if written <= 0:
            raise OSError(errno.EIO, "short write to private staging")
        view = view[written:]


async def _download_to_stage(
    client: httpx.AsyncClient, download_url: str, stage_fd: int
) -> tuple[int, str]:
    """Stream one download with hard byte and wall-clock ceilings."""
    downloaded = 0
    digest = hashlib.sha256()
    max_bytes = CFG["download_max_bytes"]
    timeout = httpx.Timeout(connect=30, read=120, write=30, pool=30)
    async with asyncio.timeout(CFG["download_max_seconds"]):
        async with client.stream(
            "GET", download_url, timeout=timeout
        ) as stream:
            stream.raise_for_status()
            # httpx responses always expose Headers; accepting a minimal empty
            # mapping also keeps the streaming helper easy to exercise in unit
            # tests without weakening the cumulative byte ceiling.
            declared_raw = getattr(stream, "headers", {}).get("content-length")
            if declared_raw is not None:
                try:
                    declared = int(declared_raw, 10)
                except ValueError as exc:
                    raise DownloadSafetyError(
                        "download Content-Length is invalid"
                    ) from exc
                if declared < 0 or declared > max_bytes:
                    raise DownloadSafetyError(
                        f"download exceeds {max_bytes} byte ceiling"
                    )
            async for chunk in stream.aiter_bytes(chunk_size=1024 * 1024):
                if not chunk:
                    continue
                if len(chunk) > max_bytes - downloaded:
                    raise DownloadSafetyError(
                        f"download exceeds {max_bytes} byte ceiling"
                    )
                await _fd_to_thread(_write_all, stage_fd, chunk)
                downloaded += len(chunk)
                digest.update(chunk)
    return downloaded, digest.hexdigest()


def _sync_private_stage(stage_fd: int, staging_fd: int) -> os.stat_result:
    os.fsync(stage_fd)
    node = os.fstat(stage_fd)
    os.fsync(staging_fd)
    return node


async def _process_asset_inner(account_id: str, asset_id: str) -> str:
    """Returns a status string: 'ok', 'no_url', 'size_mismatch',
    'download_too_large', 'download_timeout', 'collision_overflow',
    'receipt_failed', 'http_<code>', or 'error'."""
    incoming_dir = Path(CFG["incoming_dir"])
    staging_dir = Path(CFG["staging_dir"])
    incoming_fd: int | None = None
    expected_incoming: os.stat_result | None = None
    staging_fd: int | None = None
    expected_staging: os.stat_result | None = None
    stage_fd: int | None = None
    stage_name: str | None = None
    expected_stage: os.stat_result | None = None
    journaled = False

    file_url = f"{FRAMEIO_API}/accounts/{account_id}/files/{asset_id}"

    async with httpx.AsyncClient(follow_redirects=True) as client:
        try:
            recovered = await _resume_publication(client, account_id, asset_id)
            if recovered is not None:
                return recovered

            if asset_id in _completed_deletes(strict=True):
                log.info("Asset %s was already deleted upstream; clearing replay job", asset_id)
                await _clear_pending_download(asset_id)
                return "ok"

            if asset_id in _retained_assets(strict=True):
                log.info("Asset %s was already mirrored and intentionally retained", asset_id)
                if _retained_asset_is_durable(asset_id, strict=True) \
                        or await _save_retained_asset(asset_id):
                    await _clear_pending_download(asset_id)
                    return "retained"
                return "receipt_failed"

            pending_account = _pending_deletes(strict=True).get(asset_id)
            if pending_account:
                # Pre-journal versions stored only an asset/account pair after
                # publication, which is not enough cryptographic evidence to
                # authorize a later DELETE. Migrate it to safe retention.
                log.warning(
                    "Asset %s has a legacy delete receipt without byte evidence; retaining upstream",
                    asset_id,
                )
                if not await _save_retained_asset(asset_id):
                    return "receipt_failed"
                await _clear_pending_delete(asset_id)
                await _clear_pending_download(asset_id)
                await notify_failure(
                    "legacy_delete_retained",
                    "A legacy Frame.io delete retry lacked a byte journal and was "
                    "safely converted to retention. No upstream file was deleted.",
                    throttle_minutes=1440,
                )
                return "retained"

            incoming_fd, expected_incoming = _open_incoming_dir(incoming_dir)
            staging_fd, expected_staging = _open_private_staging_dir(staging_dir)
            _require_private_staging_mount(staging_fd, incoming_fd)

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
            try:
                body = meta_resp.json()
            except (TypeError, ValueError, json.JSONDecodeError):
                log.error("Malformed metadata JSON for %s", asset_id)
                await notify_failure(
                    "metadata_invalid",
                    f"Asset {asset_id[:8]}… returned malformed metadata. Upstream was preserved.",
                    throttle_minutes=15,
                )
                return "metadata_invalid"
            if not isinstance(body, dict):
                log.error("Metadata root is not an object for %s", asset_id)
                return "metadata_invalid"

            asset_key = hashlib.sha256(asset_id.encode("utf-8")).hexdigest()[:16]
            filename_raw = _pick(body, "name", "filename", "file_name")
            filename = _safe_filename(filename_raw, fallback=f"{asset_key}.bin")
            if filename_raw and filename != filename_raw:
                log.warning("Filename sanitized: %r -> %r", filename_raw, filename)
            expected_size_raw = _pick(body, "file_size", "filesize", "size")
            expected_size: int | None = None
            if expected_size_raw is not None:
                if (
                    isinstance(expected_size_raw, int)
                    and not isinstance(expected_size_raw, bool)
                    and expected_size_raw > 0
                ):
                    expected_size = expected_size_raw
                elif (
                    isinstance(expected_size_raw, str)
                    and len(expected_size_raw) <= 20
                    and re.fullmatch(r"[1-9][0-9]*", expected_size_raw)
                ):
                    expected_size = int(expected_size_raw, 10)
                if expected_size is None:
                    log.warning(
                        "Invalid file size metadata for %s: %r",
                        asset_id,
                        expected_size_raw,
                    )
            if expected_size is not None and expected_size > CFG["download_max_bytes"]:
                log.warning(
                    "Asset %s metadata size %d exceeds configured ceiling",
                    asset_id,
                    expected_size,
                )
                await notify_failure(
                    "download_too_large",
                    f"{filename}: metadata size {expected_size:,} exceeds the "
                    f"{CFG['download_max_bytes']:,}-byte download ceiling. Upstream was preserved.",
                    throttle_minutes=60,
                )
                return "download_too_large"

            # Discover the C2C ingest folder for reconciliation, persist on first hit
            data_obj = body.get("data") if isinstance(body.get("data"), dict) else body
            parent = data_obj.get("parent") if isinstance(data_obj, dict) else None
            parent_folder = (
                (data_obj.get("parent_id") if isinstance(data_obj, dict) else None)
                or (data_obj.get("folder_id") if isinstance(data_obj, dict) else None)
                or (parent.get("id") if isinstance(parent, dict) else None)
            )
            await _remember_c2c_folder(parent_folder, account_id)

            # media_links.original may be at top-level or under data.*
            data = body.get("data") if isinstance(body.get("data"), dict) else body
            media_links = (data.get("media_links") or {}) if isinstance(data, dict) else {}
            original = media_links.get("original") or {}
            if isinstance(original, str):
                download_url = original
            else:
                download_url = original.get("url") or original.get("download_url")
            if (
                not isinstance(download_url, str)
                or not download_url
                or len(download_url) > 8192
                or urlsplit(download_url).scheme.lower() != "https"
            ):
                log.error("No media_links.original URL in response for %s", asset_id)
                return "no_url"

            # Random O_EXCL temp prevents a share client from preplanting a
            # symlink at a predictable name. Keep the descriptor open through
            # publish so the inode can be checked after every pathname lookup.
            stage_fd, stage_name, expected_stage = _create_download_temp(
                staging_fd, asset_key
            )

            # Stream to the hidden temp inode (sorter ignores dotfiles), then
            # journal the exact bytes before any policy action. Final naming
            # happens only after the retention receipt or upstream delete is
            # durable, so the sorter cannot consume an untracked publication.
            log.info("Downloading %s", filename)
            downloaded, download_digest = await _download_to_stage(
                client, download_url, stage_fd
            )
            expected_stage = await _fd_to_thread(
                _sync_private_stage, stage_fd, staging_fd
            )
            log.info("Downloaded %d bytes for %s", downloaded, filename)

            if downloaded <= 0 or expected_stage.st_size != downloaded:
                log.warning("Empty or unstable download for %s — upstream preserved", filename)
                return "size_mismatch"
            if expected_size and downloaded != expected_size:
                log.warning(
                    "Size mismatch for %s: expected=%d got=%d — NOT deleting upstream",
                    filename, expected_size, downloaded,
                )
                await notify_failure(
                    "size_mismatch",
                    f"{filename}: expected {expected_size:,} bytes, got {downloaded:,}. "
                    "Upstream not deleted; partial temp removed so retry stays bounded.",
                    throttle_minutes=15,
                )
                return "size_mismatch"
            if expected_size:
                log.info("Size verified for %s (%d bytes)", filename, downloaded)
            else:
                log.info("No size in metadata for %s — skipping size check", filename)

            if not _private_staging_is_canonical(
                staging_dir, staging_fd, expected_staging
            ):
                log.error("Private staging path changed after download — upstream preserved")
                return "error"
            if not _incoming_directory_is_canonical(
                incoming_dir, incoming_fd, expected_incoming
            ):
                log.error("Incoming path changed after download — private stage preserved")
                return "error"

            policy = (
                "delete"
                if CFG["delete_upstream"] and expected_size is not None
                else "retain"
            )
            # From this point onward a state replace may have committed even if
            # its final directory fsync reports an error. Preserve the private
            # stage on every receipt outcome so a commit-uncertain journal can
            # never point at bytes that our finally block removed.
            journaled = True
            entry = await _begin_publication(
                asset_id,
                account_id,
                stage_name,
                filename,
                expected_stage,
                downloaded,
                download_digest,
                expected_size,
                policy,
            )
            if entry is None:
                visibility = _publication_stage_visibility(
                    asset_id,
                    account_id,
                    stage_name,
                    expected_stage,
                    downloaded,
                    download_digest,
                )
                if visibility is False:
                    # The authoritative state was readable and contains no
                    # reference to these exact bytes, so this was a definite
                    # pre-commit failure and immediate cleanup is bounded/safe.
                    journaled = False
                return "receipt_failed"

            # Probe the real intake filesystem after the private bytes and
            # recovery journal are durable, but before any optional upstream
            # deletion. A missing kernel/filesystem primitive now preserves the
            # local stage for a later retry instead of redownloading it.
            _require_rename_noreplace(incoming_fd)

            if policy == "retain" and expected_size is None and CFG["delete_upstream"]:
                log.warning(
                    "Asset %s retained upstream because API size was missing/invalid",
                    asset_id,
                )
                await notify_failure(
                    "missing_size_no_delete",
                    f"{filename}: downloaded locally, but Frame.io supplied no "
                    "valid size. Upstream was retained.",
                    throttle_minutes=60,
                )

            if policy == "delete":
                def local_guard() -> bool:
                    try:
                        path_node = os.stat(
                            stage_name,
                            dir_fd=staging_fd,
                            follow_symlinks=False,
                        )
                    except OSError:
                        return False
                    return (
                        _private_staging_is_canonical(
                            staging_dir, staging_fd, expected_staging
                        )
                        and path_node.st_dev == entry["dev"]
                        and path_node.st_ino == entry["ino"]
                        and _publication_fd_matches(
                            stage_fd, entry, private=True
                        )
                    )

                log.info("Deleting asset %s from Frame.io", asset_id)
                delete_result = await _delete_upstream(
                    client, account_id, asset_id, local_guard=local_guard
                )
                if delete_result is not True:
                    return "error" if delete_result is None else "delete_failed"
                advanced = await _record_publication_deleted(asset_id)
                if advanced is None:
                    return "delete_finalize_failed"
                entry = advanced

            return await _expose_publication(
                asset_id,
                entry,
                incoming_dir,
                incoming_fd,
                expected_incoming,
                staging_fd,
                stage_fd,
            )

        except DownloadSafetyError as exc:
            log.warning("Download safety limit for asset %s: %s", asset_id, exc)
            await notify_failure(
                "download_too_large",
                f"Asset {asset_id[:8]}… exceeded the configured download byte ceiling. "
                "Upstream was preserved and partial private bytes were discarded.",
                throttle_minutes=60,
            )
            return "download_too_large"
        except TimeoutError:
            log.warning("Download wall-clock limit reached for asset %s", asset_id)
            await notify_failure(
                "download_timeout",
                f"Asset {asset_id[:8]}… exceeded the configured download time limit. "
                "Upstream was preserved and partial private bytes were discarded.",
                throttle_minutes=15,
            )
            return "download_timeout"
        except httpx.HTTPStatusError as exc:
            sc = exc.response.status_code
            safe_url = _redact_url(exc.request.url)  # strip pre-signed AWS creds in query
            try:
                response_excerpt = exc.response.text[:200]
            except (httpx.ResponseNotRead, httpx.StreamConsumed):
                response_excerpt = "<streaming response body not read>"
            log.error(
                "HTTP error processing asset %s: %s %s (%s)",
                asset_id, sc, response_excerpt, safe_url,
            )
            await notify_failure(
                f"http_{sc}",
                f"Asset {asset_id[:8]}…: HTTP {sc} from {safe_url}\n{response_excerpt}",
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
        finally:
            if (
                not journaled
                and staging_fd is not None
                and stage_name is not None
                and expected_stage is not None
            ):
                _remove_private_stage_if_same(
                    staging_fd, stage_name, expected_stage
                )
            if stage_fd is not None:
                try:
                    os.close(stage_fd)
                except OSError:
                    pass
            if staging_fd is not None:
                os.close(staging_fd)
            if incoming_fd is not None:
                os.close(incoming_fd)
