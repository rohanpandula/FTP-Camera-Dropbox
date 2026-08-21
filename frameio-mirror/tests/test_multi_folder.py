"""Multi-camera C2C folder registry: every paired device's ingest folder is
remembered and swept by reconciliation, not just the first one discovered."""
import asyncio
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import app


class MultiFolderRegistryTests(unittest.TestCase):
    def setUp(self):
        self._dir = tempfile.TemporaryDirectory()
        root = Path(self._dir.name)
        incoming = root / "incoming"
        staging = root / "staging"
        incoming.mkdir()
        staging.mkdir(mode=0o700)
        staging.chmod(0o700)
        self.state = root / "state.json"
        self.state.write_text("{}")
        self.state.chmod(0o600)
        self._saved = {
            k: app.CFG[k]
            for k in ("refresh_token_file", "incoming_dir", "staging_dir",
                      "c2c_folder_id", "c2c_account_id")
        }
        app.CFG.update(
            refresh_token_file=str(self.state),
            incoming_dir=str(incoming),
            staging_dir=str(staging),
            c2c_folder_id="",
            c2c_account_id="",
        )
        # Ordinary temp-directory tests cannot create distinct Linux mounts.
        # Production still enforces the separate private state/staging mount.
        self.mount_patcher = patch.object(
            app, "_require_private_staging_mount", return_value=None
        )
        self.mount_patcher.start()

    def tearDown(self):
        self.mount_patcher.stop()
        app.CFG.update(self._saved)
        self._dir.cleanup()

    def remember(self, folder, account="acct-1"):
        asyncio.run(app._remember_c2c_folder(folder, account))

    def test_first_discovery_sets_legacy_and_list(self):
        self.remember("folder-a")
        state = app._load_state()
        self.assertEqual(state["c2c_folder_id"], "folder-a")
        self.assertEqual(state["c2c_account_id"], "acct-1")
        self.assertEqual(state["c2c_folder_ids"], ["folder-a"])
        self.assertEqual(app._reconcile_folder_ids(), ["folder-a"])

    def test_second_camera_folder_extends_registry(self):
        self.remember("folder-a")
        self.remember("folder-b")
        state = app._load_state()
        # Legacy single id keeps its first value for state-file compatibility.
        self.assertEqual(state["c2c_folder_id"], "folder-a")
        self.assertEqual(state["c2c_folder_ids"], ["folder-a", "folder-b"])
        self.assertEqual(app._reconcile_folder_ids(), ["folder-a", "folder-b"])

    def test_duplicate_folder_is_a_noop(self):
        self.remember("folder-a")
        before = self.state.read_bytes()
        self.remember("folder-a")
        self.assertEqual(self.state.read_bytes(), before)

    def test_registry_merges_legacy_only_state(self):
        # State written by a pre-multi-folder build: single id only.
        app._save_state({"c2c_folder_id": "legacy-f", "c2c_account_id": "acct-1"})
        self.assertEqual(app._reconcile_folder_ids(), ["legacy-f"])
        self.remember("folder-b")
        self.assertEqual(app._reconcile_folder_ids(), ["legacy-f", "folder-b"])

    def test_registry_rejects_garbage_and_caps(self):
        app._save_state({
            "c2c_folder_id": "f-0",
            "c2c_account_id": "acct-1",
            "c2c_folder_ids": ["f-0", 7, "", "x" * 201]
            + [f"f-{i}" for i in range(1, 20)],
        })
        ids = app._reconcile_folder_ids()
        self.assertEqual(ids[0], "f-0")
        self.assertNotIn("", ids)
        self.assertNotIn(7, ids)
        self.assertLessEqual(len(ids), 16)
        self.remember("f-new")  # registry full: refused without crashing
        self.assertNotIn("f-new", app._reconcile_folder_ids())

    def test_invalid_parent_folder_ignored(self):
        self.remember(None)
        self.remember("")
        self.remember("y" * 201)
        self.assertEqual(app._load_state(), {})
        self.assertEqual(app._reconcile_folder_ids(), [])


if __name__ == "__main__":
    unittest.main()
