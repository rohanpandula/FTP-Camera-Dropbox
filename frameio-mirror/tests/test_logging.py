"""Regression tests for OBS-03.

On 2026-08-23 the Frame.io mirror logged `Reconcile listing failed: ` with
nothing after the colon. The cause was an httpx timeout:
`str(httpx.ReadTimeout(""))` is the empty string, so `log.error("...: %s",
exc)` rendered a blank. These tests pin both blind sites — the reconcile
listing handler and the Telegram send handler — to always name the
exception's type, even when its message is empty.
"""
import asyncio
import logging
import os
import tempfile
from pathlib import Path
from unittest.mock import patch

import httpx
import pytest

import app


def _setup_reconcile_env():
    """Point CFG at a scratch dir and seed one paired folder so
    reconcile_once reaches the httpx client instead of short-circuiting.
    Mirrors the setUp fixture in test_multi_folder.py."""
    tmpdir = tempfile.TemporaryDirectory()
    root = Path(os.path.realpath(tmpdir.name))
    incoming = root / "incoming"
    staging = root / "staging"
    incoming.mkdir()
    staging.mkdir(mode=0o700)
    staging.chmod(0o700)
    state = root / "state.json"
    state.write_text("{}")
    state.chmod(0o600)

    original_cfg = {
        k: app.CFG[k]
        for k in (
            "refresh_token_file", "incoming_dir", "staging_dir",
            "adobe_client_id", "adobe_client_secret",
            "c2c_folder_id", "c2c_account_id",
        )
    }
    app.CFG.update(
        refresh_token_file=str(state),
        incoming_dir=str(incoming),
        staging_dir=str(staging),
        adobe_client_id="test-client",
        adobe_client_secret="test-secret",
        c2c_folder_id="",
        c2c_account_id="",
    )
    mount_patcher = patch.object(app, "_require_private_staging_mount", return_value=None)
    mount_patcher.start()

    original_tg = app._TG
    app._TG = None  # keep notify_failure offline (T-03-13) — no network in this test

    app._save_state({
        "c2c_folder_id": "folder-a",
        "c2c_account_id": "acct-1",
        "c2c_folder_ids": ["folder-a"],
    })

    def _teardown():
        app.CFG.update(original_cfg)
        app._TG = original_tg
        mount_patcher.stop()
        tmpdir.cleanup()

    return _teardown


def test_reconcile_listing_failure_names_the_exception_type(caplog, monkeypatch):
    caplog.set_level(logging.WARNING, logger="frameio-mirror")
    teardown = _setup_reconcile_env()
    try:
        async def _raise_read_timeout(client):
            raise httpx.ReadTimeout("")

        monkeypatch.setattr(app, "get_token", _raise_read_timeout)
        asyncio.run(app.reconcile_once())
    finally:
        teardown()

    assert "ReadTimeout" in caplog.text
    assert "Reconcile listing failed" in caplog.text


def test_telegram_send_failure_names_the_exception_type(caplog, monkeypatch):
    caplog.set_level(logging.WARNING, logger="frameio-mirror")
    original_tg = app._TG
    app._TG = {"bot_token": "test-token", "chat_id": "123"}
    try:
        async def _raise_connect_timeout(self, *args, **kwargs):
            raise httpx.ConnectTimeout("")

        monkeypatch.setattr(httpx.AsyncClient, "post", _raise_connect_timeout)
        result = asyncio.run(app._tg_send("x"))
    finally:
        app._TG = original_tg

    assert result is False
    assert "ConnectTimeout" in caplog.text
    assert "Telegram send exception" in caplog.text
