import asyncio
import hashlib
import hmac
import json
import os
import tempfile
import threading
import time
import unittest
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from unittest.mock import AsyncMock, patch

import app
from fastapi import BackgroundTasks, HTTPException
from starlette.requests import Request


def write_private_state(path: Path, value="{}") -> None:
    path.write_text(value)
    path.chmod(0o600)


class FakeResponse:
    def __init__(self, status_code=200, body=None, text=""):
        self.status_code = status_code
        self._body = {} if body is None else body
        self.text = text

    def json(self):
        return self._body

    def raise_for_status(self):
        if self.status_code >= 400:
            raise RuntimeError(f"unexpected HTTP {self.status_code} in test")


class FakeStream:
    status_code = 200

    def __init__(self, payload):
        self.payload = payload
        self.headers = {}

    async def __aenter__(self):
        return self

    async def __aexit__(self, *_args):
        return False

    async def aiter_bytes(self, chunk_size=65536):
        del chunk_size
        yield self.payload

    async def aread(self):
        return self.payload

    def raise_for_status(self):
        if self.status_code >= 400:
            raise RuntimeError(f"unexpected HTTP {self.status_code} in test")


class FailingStream(FakeStream):
    async def aiter_bytes(self, chunk_size=65536):
        del chunk_size
        yield self.payload[:2]
        raise OSError("simulated stream failure")


class ChunkedStream(FakeStream):
    def __init__(self, *chunks):
        self.chunks = chunks
        self.payload = b"".join(chunks)
        self.headers = {}

    async def aiter_bytes(self, chunk_size=65536):
        del chunk_size
        for chunk in self.chunks:
            yield chunk


class SlowStream(FakeStream):
    async def aiter_bytes(self, chunk_size=65536):
        del chunk_size
        await asyncio.sleep(60)
        yield self.payload


class FakeClient:
    def __init__(self, payload, delete_statuses, counters, metadata=None):
        self.payload = payload
        self.delete_statuses = delete_statuses
        self.counters = counters
        self.metadata = metadata

    async def __aenter__(self):
        return self

    async def __aexit__(self, *_args):
        return False

    async def get(self, *_args, **_kwargs):
        self.counters["get"] += 1
        body = self.metadata if self.metadata is not None else {
            "name": "camera.bin",
            "file_size": len(self.payload),
            "parent_id": "folder-1",
            "media_links": {"original": {"url": "https://download.invalid/file"}},
        }
        return FakeResponse(body=body)

    def stream(self, *_args, **_kwargs):
        self.counters["stream"] += 1
        return FakeStream(self.payload)

    async def delete(self, *_args, **_kwargs):
        self.counters["delete"] += 1
        status = self.delete_statuses.pop(0)
        return FakeResponse(status_code=status, text="delete test")


class ListingClient:
    async def __aenter__(self):
        return self

    async def __aexit__(self, *_args):
        return False

    async def get(self, *_args, **_kwargs):
        return FakeResponse(
            body={
                "data": [{"type": "file", "id": "asset-ghost"}],
                "links": {},
            }
        )


class ManyPageClient:
    def __init__(self, pages=21):
        self.pages = pages
        self.calls = 0

    async def __aenter__(self):
        return self

    async def __aexit__(self, *_args):
        return False

    async def get(self, *_args, **_kwargs):
        index = self.calls
        self.calls += 1
        links = {"next": f"?after={index + 1}"} if index + 1 < self.pages else {}
        return FakeResponse(
            body={
                "data": [{"type": "file", "id": f"asset-{index}"}],
                "links": links,
            }
        )


class ExpiredCursorClient:
    def __init__(self):
        self.urls = []

    async def __aenter__(self):
        return self

    async def __aexit__(self, *_args):
        return False

    async def get(self, url, *_args, **_kwargs):
        url = str(url)
        self.urls.append(url)
        if "after=expired" in url:
            return FakeResponse(status_code=410, text="cursor expired")
        return FakeResponse(
            body={
                "data": [{"type": "file", "id": "asset-after-reset"}],
                "links": {},
            }
        )


class FrameioSafetyTests(unittest.IsolatedAsyncioTestCase):
    def setUp(self):
        self.original_cfg = dict(app.CFG)
        self.runtime_paths = tempfile.TemporaryDirectory()
        runtime_root = Path(os.path.realpath(self.runtime_paths.name))
        runtime_incoming = runtime_root / "incoming"
        runtime_staging = runtime_root / "staging"
        runtime_state = runtime_root / "state.json"
        runtime_incoming.mkdir()
        runtime_staging.mkdir(mode=0o700)
        runtime_staging.chmod(0o700)
        write_private_state(runtime_state)
        app.CFG.update(
            incoming_dir=str(runtime_incoming),
            staging_dir=str(runtime_staging),
            refresh_token_file=str(runtime_state),
        )
        self.original_semaphore = app._PROCESS_SEMAPHORE
        self.original_job_queue = app._JOB_QUEUE
        self.original_queue_lock = app._QUEUE_LOCK
        self.original_in_flight_lock = app._IN_FLIGHT_LOCK
        self.original_health_lock = app._HEALTH_LOCK
        self.original_health_cache = dict(app._HEALTH_CACHE)
        self.original_reconcile_rotation = app._RECONCILE_ROTATION
        app._PROCESS_SEMAPHORE = asyncio.Semaphore(app.CFG["frameio_workers"])
        app._JOB_QUEUE = asyncio.Queue(maxsize=app.CFG["frameio_queue_size"])
        app._QUEUE_LOCK = asyncio.Lock()
        app._IN_FLIGHT_LOCK = asyncio.Lock()
        app._HEALTH_LOCK = asyncio.Lock()
        app._IN_FLIGHT.clear()
        app._QUEUED_ASSETS.clear()
        app._PENDING_DOWNLOADS.clear()
        app._PENDING_DELETES.clear()
        app._RETAINED_ASSETS.clear()
        app._COMPLETED_DELETES.clear()
        app._RENAME_NOREPLACE_FILESYSTEMS.clear()
        app._HEALTH_CACHE.clear()
        app._HEALTH_CACHE.update(expires_at=0.0, status_code=503, body={})
        app._RECONCILE_ROTATION = 0
        # Ordinary temp-directory tests cannot create distinct Linux mounts.
        # Production still enforces the separate private staging mount.
        self.mount_patcher = patch.object(
            app, "_require_private_staging_mount", return_value=None
        )
        self.mount_patcher.start()
        # macOS exposes temporary paths through /var -> /private/var. Production
        # canonical-path enforcement is exercised explicitly in release tests.
        self.state_parent_patcher = patch.object(
            app, "_state_parent_path_is_canonical", return_value=True
        )
        self.state_parent_patcher.start()
        def portable_rename_noreplace(directory_fd, source, destination):
            os.link(
                source,
                destination,
                src_dir_fd=directory_fd,
                dst_dir_fd=directory_fd,
                follow_symlinks=False,
            )
            os.unlink(source, dir_fd=directory_fd)

        self.rename_patcher = patch.object(
            app, "_rename_noreplace", side_effect=portable_rename_noreplace
        )
        self.rename_patcher.start()

    def tearDown(self):
        self.rename_patcher.stop()
        self.state_parent_patcher.stop()
        self.mount_patcher.stop()
        app.CFG.clear()
        app.CFG.update(self.original_cfg)
        app._PROCESS_SEMAPHORE = self.original_semaphore
        app._JOB_QUEUE = self.original_job_queue
        app._QUEUE_LOCK = self.original_queue_lock
        app._IN_FLIGHT_LOCK = self.original_in_flight_lock
        app._HEALTH_LOCK = self.original_health_lock
        app._IN_FLIGHT.clear()
        app._QUEUED_ASSETS.clear()
        app._PENDING_DOWNLOADS.clear()
        app._PENDING_DELETES.clear()
        app._RETAINED_ASSETS.clear()
        app._COMPLETED_DELETES.clear()
        app._RENAME_NOREPLACE_FILESYSTEMS.clear()
        app._HEALTH_CACHE.clear()
        app._HEALTH_CACHE.update(self.original_health_cache)
        app._RECONCILE_ROTATION = self.original_reconcile_rotation
        self.runtime_paths.cleanup()

    async def _drain_job_queue(self, timeout: float = 1.0) -> None:
        workers = [
            asyncio.create_task(app._asset_worker(index + 1))
            for index in range(app.CFG["frameio_workers"])
        ]
        try:
            await asyncio.wait_for(app._JOB_QUEUE.join(), timeout=timeout)
        finally:
            for worker in workers:
                worker.cancel()
            await asyncio.gather(*workers, return_exceptions=True)

    def configure_paths(
        self,
        root: Path,
        *,
        state_value="{}",
        create_state: bool = True,
    ) -> tuple[Path, Path, Path]:
        incoming = root / "incoming"
        staging = root / "staging"
        state = root / "state.json"
        incoming.mkdir()
        staging.mkdir(mode=0o700)
        staging.chmod(0o700)
        if create_state:
            write_private_state(state, state_value)
        app.CFG.update(
            incoming_dir=str(incoming),
            staging_dir=str(staging),
            refresh_token_file=str(state),
        )
        return incoming, staging, state

    def test_reserved_and_unicode_names_fit_sorter_contract(self):
        names = [".hidden.ARW", "clip.tmp", "clip.part", "clip.filepart", "Thumbs.db"]
        for name in names:
            safe = app._safe_filename(name, "fallback.bin")
            self.assertFalse(safe.startswith("."), safe)
            self.assertNotEqual(safe, "Thumbs.db")
            self.assertFalse(safe.endswith((".tmp", ".part", ".filepart")), safe)
        long_name = f"{'界' * 300}.ARW"
        safe = app._safe_filename(long_name, "fallback.bin")
        self.assertLessEqual(len(safe.encode("utf-8")), 220)
        self.assertTrue(safe.endswith(".ARW"))

    def test_atomic_publish_preserves_two_same_name_payloads(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(os.path.realpath(directory))
            directory_fd, _expected_directory = app._open_incoming_dir(root)
            records = []
            for index, payload in enumerate((b"FIRST", b"SECOND"), start=1):
                fd, temp_name, _created = app._create_download_temp(
                    directory_fd, f"asset{index}"
                )
                os.write(fd, payload)
                os.fsync(fd)
                records.append((fd, temp_name, os.fstat(fd)))

            real_rename = app._rename_noreplace
            gate = threading.Barrier(2)

            def gated_rename(directory_fd, src, dst):
                if dst == "same.ARW":
                    gate.wait(timeout=5)
                return real_rename(directory_fd, src, dst)

            with patch.object(app, "_rename_noreplace", side_effect=gated_rename):
                with ThreadPoolExecutor(max_workers=2) as pool:
                    futures = [
                        pool.submit(
                            app._publish_no_clobber,
                            directory_fd,
                            _fd,
                            temp_name,
                            "same.ARW",
                            expected,
                        )
                        for _fd, temp_name, expected in records
                    ]
                    destinations = [future.result(timeout=10) for future in futures]
            for fd, _temp_name, _expected in records:
                os.close(fd)
            os.close(directory_fd)

            self.assertEqual(set(destinations), {"same.ARW", "same_2.ARW"})
            hashes = {
                hashlib.sha256((root / name).read_bytes()).hexdigest()
                for name in destinations
            }
            self.assertEqual(
                hashes,
                {hashlib.sha256(b"FIRST").hexdigest(), hashlib.sha256(b"SECOND").hexdigest()},
            )

    def test_swapped_temp_symlink_is_never_published_or_opened(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(os.path.realpath(directory))
            sentinel = root / "sentinel"
            sentinel.write_bytes(b"KEEP")
            directory_fd, _expected_directory = app._open_incoming_dir(root)
            fd, temp_name, _created = app._create_download_temp(
                directory_fd, "real"
            )
            os.write(fd, b"CAMERA")
            expected = os.fstat(fd)
            os.rename(
                temp_name,
                "displaced",
                src_dir_fd=directory_fd,
                dst_dir_fd=directory_fd,
            )
            os.symlink("sentinel", temp_name, dir_fd=directory_fd)
            with self.assertRaises(RuntimeError):
                app._publish_no_clobber(
                    directory_fd, fd, temp_name, "camera.ARW", expected
                )
            os.close(fd)
            os.close(directory_fd)
            self.assertEqual(sentinel.read_bytes(), b"KEEP")
            self.assertFalse((root / "camera.ARW").exists())

    async def test_unwritable_state_preserves_upstream_and_defers_publication(self):
        payload = b"camera payload"
        counters = {"get": 0, "stream": 0, "delete": 0}
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            incoming, _staging, _state = self.configure_paths(
                root, create_state=False
            )
            app.CFG.update(
                refresh_token_file=str(root / "missing" / "state.json"),
                c2c_folder_id="",
                c2c_account_id="",
                delete_upstream=False,
            )
            client = FakeClient(payload, [204], counters)
            with (
                patch.object(app.httpx, "AsyncClient", return_value=client),
                patch.object(app, "get_token", AsyncMock(return_value="token")),
                patch.object(app, "notify_failure", AsyncMock()),
            ):
                status = await app._process_asset_inner("account-1", "asset-1")
            self.assertEqual(status, "receipt_failed")
            self.assertEqual(list(incoming.iterdir()), [])
            self.assertEqual(counters, {"get": 1, "stream": 1, "delete": 0})
            self.assertEqual(app.CFG["c2c_folder_id"], "folder-1")

    async def test_advertised_oversize_is_rejected_before_streaming(self):
        payload = b"not downloaded"
        counters = {"get": 0, "stream": 0, "delete": 0}
        metadata = {
            "name": "huge.ARW",
            "file_size": 11,
            "parent_id": "folder-1",
            "media_links": {"original": {"url": "https://download.invalid/file"}},
        }
        with tempfile.TemporaryDirectory() as directory:
            _incoming, staging, _state = self.configure_paths(Path(directory))
            app.CFG.update(delete_upstream=True, download_max_bytes=10)
            client = FakeClient(payload, [204], counters, metadata=metadata)
            with (
                patch.object(app.httpx, "AsyncClient", return_value=client),
                patch.object(app, "get_token", AsyncMock(return_value="token")),
                patch.object(app, "notify_failure", AsyncMock()),
            ):
                status = await app.process_asset("account-1", "asset-too-large")

            self.assertEqual(status, "download_too_large")
            self.assertEqual(counters, {"get": 1, "stream": 0, "delete": 0})
            self.assertEqual(list(staging.iterdir()), [])

    async def test_streamed_bytes_cannot_cross_download_ceiling(self):
        counters = {"get": 0, "stream": 0, "delete": 0}
        metadata = {
            "name": "unknown-size.ARW",
            "parent_id": "folder-1",
            "media_links": {"original": {"url": "https://download.invalid/file"}},
        }
        with tempfile.TemporaryDirectory() as directory:
            incoming, staging, _state = self.configure_paths(Path(directory))
            app.CFG.update(delete_upstream=True, download_max_bytes=5)
            client = FakeClient(b"", [204], counters, metadata=metadata)

            def stream(*_args, **_kwargs):
                counters["stream"] += 1
                return ChunkedStream(b"123", b"456")

            client.stream = stream
            with (
                patch.object(app.httpx, "AsyncClient", return_value=client),
                patch.object(app, "get_token", AsyncMock(return_value="token")),
                patch.object(app, "notify_failure", AsyncMock()),
            ):
                status = await app.process_asset("account-1", "asset-stream-limit")

            self.assertEqual(status, "download_too_large")
            self.assertEqual(counters, {"get": 1, "stream": 1, "delete": 0})
            self.assertEqual(list(incoming.iterdir()), [])
            self.assertEqual(list(staging.iterdir()), [])

    async def test_download_has_an_overall_elapsed_timeout(self):
        counters = {"get": 0, "stream": 0, "delete": 0}
        with tempfile.TemporaryDirectory() as directory:
            incoming, staging, _state = self.configure_paths(Path(directory))
            app.CFG.update(delete_upstream=True, download_max_seconds=0.01)
            client = FakeClient(b"eventually", [204], counters)

            def stream(*_args, **_kwargs):
                counters["stream"] += 1
                return SlowStream(b"eventually")

            client.stream = stream
            with (
                patch.object(app.httpx, "AsyncClient", return_value=client),
                patch.object(app, "get_token", AsyncMock(return_value="token")),
                patch.object(app, "notify_failure", AsyncMock()),
            ):
                status = await asyncio.wait_for(
                    app.process_asset("account-1", "asset-timeout"), timeout=1
                )

            self.assertEqual(status, "download_timeout")
            self.assertEqual(counters, {"get": 1, "stream": 1, "delete": 0})
            self.assertEqual(list(incoming.iterdir()), [])
            self.assertEqual(list(staging.iterdir()), [])

    async def test_malformed_metadata_root_is_rejected_without_download(self):
        counters = {"get": 0, "stream": 0, "delete": 0}
        with tempfile.TemporaryDirectory() as directory:
            incoming, staging, _state = self.configure_paths(Path(directory))
            client = FakeClient(b"camera", [204], counters, metadata=[])
            with (
                patch.object(app.httpx, "AsyncClient", return_value=client),
                patch.object(app, "get_token", AsyncMock(return_value="token")),
                patch.object(app, "notify_failure", AsyncMock()),
            ):
                status = await app.process_asset("account-1", "asset-bad-metadata")

            self.assertEqual(status, "metadata_invalid")
            self.assertEqual(counters, {"get": 1, "stream": 0, "delete": 0})
            self.assertEqual(list(incoming.iterdir()), [])
            self.assertEqual(list(staging.iterdir()), [])

    async def test_delete_failure_retries_without_redownload(self):
        payload = b"one local copy"
        counters = {"get": 0, "stream": 0, "delete": 0}
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            incoming, _staging, state = self.configure_paths(root)
            app.CFG.update(
                c2c_folder_id="folder-1",
                c2c_account_id="account-1",
                delete_upstream=True,
                adobe_client_id="client",
                adobe_client_secret="secret",
            )
            app._save_pending_download("asset-1", "account-1")
            client = FakeClient(payload, [500, 204], counters)
            with (
                patch.object(app.httpx, "AsyncClient", return_value=client),
                patch.object(app, "get_token", AsyncMock(return_value="token")),
                patch.object(app, "notify_failure", AsyncMock()),
            ):
                first = await app.process_asset("account-1", "asset-1")
                self.assertIn("asset-1", app._pending_downloads(strict=True))
                app._PENDING_DOWNLOADS.clear()
                app._PENDING_DELETES.clear()
                app.CFG["c2c_folder_id"] = ""
                app.CFG["c2c_account_id"] = ""
                second = await app.reconcile_once()
                replay = await app.process_asset("account-1", "asset-1")
            self.assertEqual((first, second, replay), ("delete_failed", 1, "ok"))
            self.assertEqual(counters, {"get": 1, "stream": 1, "delete": 2})
            visible = [path for path in incoming.iterdir() if not path.name.startswith(".")]
            self.assertEqual(len(visible), 1)
            self.assertEqual(visible[0].read_bytes(), payload)
            saved = json.loads(state.read_text())
            self.assertEqual(saved.get("pending_deletes"), {})
            self.assertEqual(saved.get("pending_downloads"), {})
            self.assertIn("asset-1", saved.get("completed_deletes", {}))

    async def test_delete_finalize_failure_retries_delete_only(self):
        payload = b"one local copy"
        counters = {"get": 0, "stream": 0, "delete": 0}
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            incoming, _staging, state = self.configure_paths(root)
            app.CFG.update(
                c2c_folder_id="folder-1",
                c2c_account_id="account-1",
                delete_upstream=True,
            )
            app._save_pending_download("asset-finalize", "account-1")
            client = FakeClient(payload, [204, 404], counters)
            real_save = app._save_state
            failed_once = False

            def fail_first_finalize(updates, **kwargs):
                nonlocal failed_once
                if "completed_deletes" in updates and not failed_once:
                    failed_once = True
                    raise OSError("simulated finalize crash window")
                return real_save(updates, **kwargs)

            with (
                patch.object(app.httpx, "AsyncClient", return_value=client),
                patch.object(app, "get_token", AsyncMock(return_value="token")),
                patch.object(app, "notify_failure", AsyncMock()),
                patch.object(app, "_save_state", side_effect=fail_first_finalize),
            ):
                first = await app.process_asset("account-1", "asset-finalize")
                after_failure = json.loads(state.read_text())
                second = await app.process_asset("account-1", "asset-finalize")
            self.assertEqual((first, second), ("delete_finalize_failed", "ok"))
            self.assertIn("asset-finalize", after_failure["pending_downloads"])
            self.assertIn("asset-finalize", after_failure["pending_deletes"])
            self.assertEqual(counters, {"get": 1, "stream": 1, "delete": 2})
            final = json.loads(state.read_text())
            self.assertEqual(final["pending_downloads"], {})
            self.assertEqual(final["pending_deletes"], {})
            self.assertIn("asset-finalize", final["completed_deletes"])

    async def test_default_retention_prevents_delete_and_redownload(self):
        payload = b"retained local copy"
        counters = {"get": 0, "stream": 0, "delete": 0}
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            _incoming, _staging, state = self.configure_paths(root)
            app.CFG.update(
                c2c_folder_id="folder-1",
                c2c_account_id="account-1",
                delete_upstream=False,
            )
            client = FakeClient(payload, [], counters)
            with (
                patch.object(app.httpx, "AsyncClient", return_value=client),
                patch.object(app, "get_token", AsyncMock(return_value="token")),
                patch.object(app, "notify_failure", AsyncMock()),
            ):
                first = await app.process_asset("account-1", "asset-retained")
                second = await app.process_asset("account-1", "asset-retained")
            self.assertEqual((first, second), ("retained", "retained"))
            self.assertEqual(counters, {"get": 1, "stream": 1, "delete": 0})
            self.assertEqual(
                json.loads(state.read_text()).get("retained_assets"),
                ["asset-retained"],
            )

    async def test_receipt_write_failure_keeps_durable_download_job(self):
        payload = b"one safely retained copy"
        counters = {"get": 0, "stream": 0, "delete": 0}
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            _incoming, _staging, state = self.configure_paths(root)
            app.CFG.update(
                c2c_folder_id="folder-1",
                c2c_account_id="account-1",
                delete_upstream=False,
            )
            app._save_pending_download("asset-receipt", "account-1")
            client = FakeClient(payload, [], counters)
            real_save = app._save_state
            failed_once = False

            def fail_first_receipt(updates, **kwargs):
                nonlocal failed_once
                if "retained_assets" in updates and not failed_once:
                    failed_once = True
                    raise OSError("simulated receipt write failure")
                return real_save(updates, **kwargs)

            with (
                patch.object(app.httpx, "AsyncClient", return_value=client),
                patch.object(app, "get_token", AsyncMock(return_value="token")),
                patch.object(app, "notify_failure", AsyncMock()),
                patch.object(app, "_save_state", side_effect=fail_first_receipt),
            ):
                first = await app.process_asset("account-1", "asset-receipt")
                self.assertIn("asset-receipt", app._pending_downloads())
                second = await app.process_asset("account-1", "asset-receipt")
            self.assertEqual((first, second), ("receipt_failed", "retained"))
            self.assertEqual(counters, {"get": 2, "stream": 2, "delete": 0})
            self.assertNotIn("asset-receipt", app._pending_downloads())

    async def test_incoming_swap_after_staging_preserves_private_copy(self):
        payload = b"camera payload"
        counters = {"get": 0, "stream": 0, "delete": 0}
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            incoming, staging, state = self.configure_paths(root)
            displaced = root / "displaced"
            outside = root / "outside"
            outside.mkdir()
            app.CFG.update(
                c2c_folder_id="folder-1",
                c2c_account_id="account-1",
                delete_upstream=True,
            )
            client = FakeClient(payload, [204], counters)
            real_delete = app._delete_upstream

            async def swap_then_delete(*args, **kwargs):
                incoming.rename(displaced)
                incoming.symlink_to(outside, target_is_directory=True)
                return await real_delete(*args, **kwargs)

            with (
                patch.object(app.httpx, "AsyncClient", return_value=client),
                patch.object(app, "get_token", AsyncMock(return_value="token")),
                patch.object(app, "notify_failure", AsyncMock()),
                patch.object(app, "_delete_upstream", side_effect=swap_then_delete),
            ):
                status = await app.process_asset("account-1", "asset-swap")
            self.assertEqual(status, "delete_finalize_failed")
            self.assertEqual(counters["delete"], 1)
            hidden = [path for path in staging.iterdir() if path.name.startswith(".tmp.")]
            self.assertEqual(len(hidden), 1)
            self.assertEqual(hidden[0].read_bytes(), payload)
            self.assertEqual(list(displaced.iterdir()), [])
            self.assertEqual(list(outside.iterdir()), [])

    async def test_directory_fsync_failure_preserves_private_copy(self):
        payload = b"camera payload"
        counters = {"get": 0, "stream": 0, "delete": 0}
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            incoming, staging, _state = self.configure_paths(root)
            app.CFG.update(
                c2c_folder_id="folder-1",
                c2c_account_id="account-1",
                delete_upstream=True,
            )
            client = FakeClient(payload, [204], counters)
            incoming_node = incoming.stat()
            real_fsync = app.os.fsync

            def fail_incoming_directory(fd):
                node = os.fstat(fd)
                if (
                    node.st_dev == incoming_node.st_dev
                    and node.st_ino == incoming_node.st_ino
                ):
                    raise OSError("simulated directory fsync failure")
                return real_fsync(fd)

            with (
                patch.object(app.httpx, "AsyncClient", return_value=client),
                patch.object(app, "get_token", AsyncMock(return_value="token")),
                patch.object(app, "notify_failure", AsyncMock()),
                patch.object(app.os, "fsync", side_effect=fail_incoming_directory),
            ):
                status = await app.process_asset("account-1", "asset-fsync")
            self.assertEqual(status, "error")
            self.assertEqual(counters["delete"], 1)
            self.assertEqual(list(incoming.iterdir()), [])
            self.assertEqual(len(list(staging.iterdir())), 1)

    async def test_chunked_oversize_webhook_is_bounded(self):
        messages = iter(
            [
                {"type": "http.request", "body": b"12345", "more_body": True},
                {"type": "http.request", "body": b"67890", "more_body": True},
                {"type": "http.request", "body": b"never-read", "more_body": False},
            ]
        )
        reads = 0

        async def receive():
            nonlocal reads
            reads += 1
            return next(messages)

        request = Request(
            {
                "type": "http",
                "method": "POST",
                "path": "/webhook",
                "headers": [],
                "query_string": b"",
                "server": ("test", 80),
                "client": ("test", 1234),
                "scheme": "http",
            },
            receive,
        )
        with self.assertRaises(HTTPException) as raised:
            await app._read_bounded_body(request, 8)
        self.assertEqual(raised.exception.status_code, 413)
        self.assertEqual(reads, 2)

    async def test_missing_credentials_webhook_is_durably_queued(self):
        with tempfile.TemporaryDirectory() as directory:
            state = Path(directory) / "state.json"
            write_private_state(state)
            secret = "webhook-secret"
            app.CFG.update(
                refresh_token_file=str(state),
                webhook_secret=secret,
                adobe_client_id="",
                adobe_client_secret="",
            )
            raw = json.dumps(
                {
                    "type": "file.ready",
                    "resource": {"type": "file", "id": "queued-asset"},
                    "account": {"id": "queued-account"},
                }
            ).encode()
            delivered = False

            async def receive():
                nonlocal delivered
                if delivered:
                    return {"type": "http.request", "body": b"", "more_body": False}
                delivered = True
                return {"type": "http.request", "body": raw, "more_body": False}

            request = Request(
                {
                    "type": "http",
                    "method": "POST",
                    "path": "/webhook",
                    "headers": [],
                    "query_string": b"",
                    "server": ("test", 80),
                    "client": ("test", 1234),
                    "scheme": "http",
                },
                receive,
            )
            timestamp = str(int(time.time()))
            signature = "v0=" + hmac.new(
                secret.encode("latin-1"),
                f"v0:{timestamp}:".encode("latin-1") + raw,
                hashlib.sha256,
            ).hexdigest()
            with patch.object(app, "notify_failure", AsyncMock()):
                response = await app.webhook(
                    request,
                    BackgroundTasks(),
                    x_frameio_signature=signature,
                    x_frameio_request_timestamp=timestamp,
                )
            self.assertEqual(response["status"], "accepted_queued")
            self.assertEqual(
                app._pending_downloads(), {"queued-asset": "queued-account"}
            )

    async def test_webhook_queue_is_bounded_and_overflow_stays_durable(self):
        with tempfile.TemporaryDirectory() as directory:
            _incoming, _staging, state = self.configure_paths(Path(directory))
            secret = "webhook-secret"
            app.CFG.update(
                webhook_secret=secret,
                adobe_client_id="client",
                adobe_client_secret="secret",
                frameio_queue_size=1,
            )
            app._JOB_QUEUE = asyncio.Queue(maxsize=1)
            app._JOB_QUEUE.put_nowait(("busy-account", "busy-asset"))
            app._QUEUED_ASSETS.add("busy-asset")
            raw = json.dumps(
                {
                    "type": "file.ready",
                    "resource": {"type": "file", "id": "overflow-asset"},
                    "account": {"id": "overflow-account"},
                }
            ).encode()
            delivered = False

            async def receive():
                nonlocal delivered
                if delivered:
                    return {"type": "http.request", "body": b"", "more_body": False}
                delivered = True
                return {"type": "http.request", "body": raw, "more_body": False}

            request = Request(
                {
                    "type": "http",
                    "method": "POST",
                    "path": "/webhook",
                    "headers": [],
                    "query_string": b"",
                    "server": ("test", 80),
                    "client": ("test", 1234),
                    "scheme": "http",
                },
                receive,
            )
            timestamp = str(int(time.time()))
            signature = "v0=" + hmac.new(
                secret.encode("latin-1"),
                f"v0:{timestamp}:".encode("latin-1") + raw,
                hashlib.sha256,
            ).hexdigest()
            background = BackgroundTasks()
            with patch.object(app, "notify_failure", AsyncMock()):
                response = await app.webhook(
                    request,
                    background,
                    x_frameio_signature=signature,
                    x_frameio_request_timestamp=timestamp,
                )

            self.assertEqual(
                response,
                {"status": "accepted_queued", "reason": "worker_queue_full"},
            )
            self.assertEqual(app._JOB_QUEUE.qsize(), 1)
            self.assertEqual(background.tasks, [])
            saved = json.loads(state.read_text())
            self.assertEqual(
                saved["pending_downloads"]["overflow-asset"], "overflow-account"
            )

    async def test_first_webhook_job_retries_before_folder_discovery(self):
        with tempfile.TemporaryDirectory() as directory:
            state = Path(directory) / "state.json"
            write_private_state(state)
            app.CFG.update(
                refresh_token_file=str(state),
                c2c_folder_id="",
                c2c_account_id="",
                adobe_client_id="client",
                adobe_client_secret="secret",
            )
            app._save_pending_download("first-asset", "first-account")
            calls = 0

            async def process_then_finalize(_account_id, asset_id):
                nonlocal calls
                calls += 1
                if calls == 1:
                    return "error"
                await app._clear_pending_download(asset_id)
                return "retained"

            with patch.object(
                app, "_process_asset_inner", side_effect=process_then_finalize
            ) as process:
                self.assertEqual(await app.reconcile_once(), 1)
                await self._drain_job_queue()
                self.assertIn("first-asset", app._pending_downloads())
                self.assertEqual(await app.reconcile_once(), 1)
                await self._drain_job_queue()
            self.assertEqual(process.await_count, 2)
            self.assertNotIn("first-asset", app._pending_downloads())

    async def test_transient_403_is_retried_on_later_sweep(self):
        with tempfile.TemporaryDirectory() as directory:
            state = Path(directory) / "state.json"
            write_private_state(state)
            app.CFG.update(
                refresh_token_file=str(state),
                c2c_folder_id="folder-1",
                c2c_account_id="account-1",
                adobe_client_id="client",
                adobe_client_secret="secret",
            )
            with (
                patch.object(app.httpx, "AsyncClient", return_value=ListingClient()),
                patch.object(app, "get_token", AsyncMock(return_value="token")),
                patch.object(
                    app,
                    "_process_asset_inner",
                    AsyncMock(side_effect=["http_403", "ok"]),
                ) as process,
                patch.object(app, "notify_failure", AsyncMock()),
            ):
                self.assertEqual(await app.reconcile_once(), 1)
                await self._drain_job_queue()
                self.assertEqual(await app.reconcile_once(), 1)
                await self._drain_job_queue()
            self.assertEqual(process.await_count, 2)
            self.assertNotIn("reconcile_skip", json.loads(state.read_text()))

    async def test_reconcile_walks_beyond_twenty_pages(self):
        with tempfile.TemporaryDirectory() as directory:
            state = Path(directory) / "state.json"
            write_private_state(state)
            app.CFG.update(
                refresh_token_file=str(state),
                c2c_folder_id="folder-1",
                c2c_account_id="account-1",
                adobe_client_id="client",
                adobe_client_secret="secret",
            )
            listing = ManyPageClient(pages=21)
            with (
                patch.object(app.httpx, "AsyncClient", return_value=listing),
                patch.object(app, "get_token", AsyncMock(return_value="token")),
                patch.object(
                    app, "_process_asset_inner", AsyncMock(return_value="ok")
                ) as process,
                patch.object(app, "notify_failure", AsyncMock()),
            ):
                self.assertEqual(
                    await app.reconcile_once(), app.CFG["frameio_workers"]
                )
                await self._drain_job_queue()
            self.assertEqual(listing.calls, 21)
            self.assertEqual(process.await_count, app.CFG["frameio_workers"])

    async def test_expired_persisted_cursor_resets_to_full_listing(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            endpoint = (
                f"{app.FRAMEIO_API}/accounts/account-1/folders/folder-1/files"
            )
            _incoming, _staging, state = self.configure_paths(
                root,
                state_value=json.dumps(
                    {
                        "reconcile_cursor": {
                            "url": f"{endpoint}?after=expired",
                            "account_id": "account-1",
                            "folder_id": "folder-1",
                        }
                    }
                ),
            )
            app.CFG.update(
                c2c_folder_id="folder-1",
                c2c_account_id="account-1",
                adobe_client_id="client",
                adobe_client_secret="secret",
            )
            listing = ExpiredCursorClient()
            with (
                patch.object(app.httpx, "AsyncClient", return_value=listing),
                patch.object(app, "get_token", AsyncMock(return_value="token")),
                patch.object(app, "process_asset", AsyncMock(return_value="ok")) as process,
                patch.object(app, "notify_failure", AsyncMock()),
            ):
                processed = await app.reconcile_once()
                await self._drain_job_queue()

            self.assertEqual(processed, 1)
            self.assertEqual(listing.urls, [f"{endpoint}?after=expired", endpoint])
            process.assert_awaited_once_with("account-1", "asset-after-reset")
            self.assertEqual(json.loads(state.read_text())["reconcile_cursor"], {})

    def test_pagination_rejects_external_or_looping_endpoint(self):
        endpoint = "https://api.frame.io/v4/accounts/a/folders/f/files"
        self.assertEqual(
            app._validated_next_page_url(endpoint, "?after=two", endpoint),
            f"{endpoint}?after=two",
        )
        for unsafe in (
            "https://evil.invalid/steal",
            "http://api.frame.io/v4/accounts/a/folders/f/files?after=2",
            "https://api.frame.io/v4/accounts/other/folders/f/files?after=2",
        ):
            with self.assertRaises(ValueError):
                app._validated_next_page_url(endpoint, unsafe, endpoint)

    def test_cleanup_distinguishes_private_stages_from_incoming_handoffs(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            incoming, staging, state = self.configure_paths(root)
            app.CFG["download_tmp_stale_seconds"] = 300
            payload = b"journal-owned-camera-bytes"
            stage_name = ".tmp.aaaaaaaaaaaaaaaa.bbbbbbbbbbbbbbbb"
            handoff_name = ".tmp.cccccccccccccccc.dddddddddddddddd"
            stage = staging / stage_name
            handoff = incoming / handoff_name
            stage.write_bytes(payload)
            handoff.write_bytes(payload)
            stage.chmod(0o600)
            handoff.chmod(0o600)
            stage_node = stage.stat()
            handoff_node = handoff.stat()

            stale_stage = staging / ".tmp.eeeeeeeeeeeeeeee.ffffffffffffffff"
            stale_handoff = incoming / ".tmp.1111111111111111.2222222222222222"
            recent_stage = staging / ".tmp.3333333333333333.4444444444444444"
            near_miss = incoming / ".tmp.not-a-frameio-temp"
            symlink = incoming / ".tmp.5555555555555555.6666666666666666"
            sentinel = incoming / "sentinel"
            stale_stage.write_bytes(b"stale-stage")
            stale_handoff.write_bytes(b"stale-handoff")
            recent_stage.write_bytes(b"recent")
            near_miss.write_bytes(b"keep")
            sentinel.write_bytes(b"sentinel")
            symlink.symlink_to(sentinel)
            for path in (stale_stage, stale_handoff, recent_stage):
                path.chmod(0o600)

            staging_fd, _expected_staging = app._open_private_staging_dir(staging)
            active_fd, active_name, _active_node = app._create_download_temp(
                staging_fd, "7777777777777777"
            )
            os.write(active_fd, b"active")
            os.fsync(active_fd)

            old = time.time() - 600
            for path in (
                stage,
                handoff,
                stale_stage,
                stale_handoff,
                near_miss,
                staging / active_name,
            ):
                os.utime(path, (old, old), follow_symlinks=False)

            write_private_state(
                state,
                json.dumps(
                    {
                        "retained_assets": ["asset-journal"],
                        "pending_publications": {
                            "asset-journal": {
                                "version": 1,
                                "account_id": "account-1",
                                "temp_name": stage_name,
                                "filename": "camera.bin",
                                "destination_name": "camera.bin",
                                "handoff_name": handoff_name,
                                "handoff_dev": handoff_node.st_dev,
                                "handoff_ino": handoff_node.st_ino,
                                "dev": stage_node.st_dev,
                                "ino": stage_node.st_ino,
                                "size": len(payload),
                                "sha256": hashlib.sha256(payload).hexdigest(),
                                "expected_size": None,
                                "policy": "retain",
                                "phase": "renaming",
                                "created_at": int(time.time()),
                            }
                        },
                    }
                ),
            )

            self.assertEqual(app._cleanup_stale_download_temps(), 2)
            self.assertEqual(stage.read_bytes(), payload)
            self.assertEqual(handoff.read_bytes(), payload)
            self.assertEqual(stale_stage.stat().st_size, 0)
            self.assertEqual(stale_handoff.stat().st_size, 0)
            self.assertEqual(recent_stage.read_bytes(), b"recent")
            self.assertEqual(near_miss.read_bytes(), b"keep")
            self.assertTrue(symlink.is_symlink())
            self.assertEqual(sentinel.read_bytes(), b"sentinel")
            self.assertEqual((staging / active_name).read_bytes(), b"active")

            self.assertEqual(app._cleanup_stale_download_temps(), 0)
            os.close(active_fd)
            self.assertEqual(app._cleanup_stale_download_temps(), 1)
            self.assertEqual((staging / active_name).stat().st_size, 0)
            os.close(staging_fd)

    async def test_repeated_stream_failures_do_not_accumulate_temps(self):
        payload = b"partial payload"
        counters = {"get": 0, "stream": 0, "delete": 0}
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            incoming, staging, _state = self.configure_paths(root)
            app.CFG.update(
                c2c_folder_id="folder-1",
                c2c_account_id="account-1",
                delete_upstream=True,
            )
            client = FakeClient(payload, [204], counters)
            client.stream = lambda *_args, **_kwargs: FailingStream(payload)
            with (
                patch.object(app.httpx, "AsyncClient", return_value=client),
                patch.object(app, "get_token", AsyncMock(return_value="token")),
                patch.object(app, "notify_failure", AsyncMock()),
            ):
                for index in range(3):
                    self.assertEqual(
                        await app.process_asset("account-1", f"asset-{index}"), "error"
                    )
            self.assertEqual(list(incoming.iterdir()), [])
            self.assertEqual(list(staging.iterdir()), [])

    def test_state_is_atomic_private_and_fifo_read_is_nonblocking(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            state = root / "state.json"
            app.CFG["refresh_token_file"] = str(state)
            app._save_state({"value": "safe"})
            self.assertEqual(state.stat().st_mode & 0o777, 0o600)
            self.assertEqual(app._load_state(), {"value": "safe"})
            self.assertEqual(list(root.glob(".state.json.*")), [])

            state.unlink()
            os.mkfifo(state)
            started = time.monotonic()
            self.assertEqual(app._load_state(), {})
            elapsed = time.monotonic() - started
            self.assertLess(elapsed, 1)

    def test_corrupt_state_is_never_overwritten_by_save(self):
        with tempfile.TemporaryDirectory() as directory:
            state = Path(directory) / "state.json"
            app.CFG["refresh_token_file"] = str(state)
            for corrupt in (b'{"refresh_token":', b"[]"):
                state.write_bytes(corrupt)
                state.chmod(0o600)
                self.assertEqual(app._load_state(), {})
                with self.assertRaises((json.JSONDecodeError, ValueError)):
                    app._save_state({"pending_downloads": {"asset": "account"}})
                self.assertEqual(state.read_bytes(), corrupt)

    async def test_health_requires_valid_private_state(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            _incoming, _staging, state = self.configure_paths(root)
            app.CFG.update(
                webhook_secret="secret",
                adobe_client_id="client",
                adobe_client_secret="secret",
            )
            healthy = await app.health()
            self.assertEqual(healthy.status_code, 200)
            self.assertEqual(json.loads(healthy.body)["status"], "ok")

            state.write_text("not-json")
            app._HEALTH_CACHE["expires_at"] = 0.0
            unhealthy = await app.health()
            self.assertEqual(unhealthy.status_code, 503)
            body = json.loads(unhealthy.body)
            self.assertEqual(body["status"], "unhealthy")
            self.assertIn("private state", " ".join(body["errors"]))

    async def test_health_rejects_malformed_durable_queue_schema(self):
        with tempfile.TemporaryDirectory() as directory:
            _incoming, _staging, _state = self.configure_paths(
                Path(directory),
                state_value=json.dumps({"pending_downloads": []}),
            )
            app.CFG.update(
                webhook_secret="secret",
                adobe_client_id="client",
                adobe_client_secret="secret",
            )

            response = await app.health()

            self.assertEqual(response.status_code, 503)
            body = json.loads(response.body)
            self.assertFalse(body["state_persistent"])
            self.assertIn("private state", " ".join(body["errors"]))


if __name__ == "__main__":
    unittest.main()
