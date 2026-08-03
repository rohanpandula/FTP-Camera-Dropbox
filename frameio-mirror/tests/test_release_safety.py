import asyncio
import hashlib
import json
import os
import stat
import tempfile
import threading
import time
import unittest
from pathlib import Path
from urllib.parse import parse_qs, urlsplit
from unittest.mock import AsyncMock, patch

import httpx

import app


def write_private_state(path: Path, value=None) -> None:
    if value is None:
        value = {}
    path.write_text(json.dumps(value))
    path.chmod(0o600)


class FakeResponse:
    def __init__(self, *, status_code=200, body=None, text=""):
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

    def __init__(self, payload: bytes):
        self.payload = payload
        self.headers = {}

    async def __aenter__(self):
        return self

    async def __aexit__(self, *_args):
        return False

    async def aread(self):
        return self.payload

    def raise_for_status(self):
        return None

    async def aiter_bytes(self, chunk_size=65536):
        del chunk_size
        yield self.payload


class AssetClient:
    def __init__(self, payload: bytes, incoming: Path, delete_hook=None):
        self.payload = payload
        self.incoming = incoming
        self.delete_hook = delete_hook
        self.calls = {"get": 0, "stream": 0, "delete": 0}

    async def __aenter__(self):
        return self

    async def __aexit__(self, *_args):
        return False

    async def get(self, *_args, **_kwargs):
        self.calls["get"] += 1
        return FakeResponse(
            body={
                "name": "camera.bin",
                "file_size": len(self.payload),
                "parent_id": "folder-1",
                "media_links": {
                    "original": {"url": "https://download.invalid/camera.bin"}
                },
            }
        )

    def stream(self, *_args, **_kwargs):
        self.calls["stream"] += 1
        return FakeStream(self.payload)

    async def delete(self, *_args, **_kwargs):
        self.calls["delete"] += 1
        if self.delete_hook is not None:
            result = self.delete_hook()
            if hasattr(result, "__await__"):
                await result
        return FakeResponse(status_code=204)


class MalformedListingClient:
    async def __aenter__(self):
        return self

    async def __aexit__(self, *_args):
        return False

    async def get(self, *_args, **_kwargs):
        return FakeResponse(body={})


class CursorListingClient:
    def __init__(self, total_pages: int):
        self.total_pages = total_pages
        self.urls: list[str] = []

    async def __aenter__(self):
        return self

    async def __aexit__(self, *_args):
        return False

    async def get(self, url, *_args, **_kwargs):
        url = str(url)
        self.urls.append(url)
        query = parse_qs(urlsplit(url).query)
        page = int(query.get("after", ["0"])[0])
        links = (
            {"next": f"?after={page + 1}"}
            if page + 1 < self.total_pages
            else {}
        )
        return FakeResponse(
            body={
                "data": [{"type": "file", "id": f"asset-{page}"}],
                "links": links,
            }
        )


class RotatingTokenClient:
    def __init__(self, responses):
        self.responses = list(responses)
        self.post_records = []

    async def post(self, *_args, data=None, **_kwargs):
        self.post_records.append(dict(data or {}))
        return self.responses.pop(0) if self.responses else FakeResponse(
            status_code=500
        )


class FrameioReleaseSafetyTests(unittest.IsolatedAsyncioTestCase):
    def setUp(self):
        self.original_cfg = dict(app.CFG)
        self.runtime_paths = tempfile.TemporaryDirectory()
        runtime_root = Path(self.runtime_paths.name)
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
        self.real_rename_noreplace = app._rename_noreplace
        self.real_require_private_staging_mount = app._require_private_staging_mount
        self.real_state_parent_path_is_canonical = (
            app._state_parent_path_is_canonical
        )
        self.original_semaphore = app._PROCESS_SEMAPHORE
        self.original_job_queue = app._JOB_QUEUE
        self.original_queue_lock = app._QUEUE_LOCK
        self.original_in_flight_lock = app._IN_FLIGHT_LOCK
        self.original_health_lock = app._HEALTH_LOCK
        self.original_health_probe_task = app._HEALTH_PROBE_TASK
        self.original_health_cache = dict(app._HEALTH_CACHE)
        self.original_token_cache = dict(app._TOKEN_CACHE)
        self.original_reconcile_rotation = app._RECONCILE_ROTATION
        self.original_refresh_token_memory = app._REFRESH_TOKEN_MEMORY
        self.original_refresh_persist_error = app._REFRESH_TOKEN_PERSIST_ERROR
        app._PROCESS_SEMAPHORE = asyncio.Semaphore(app.CFG["frameio_workers"])
        app._JOB_QUEUE = asyncio.Queue(maxsize=app.CFG["frameio_queue_size"])
        app._QUEUE_LOCK = asyncio.Lock()
        app._IN_FLIGHT_LOCK = asyncio.Lock()
        app._HEALTH_LOCK = asyncio.Lock()
        app._HEALTH_PROBE_TASK = None
        app._IN_FLIGHT.clear()
        app._QUEUED_ASSETS.clear()
        app._PENDING_DOWNLOADS.clear()
        app._PENDING_DELETES.clear()
        app._RETAINED_ASSETS.clear()
        app._COMPLETED_DELETES.clear()
        app._RENAME_NOREPLACE_FILESYSTEMS.clear()
        app._OAUTH_STATES.clear()
        app._HEALTH_CACHE.clear()
        app._HEALTH_CACHE.update(expires_at=0.0, status_code=503, body={})
        app._RECONCILE_ROTATION = 0
        app._REFRESH_TOKEN_MEMORY = None
        app._REFRESH_TOKEN_PERSIST_ERROR = False
        # Unit-test temp directories share one mount; production must not.
        self.mount_patcher = patch.object(
            app, "_require_private_staging_mount", return_value=None
        )
        self.mount_patcher.start()
        # macOS exposes temporary paths through /var -> /private/var. Dedicated
        # tests below restore the real canonical-path policy when exercising it.
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
        app._HEALTH_PROBE_TASK = self.original_health_probe_task
        app._TOKEN_CACHE.clear()
        app._TOKEN_CACHE.update(self.original_token_cache)
        app._IN_FLIGHT.clear()
        app._QUEUED_ASSETS.clear()
        app._PENDING_DOWNLOADS.clear()
        app._PENDING_DELETES.clear()
        app._RETAINED_ASSETS.clear()
        app._COMPLETED_DELETES.clear()
        app._RENAME_NOREPLACE_FILESYSTEMS.clear()
        app._OAUTH_STATES.clear()
        app._HEALTH_CACHE.clear()
        app._HEALTH_CACHE.update(self.original_health_cache)
        app._RECONCILE_ROTATION = self.original_reconcile_rotation
        app._REFRESH_TOKEN_MEMORY = self.original_refresh_token_memory
        app._REFRESH_TOKEN_PERSIST_ERROR = self.original_refresh_persist_error
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

    def configure_asset(self, root: Path, asset_id: str, *, delete_upstream: bool):
        incoming = root / "incoming"
        staging = root / "staging"
        incoming.mkdir()
        staging.mkdir(mode=0o700)
        staging.chmod(0o700)
        state = root / "state.json"
        write_private_state(
            state,
            {"pending_downloads": {asset_id: "account-1"}},
        )
        app.CFG.update(
            incoming_dir=str(incoming),
            staging_dir=str(staging),
            refresh_token_file=str(state),
            c2c_folder_id="folder-1",
            c2c_account_id="account-1",
            adobe_client_id="client",
            adobe_client_secret="secret",
            webhook_secret="webhook-secret",
            delete_upstream=delete_upstream,
        )
        return incoming, staging, state

    async def test_oauth_start_is_post_and_header_only(self):
        setup_secret = "never-put-this-in-a-url"
        app.CFG.update(
            adobe_client_id="client",
            adobe_client_secret="secret",
            adobe_scopes="openid,offline_access",
            oauth_redirect_uri="https://mirror.invalid/oauth/callback",
            oauth_setup_secret=setup_secret,
        )
        start_routes = [
            route
            for route in app.app.routes
            if getattr(route, "path", None) == "/oauth/start"
        ]
        self.assertEqual(len(start_routes), 1)
        self.assertEqual(start_routes[0].methods, {"POST"})

        transport = httpx.ASGITransport(app=app.app)
        async with httpx.AsyncClient(
            transport=transport, base_url="https://mirror.invalid"
        ) as client:
            get_response = await client.get(
                "/oauth/start", params={"setup": setup_secret}
            )
            query_only = await client.post(
                "/oauth/start", params={"setup": setup_secret}
            )
            header_response = await client.post(
                "/oauth/start", headers={"X-Setup-Secret": setup_secret}
            )

        self.assertEqual(get_response.status_code, 405)
        self.assertEqual(query_only.status_code, 403)
        self.assertEqual(header_response.status_code, 200)
        authorize_url = header_response.json()["authorize_url"]
        self.assertNotIn(setup_secret, authorize_url)
        self.assertEqual(
            parse_qs(urlsplit(authorize_url).query)["redirect_uri"],
            ["https://mirror.invalid/oauth/callback"],
        )

    async def test_public_or_hardlinked_state_is_rejected_and_health_is_503(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            incoming = root / "incoming"
            staging = root / "staging"
            incoming.mkdir()
            staging.mkdir(mode=0o700)
            staging.chmod(0o700)
            state = root / "state.json"
            write_private_state(state, {"refresh_token": "token"})
            app.CFG.update(
                incoming_dir=str(incoming),
                staging_dir=str(staging),
                refresh_token_file=str(state),
                webhook_secret="webhook-secret",
                adobe_client_id="client",
                adobe_client_secret="secret",
            )

            state.chmod(0o644)
            with self.assertRaises(ValueError):
                app._load_state(strict=True)
            public_health = await app.health()
            self.assertEqual(public_health.status_code, 503)
            self.assertFalse(json.loads(public_health.body)["state_persistent"])

            state.chmod(0o600)
            os.link(state, root / "state-hardlink.json")
            app._HEALTH_CACHE["expires_at"] = 0.0
            with self.assertRaises(ValueError):
                app._load_state(strict=True)
            linked_health = await app.health()
            self.assertEqual(linked_health.status_code, 503)
            self.assertFalse(json.loads(linked_health.body)["state_persistent"])

    def test_state_parent_on_shared_incoming_mount_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            incoming = root / "incoming"
            state_parent = root / "state"
            incoming.mkdir()
            state_parent.mkdir(mode=0o700)
            state_parent.chmod(0o700)
            state = state_parent / "state.json"
            write_private_state(state)
            app.CFG.update(
                incoming_dir=str(incoming),
                refresh_token_file=str(state),
            )

            with (
                patch.object(
                    app,
                    "_require_private_staging_mount",
                    side_effect=self.real_require_private_staging_mount,
                ),
                patch.object(app, "_fd_mount_id", return_value=77),
                self.assertRaisesRegex(
                    RuntimeError,
                    "REFRESH_TOKEN_FILE parent must be a separate private mount",
                ),
            ):
                app._load_state(strict=True)

    def test_symlinked_and_non_private_state_parents_are_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            incoming = root / "incoming"
            private_target = root / "private-target"
            linked_parent = root / "linked-state"
            incoming.mkdir()
            private_target.mkdir(mode=0o700)
            private_target.chmod(0o700)
            write_private_state(private_target / "state.json")
            linked_parent.symlink_to(private_target, target_is_directory=True)
            app.CFG.update(
                incoming_dir=str(incoming),
                refresh_token_file=str(linked_parent / "state.json"),
            )

            with (
                patch.object(
                    app,
                    "_state_parent_path_is_canonical",
                    side_effect=self.real_state_parent_path_is_canonical,
                ),
                self.assertRaisesRegex(OSError, "state parent contains a symlink"),
            ):
                app._load_state(strict=True)

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            incoming = root / "incoming"
            shared_parent = root / "shared-state"
            incoming.mkdir()
            shared_parent.mkdir()
            shared_parent.chmod(0o777)
            state = shared_parent / "state.json"
            write_private_state(state)
            app.CFG.update(
                incoming_dir=str(incoming),
                refresh_token_file=str(state),
            )

            with self.assertRaisesRegex(
                OSError, "state parent must be private-owned or root-protected"
            ):
                app._load_state(strict=True)

    async def test_malformed_http_200_listing_preserves_retained_receipts(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            state = root / "state.json"
            receipts = ["retain-a", "retain-b"]
            write_private_state(state, {"retained_assets": receipts})
            app.CFG.update(
                refresh_token_file=str(state),
                c2c_folder_id="folder-1",
                c2c_account_id="account-1",
                adobe_client_id="client",
                adobe_client_secret="secret",
            )
            with (
                patch.object(
                    app.httpx,
                    "AsyncClient",
                    return_value=MalformedListingClient(),
                ),
                patch.object(app, "get_token", AsyncMock(return_value="token")),
                patch.object(app, "notify_failure", AsyncMock()),
            ):
                self.assertEqual(await app.reconcile_once(), 0)

            saved = json.loads(state.read_text())
            self.assertEqual(saved["retained_assets"], receipts)
            self.assertTrue(saved["reconcile_cursor"]["url"].startswith(app.FRAMEIO_API))
            self.assertEqual(state.stat().st_mode & 0o777, 0o600)

    async def test_pagination_budget_persists_and_resumes_cursor(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            state = root / "state.json"
            write_private_state(state, {"retained_assets": ["receipt"]})
            app.CFG.update(
                refresh_token_file=str(state),
                c2c_folder_id="folder-1",
                c2c_account_id="account-1",
                adobe_client_id="client",
                adobe_client_secret="secret",
                reconcile_max_pages=2,
                reconcile_max_items=100,
                reconcile_max_seconds=300,
            )
            first_client = CursorListingClient(total_pages=4)
            second_client = CursorListingClient(total_pages=4)
            process = AsyncMock(return_value="ok")
            with (
                patch.object(
                    app.httpx,
                    "AsyncClient",
                    side_effect=[first_client, second_client],
                ),
                patch.object(app, "get_token", AsyncMock(return_value="token")),
                patch.object(app, "process_asset", process),
                patch.object(app, "notify_failure", AsyncMock()),
            ):
                self.assertEqual(await app.reconcile_once(), 2)
                await self._drain_job_queue()
                after_budget = json.loads(state.read_text())
                self.assertTrue(
                    after_budget["reconcile_cursor"]["url"].endswith("?after=2")
                )
                self.assertEqual(await app.reconcile_once(), 2)
                await self._drain_job_queue()

            final_state = json.loads(state.read_text())
            self.assertEqual(first_client.urls[0].split("?", 1)[0], second_client.urls[0].split("?", 1)[0])
            self.assertTrue(second_client.urls[0].endswith("?after=2"))
            self.assertEqual(final_state["reconcile_cursor"], {})
            self.assertEqual(final_state["retained_assets"], ["receipt"])
            self.assertEqual(process.await_count, 4)

    async def test_frameio_worker_semaphore_bounds_inner_processing(self):
        workers = 3
        app.CFG["frameio_workers"] = workers
        app._PROCESS_SEMAPHORE = asyncio.Semaphore(workers)
        active = 0
        peak = 0
        saturated = asyncio.Event()
        release = asyncio.Event()

        async def controlled_inner(_account_id, _asset_id):
            nonlocal active, peak
            active += 1
            peak = max(peak, active)
            if active == workers:
                saturated.set()
            try:
                await release.wait()
                return "ok"
            finally:
                active -= 1

        with patch.object(app, "_process_asset_inner", side_effect=controlled_inner):
            tasks = [
                asyncio.create_task(app.process_asset("account-1", f"asset-{index}"))
                for index in range(12)
            ]
            await asyncio.wait_for(saturated.wait(), timeout=2)
            await asyncio.sleep(0)
            self.assertEqual(peak, workers)
            release.set()
            self.assertEqual(await asyncio.gather(*tasks), ["ok"] * 12)
        self.assertEqual(peak, workers)

    async def test_fd_to_thread_joins_worker_before_cancelled_owner_reuses_fd(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            original_path = root / "original.bin"
            replacement_path = root / "replacement.bin"
            worker_payload = b"descriptor-worker-payload"
            replacement_payload = b"replacement-owner-payload"
            descriptor = os.open(
                original_path,
                os.O_RDWR | os.O_CREAT | os.O_TRUNC,
                0o600,
            )
            worker_entered = threading.Event()
            release_worker = threading.Event()
            worker_done = threading.Event()
            owner_closed = threading.Event()
            owner_reused = threading.Event()
            worker_errors: list[BaseException] = []
            reuse_descriptors: list[int] = []
            order: list[str] = []

            def blocked_write(owned_descriptor: int) -> None:
                worker_entered.set()
                if not release_worker.wait(timeout=5):
                    worker_errors.append(TimeoutError("worker was never released"))
                    return
                try:
                    os.write(owned_descriptor, worker_payload)
                    os.fsync(owned_descriptor)
                except BaseException as exc:
                    worker_errors.append(exc)
                finally:
                    order.append("worker-done")
                    worker_done.set()

            async def descriptor_owner() -> None:
                try:
                    await app._fd_to_thread(blocked_write, descriptor)
                finally:
                    order.append("owner-close")
                    os.close(descriptor)
                    owner_closed.set()

                    replacement_descriptor = os.open(
                        replacement_path,
                        os.O_RDWR | os.O_CREAT | os.O_TRUNC,
                        0o600,
                    )
                    if replacement_descriptor != descriptor:
                        os.dup2(replacement_descriptor, descriptor)
                        os.close(replacement_descriptor)
                        replacement_descriptor = descriptor
                    reuse_descriptors.append(replacement_descriptor)
                    order.append("owner-reuse")
                    owner_reused.set()
                    try:
                        os.write(replacement_descriptor, replacement_payload)
                        os.fsync(replacement_descriptor)
                    finally:
                        os.close(replacement_descriptor)

            task = asyncio.create_task(descriptor_owner())
            entered = await asyncio.wait_for(
                asyncio.to_thread(worker_entered.wait), timeout=2
            )
            self.assertTrue(entered)
            task.cancel()
            await asyncio.sleep(0)
            await asyncio.sleep(0)

            cancellation_propagated_early = task.done()
            owner_closed_early = owner_closed.is_set()
            owner_reused_early = owner_reused.is_set()
            worker_finished_early = worker_done.is_set()
            try:
                os.fstat(descriptor)
                descriptor_open_before_release = True
            except OSError:
                descriptor_open_before_release = False

            release_worker.set()
            cancellation_propagated = False
            try:
                await asyncio.wait_for(task, timeout=2)
            except asyncio.CancelledError:
                cancellation_propagated = True

            self.assertFalse(cancellation_propagated_early)
            self.assertFalse(owner_closed_early)
            self.assertFalse(owner_reused_early)
            self.assertFalse(worker_finished_early)
            self.assertTrue(descriptor_open_before_release)
            self.assertTrue(cancellation_propagated)
            self.assertTrue(worker_done.is_set())
            self.assertTrue(owner_closed.is_set())
            self.assertTrue(owner_reused.is_set())
            self.assertEqual(worker_errors, [])
            self.assertEqual(reuse_descriptors, [descriptor])
            self.assertEqual(order, ["worker-done", "owner-close", "owner-reuse"])
            self.assertEqual(original_path.read_bytes(), worker_payload)
            self.assertEqual(replacement_path.read_bytes(), replacement_payload)

    async def test_journaled_temp_is_excluded_from_stale_cleanup(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            incoming = root / "incoming"
            staging = root / "staging"
            incoming.mkdir()
            staging.mkdir(mode=0o700)
            staging.chmod(0o700)
            state = root / "state.json"
            write_private_state(state)
            app.CFG.update(
                incoming_dir=str(incoming),
                staging_dir=str(staging),
                refresh_token_file=str(state),
                download_tmp_stale_seconds=300,
            )

            directory_fd, _expected_directory = app._open_private_staging_dir(staging)
            temp_fd, temp_name, _created = app._create_download_temp(
                directory_fd, "a" * 16
            )
            payload = b"journal-owned-camera-bytes"
            os.write(temp_fd, payload)
            os.fsync(temp_fd)
            node = os.fstat(temp_fd)
            os.close(temp_fd)
            os.close(directory_fd)
            old = time.time() - 600
            os.utime(staging / temp_name, (old, old))
            stray = staging / f".tmp.{'b' * 16}.{'c' * 16}"
            stray.write_bytes(b"unowned-stale-bytes")
            stray.chmod(0o600)
            os.utime(stray, (old, old))
            write_private_state(
                state,
                {
                    "pending_publications": {
                        "asset-journal": {
                            "version": 1,
                            "account_id": "account-1",
                            "temp_name": temp_name,
                            "filename": "camera.bin",
                            "destination_name": None,
                            "dev": node.st_dev,
                            "ino": node.st_ino,
                            "size": len(payload),
                            "sha256": hashlib.sha256(payload).hexdigest(),
                            "expected_size": None,
                            "policy": "retain",
                            "phase": "ready",
                            "created_at": int(time.time()),
                        }
                    }
                },
            )

            self.assertEqual(app._cleanup_stale_download_temps(), 1)
            self.assertEqual((staging / temp_name).read_bytes(), payload)
            self.assertEqual(stray.stat().st_size, 0)

    async def test_temp_is_private_and_hidden_during_upstream_delete(self):
        payload = b"camera-payload"
        observed = {}
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            incoming, staging, state = self.configure_asset(
                root, "asset-private", delete_upstream=True
            )

            def inspect_delete_window():
                paths = list(staging.iterdir())
                observed["names"] = [path.name for path in paths]
                observed["incoming"] = list(incoming.iterdir())
                observed["modes"] = [
                    stat.S_IMODE(path.stat().st_mode) for path in paths
                ]
                observed["journal"] = json.loads(state.read_text()).get(
                    "pending_publications", {}
                )

            client = AssetClient(payload, incoming, inspect_delete_window)
            with (
                patch.object(app.httpx, "AsyncClient", return_value=client),
                patch.object(app, "get_token", AsyncMock(return_value="token")),
                patch.object(app, "notify_failure", AsyncMock()),
            ):
                status = await app.process_asset("account-1", "asset-private")

            self.assertEqual(status, "ok")
            self.assertEqual(observed["incoming"], [])
            self.assertEqual(len(observed["names"]), 1)
            self.assertTrue(observed["names"][0].startswith(".tmp."))
            self.assertEqual(observed["modes"], [0o600])
            self.assertIn("asset-private", observed["journal"])
            self.assertEqual((incoming / "camera.bin").read_bytes(), payload)
            self.assertEqual(stat.S_IMODE((incoming / "camera.bin").stat().st_mode), 0o664)
            self.assertEqual(client.calls, {"get": 1, "stream": 1, "delete": 1})
            self.assertEqual(list(staging.iterdir()), [])

    async def test_same_size_mutation_before_delete_sends_no_delete(self):
        payload = b"ORIGINAL-CAMERA-BYTES"
        mutation = b"MUTATED!-CAMERA-BYTES"
        self.assertEqual(len(payload), len(mutation))
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            incoming, staging, _state = self.configure_asset(
                root, "asset-mutated", delete_upstream=True
            )
            client = AssetClient(payload, incoming)
            token_calls = 0

            async def token_then_mutate(_client):
                nonlocal token_calls
                token_calls += 1
                if token_calls == 2:
                    hidden = [path for path in staging.iterdir() if path.name.startswith(".tmp.")]
                    self.assertEqual(len(hidden), 1)
                    with hidden[0].open("r+b") as handle:
                        handle.write(mutation)
                        handle.flush()
                        os.fsync(handle.fileno())
                return "token"

            with (
                patch.object(app.httpx, "AsyncClient", return_value=client),
                patch.object(app, "get_token", side_effect=token_then_mutate),
                patch.object(app, "notify_failure", AsyncMock()),
            ):
                status = await app.process_asset("account-1", "asset-mutated")

            self.assertEqual(status, "error")
            self.assertEqual(token_calls, 2)
            self.assertEqual(client.calls["delete"], 0)
            self.assertEqual(list(incoming.iterdir()), [])
            self.assertEqual([path.read_bytes() for path in staging.iterdir()], [mutation])

    async def test_float_size_metadata_never_authorizes_upstream_delete(self):
        payload = b"float-size-must-not-delete"
        asset_id = "asset-float-size"
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            incoming, staging, state = self.configure_asset(
                root, asset_id, delete_upstream=True
            )
            client = AssetClient(payload, incoming)

            async def get_float_size_metadata(*_args, **_kwargs):
                client.calls["get"] += 1
                return FakeResponse(
                    body={
                        "name": "camera.bin",
                        "file_size": float(len(payload)),
                        "parent_id": "folder-1",
                        "media_links": {
                            "original": {
                                "url": "https://download.invalid/camera.bin"
                            }
                        },
                    }
                )

            client.get = get_float_size_metadata
            with (
                patch.object(app.httpx, "AsyncClient", return_value=client),
                patch.object(app, "get_token", AsyncMock(return_value="token")),
                patch.object(app, "notify_failure", AsyncMock()),
            ):
                status = await app.process_asset("account-1", asset_id)

            self.assertEqual(status, "retained")
            self.assertEqual(client.calls, {"get": 1, "stream": 1, "delete": 0})
            self.assertEqual((incoming / "camera.bin").read_bytes(), payload)
            self.assertEqual(list(staging.iterdir()), [])
            saved = json.loads(state.read_text())
            self.assertIn(asset_id, saved["retained_assets"])
            self.assertEqual(saved["pending_deletes"], {})

    async def test_rename_crash_recovers_without_redownload_or_suffix(self):
        payload = b"single-local-copy"
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            incoming, staging, state = self.configure_asset(
                root, "asset-crash", delete_upstream=False
            )
            client = AssetClient(payload, incoming)
            with (
                patch.object(app.httpx, "AsyncClient", return_value=client),
                patch.object(app, "get_token", AsyncMock(return_value="token")),
                patch.object(app, "notify_failure", AsyncMock()),
            ):
                with patch.object(
                    app, "_finish_publication", AsyncMock(return_value=False)
                ):
                    first = await app.process_asset("account-1", "asset-crash")
                after_crash = json.loads(state.read_text())
                second = await app.process_asset("account-1", "asset-crash")

            self.assertEqual((first, second), ("publication_finalize_failed", "retained"))
            self.assertEqual(client.calls, {"get": 1, "stream": 1, "delete": 0})
            self.assertEqual(
                after_crash["pending_publications"]["asset-crash"]["phase"],
                "renaming",
            )
            self.assertEqual(
                after_crash["pending_publications"]["asset-crash"]["destination_name"],
                "camera.bin",
            )
            self.assertIsNotNone(
                after_crash["pending_publications"]["asset-crash"]["handoff_name"]
            )
            self.assertEqual(
                {path.name: path.read_bytes() for path in incoming.iterdir()},
                {"camera.bin": payload},
            )
            final_state = json.loads(state.read_text())
            self.assertEqual(final_state["pending_publications"], {})
            self.assertEqual(final_state["pending_downloads"], {})
            self.assertEqual(list(staging.iterdir()), [])

    async def test_begin_publication_commit_uncertainty_preserves_recovery_stage(self):
        payload = b"state-replace-committed-before-fsync-error"
        asset_id = "asset-begin-uncertain"
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            incoming, staging, state = self.configure_asset(
                root, asset_id, delete_upstream=False
            )
            client = AssetClient(payload, incoming)
            root_node = root.stat()
            real_fsync = app.os.fsync
            injected = 0

            def fail_committed_publication_parent_fsync(fd):
                nonlocal injected
                node = os.fstat(fd)
                if (
                    injected == 0
                    and stat.S_ISDIR(node.st_mode)
                    and node.st_dev == root_node.st_dev
                    and node.st_ino == root_node.st_ino
                ):
                    saved = json.loads(state.read_text())
                    publication = saved.get("pending_publications", {}).get(asset_id)
                    if publication is not None and publication["phase"] == "ready":
                        injected += 1
                        raise OSError("simulated state parent fsync uncertainty")
                return real_fsync(fd)

            with (
                patch.object(app.httpx, "AsyncClient", return_value=client),
                patch.object(app, "get_token", AsyncMock(return_value="token")),
                patch.object(app, "notify_failure", AsyncMock()),
                patch.object(
                    app.os,
                    "fsync",
                    side_effect=fail_committed_publication_parent_fsync,
                ),
            ):
                first = await app.process_asset("account-1", asset_id)
                after_uncertain_write = json.loads(state.read_text())
                private_stages = list(staging.iterdir())
                private_stage_payloads = [path.read_bytes() for path in private_stages]
                second = await app.process_asset("account-1", asset_id)

            self.assertEqual(injected, 1)
            self.assertEqual((first, second), ("receipt_failed", "retained"))
            self.assertEqual(client.calls, {"get": 1, "stream": 1, "delete": 0})
            self.assertEqual(len(private_stages), 1)
            self.assertEqual(private_stage_payloads, [payload])
            self.assertEqual(
                after_uncertain_write["pending_publications"][asset_id]["phase"],
                "ready",
            )
            self.assertEqual((incoming / "camera.bin").read_bytes(), payload)
            final = json.loads(state.read_text())
            self.assertEqual(final["pending_publications"], {})
            self.assertEqual(final["pending_downloads"], {})
            self.assertEqual(list(staging.iterdir()), [])

    async def test_destination_journal_uncertainty_resets_before_handoff_removal(self):
        payload = b"handoff-journal-committed-before-fsync-error"
        asset_id = "asset-handoff-uncertain"
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            incoming, staging, state = self.configure_asset(
                root, asset_id, delete_upstream=False
            )
            client = AssetClient(payload, incoming)
            root_node = root.stat()
            real_fsync = app.os.fsync
            real_remove = app._remove_temp_if_same
            injected = 0
            observed = {}

            def fail_committed_renaming_parent_fsync(fd):
                nonlocal injected
                node = os.fstat(fd)
                if (
                    injected == 0
                    and stat.S_ISDIR(node.st_mode)
                    and node.st_dev == root_node.st_dev
                    and node.st_ino == root_node.st_ino
                ):
                    saved = json.loads(state.read_text())
                    publication = saved.get("pending_publications", {}).get(asset_id)
                    if publication is not None and publication["phase"] == "renaming":
                        hidden = [
                            path
                            for path in incoming.iterdir()
                            if path.name.startswith(".tmp.")
                        ]
                        observed["handoff_before_error"] = hidden[0].read_bytes()
                        injected += 1
                        raise OSError("simulated destination journal fsync uncertainty")
                return real_fsync(fd)

            def observe_reset_before_remove(directory_fd, temp_name, expected):
                saved = json.loads(state.read_text())
                publication = saved["pending_publications"][asset_id]
                observed["phase_at_remove"] = publication["phase"]
                observed["handoff_at_remove"] = publication["handoff_name"]
                return real_remove(directory_fd, temp_name, expected)

            with (
                patch.object(app.httpx, "AsyncClient", return_value=client),
                patch.object(app, "get_token", AsyncMock(return_value="token")),
                patch.object(app, "notify_failure", AsyncMock()),
                patch.object(
                    app.os,
                    "fsync",
                    side_effect=fail_committed_renaming_parent_fsync,
                ),
                patch.object(
                    app,
                    "_remove_temp_if_same",
                    side_effect=observe_reset_before_remove,
                ),
            ):
                first = await app.process_asset("account-1", asset_id)
                after_reset = json.loads(state.read_text())
                private_stages = list(staging.iterdir())
                private_stage_payloads = [path.read_bytes() for path in private_stages]
                incoming_after_reset = list(incoming.iterdir())
                second = await app.process_asset("account-1", asset_id)

            self.assertEqual(injected, 1)
            self.assertEqual((first, second), ("error", "retained"))
            self.assertEqual(client.calls, {"get": 1, "stream": 1, "delete": 0})
            self.assertEqual(observed["handoff_before_error"], payload)
            self.assertEqual(observed["phase_at_remove"], "ready")
            self.assertIsNone(observed["handoff_at_remove"])
            reset_entry = after_reset["pending_publications"][asset_id]
            self.assertEqual(reset_entry["phase"], "ready")
            self.assertIsNone(reset_entry["destination_name"])
            self.assertIsNone(reset_entry["handoff_name"])
            self.assertEqual(len(private_stages), 1)
            self.assertEqual(private_stage_payloads, [payload])
            self.assertEqual(incoming_after_reset, [])
            self.assertEqual((incoming / "camera.bin").read_bytes(), payload)
            final = json.loads(state.read_text())
            self.assertEqual(final["pending_publications"], {})
            self.assertEqual(final["pending_downloads"], {})
            self.assertEqual(list(staging.iterdir()), [])

    async def test_unsupported_renameat2_prevents_upstream_delete(self):
        payload = b"preserve-upstream"
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            incoming, staging, _state = self.configure_asset(
                root, "asset-no-rename", delete_upstream=True
            )
            client = AssetClient(payload, incoming)
            with (
                patch.object(app.httpx, "AsyncClient", return_value=client),
                patch.object(app, "get_token", AsyncMock(return_value="token")),
                patch.object(app, "notify_failure", AsyncMock()),
                patch.object(app, "_RENAMEAT2", None),
                patch.object(
                    app,
                    "_rename_noreplace",
                    side_effect=self.real_rename_noreplace,
                ),
            ):
                status = await app.process_asset("account-1", "asset-no-rename")

            self.assertEqual(status, "error")
            self.assertEqual(client.calls, {"get": 1, "stream": 1, "delete": 0})
            self.assertEqual(list(incoming.iterdir()), [])
            private_stages = list(staging.iterdir())
            self.assertEqual(len(private_stages), 1)
            self.assertEqual(private_stages[0].read_bytes(), payload)
            self.assertIn(
                "asset-no-rename",
                json.loads(_state.read_text())["pending_publications"],
            )

    async def test_rotated_refresh_token_survives_persistence_failure(self):
        state = Path(app.CFG["refresh_token_file"])
        write_private_state(state, {"refresh_token": "old-refresh"})
        app.CFG.update(
            webhook_secret="webhook-secret",
            adobe_client_id="client",
            adobe_client_secret="secret",
        )
        app._TOKEN_CACHE.update(token=None, expires_at=0.0)
        client = RotatingTokenClient(
            [
                FakeResponse(
                    body={
                        "access_token": "at-1",
                        "expires_in": 3600,
                        "refresh_token": "new-refresh",
                    }
                ),
                FakeResponse(
                    body={"access_token": "at-2", "expires_in": 3600}
                ),
            ]
        )
        real_save = app._save_refresh_token
        persist_calls = 0

        def flaky_save_refresh_token(token):
            nonlocal persist_calls
            persist_calls += 1
            if persist_calls == 1:
                raise OSError("simulated state write failure")
            return real_save(token)

        notify = AsyncMock()
        with patch.object(
            app, "_save_refresh_token", side_effect=flaky_save_refresh_token
        ), patch.object(app, "notify_failure", notify):
            self.assertEqual(await app._fetch_token(client), "at-1")

            self.assertEqual(app._TOKEN_CACHE["token"], "at-1")
            self.assertEqual(app._REFRESH_TOKEN_MEMORY, "new-refresh")
            self.assertTrue(app._REFRESH_TOKEN_PERSIST_ERROR)
            self.assertEqual(persist_calls, 1)
            notify.assert_awaited_once()
            self.assertEqual(notify.call_args.args[0], "refresh_token_persist")
            self.assertTrue(
                json.loads(state.read_text()).get("refresh_token")
                == "old-refresh"
            )

            status, body = app._collect_health()
            self.assertEqual(status, 503)
            self.assertIn(
                "rotated refresh token is not durably persisted", body["errors"]
            )

            self.assertEqual(
                client.post_records[0]["refresh_token"], "old-refresh"
            )

        self.assertEqual(await app._fetch_token(client), "at-2")
        self.assertEqual(
            client.post_records[1]["refresh_token"], "new-refresh"
        )
        self.assertEqual(app._TOKEN_CACHE["token"], "at-2")
        self.assertEqual(app._REFRESH_TOKEN_MEMORY, "new-refresh")
        self.assertFalse(app._REFRESH_TOKEN_PERSIST_ERROR)
        self.assertEqual(persist_calls, 1)
        self.assertEqual(
            json.loads(state.read_text()).get("refresh_token"), "new-refresh"
        )

        status, body = app._collect_health()
        self.assertEqual(status, 200)
        self.assertTrue(body["state_persistent"])
        self.assertEqual(body["errors"], [])

    async def test_health_single_flight_timeout_and_cached_reuse(self):
        release = threading.Event()
        completed = threading.Event()
        collect_count = [0]

        def gated_collect_health():
            collect_count[0] += 1
            try:
                if not release.wait(timeout=5):
                    raise RuntimeError("release was never set")
                return (
                    200,
                    {
                        "status": "ok",
                        "version": "1.0.0",
                        "uptime_seconds": 0,
                        "has_refresh_token": True,
                        "state_persistent": True,
                        "staging_private": True,
                        "errors": [],
                    },
                )
            finally:
                completed.set()

        try:
            with (
                patch.object(
                    app, "_collect_health", side_effect=gated_collect_health
                ),
                patch.object(app, "_HEALTH_PROBE_TIMEOUT_SECONDS", 0.01),
            ):
                async with asyncio.TaskGroup() as group:
                    first = group.create_task(app.health())
                    second = group.create_task(app.health())
                first_body = json.loads(first.result().body)
                self.assertEqual(first.result().status_code, 503)
                self.assertEqual(second.result().status_code, 503)
                self.assertIn(
                    "health filesystem probe timed out", first_body["errors"]
                )
                self.assertEqual(collect_count[0], 1)

                third = await app.health()
                self.assertEqual(third.status_code, 503)
                self.assertEqual(collect_count[0], 1)

                release.set()
                self.assertTrue(await asyncio.to_thread(completed.wait, 5))
                app._HEALTH_CACHE["expires_at"] = 0.0
                reused = await app.health()
                self.assertEqual(reused.status_code, 200)
                self.assertEqual(json.loads(reused.body)["status"], "ok")
                self.assertEqual(collect_count[0], 1)
                self.assertIsNone(app._HEALTH_PROBE_TASK)
        finally:
            release.set()

    async def test_health_strict_durable_state_and_id_limits(self):
        state = Path(app.CFG["refresh_token_file"])
        app.CFG.update(
            webhook_secret="webhook-secret",
            adobe_client_id="client",
            adobe_client_secret="secret",
        )

        over_200 = "x" * 201
        at_200 = "y" * 200
        over_8192 = "z" * 8193
        at_8192 = "w" * 8192

        invalid_scenarios = {
            "pending_downloads long asset id": {
                "pending_downloads": {over_200: "account-1"}
            },
            "pending_downloads long account id": {
                "pending_downloads": {"asset-1": over_200}
            },
            "reconcile_cursor long url": {
                "reconcile_cursor": {
                    "url": over_8192,
                    "account_id": "account-1",
                    "folder_id": "folder-1",
                }
            },
            "reconcile_cursor long account id": {
                "reconcile_cursor": {
                    "url": at_8192,
                    "account_id": over_200,
                    "folder_id": "folder-1",
                }
            },
            "reconcile_cursor long folder id": {
                "reconcile_cursor": {
                    "url": at_8192,
                    "account_id": "account-1",
                    "folder_id": over_200,
                }
            },
        }
        for label, state_value in invalid_scenarios.items():
            with self.subTest(label=label):
                write_private_state(state, state_value)
                app._HEALTH_CACHE["expires_at"] = 0.0
                response = await app.health()
                self.assertEqual(response.status_code, 503)
                body = json.loads(response.body)
                self.assertFalse(body["state_persistent"])
                self.assertIn("private state", " ".join(body["errors"]))

        write_private_state(
            state,
            {
                "pending_downloads": {at_200: at_200},
                "reconcile_cursor": {
                    "url": at_8192,
                    "account_id": at_200,
                    "folder_id": at_200,
                },
            },
        )
        app._HEALTH_CACHE["expires_at"] = 0.0
        boundary_response = await app.health()
        self.assertEqual(boundary_response.status_code, 200)
        body = json.loads(boundary_response.body)
        self.assertTrue(body["state_persistent"])
        self.assertEqual(body["errors"], [])

    async def test_fair_reconcile_rotation_starves_no_tail_job(self):
        app.CFG["frameio_workers"] = 2
        app._PROCESS_SEMAPHORE = asyncio.Semaphore(2)
        app._RECONCILE_ROTATION = 0
        ordered = [
            (f"asset-{letter}", "account-1")
            for letter in ("a", "b", "c", "d", "e")
        ]
        admitted = []
        process = AsyncMock(return_value="ok")
        with patch.object(app, "process_asset", process):
            for _ in range(3):
                count = await app._process_reconcile_jobs(ordered)
                self.assertEqual(count, 2)
                before = len(process.call_args_list)
                await self._drain_job_queue()
                batch = [
                    args.args[1]
                    for args in process.call_args_list[before:]
                ]
                admitted.append(batch)

        self.assertEqual(
            admitted,
            [
                ["asset-a", "asset-b"],
                ["asset-c", "asset-d"],
                ["asset-e", "asset-a"],
            ],
        )


if __name__ == "__main__":
    unittest.main()
