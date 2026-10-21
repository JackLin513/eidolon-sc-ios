"""The health check (#165): whether the backend can serve, which it cannot unless it reads
the database in time; needing no session, for compose to ask it."""

import asyncio
import logging
import time
from pathlib import Path

import pytest

import eidolon.app
import eidolon.loop_lag
from eidolon.database import readable
from eidolon.loop_lag import watch_the_loop
from eidolon.server_logs import WithoutQuery
from tests.conftest import ClientFactory
from tests.fakes import FakeLLM


async def test_the_backend_is_healthy_while_it_reads_the_database(make_client: ClientFactory):
    res = await make_client(FakeLLM(), user=None).get("/api/health")

    assert (res.status_code, res.json()) == (200, {"ok": True})


async def test_the_backend_is_not_healthy_when_it_cannot_read_the_database(
    make_client: ClientFactory, monkeypatch: pytest.MonkeyPatch
):
    monkeypatch.setattr(eidolon.app, "readable", lambda path: False)

    res = await make_client(FakeLLM(), user=None).get("/api/health")

    assert (res.status_code, res.json()) == (503, {"ok": False})


async def test_the_backend_is_not_healthy_when_reading_takes_too_long(
    make_client: ClientFactory, monkeypatch: pytest.MonkeyPatch
):
    def slow(path: Path) -> bool:
        time.sleep(0.3)
        return True

    monkeypatch.setattr(eidolon.app, "readable", slow)
    monkeypatch.setattr(eidolon.app, "HEALTH_TIMEOUT", 0.05)

    res = await make_client(FakeLLM(), user=None).get("/api/health")

    assert res.status_code == 503


def test_a_file_that_is_not_a_database_is_not_readable(tmp_path: Path):
    broken = tmp_path / "eidolon.db"
    broken.write_bytes(b"not a database, though long enough to look like a header" * 4)

    assert not readable(broken)


async def test_an_event_loop_running_late_is_logged_with_the_calls_then(
    monkeypatch: pytest.MonkeyPatch, caplog: pytest.LogCaptureFixture
):
    monkeypatch.setattr(eidolon.loop_lag, "INTERVAL", 0.02)
    monkeypatch.setattr(eidolon.loop_lag, "TOLERATED", 0.1)
    watching = asyncio.create_task(watch_the_loop(lambda: 3))
    try:
        with caplog.at_level(logging.WARNING, logger="eidolon.loop_lag"):
            await asyncio.sleep(0.1)  # on time: nothing logged
            on_time = list(caplog.messages)
            time.sleep(0.3)  # blocking the loop
            await asyncio.sleep(0.05)
    finally:
        watching.cancel()

    assert on_time == []
    [late] = caplog.messages
    assert "ms late, 3 calls in progress" in late


def test_the_access_log_keeps_no_query():
    record = logging.LogRecord(
        "uvicorn.access", logging.INFO, __file__, 0, '%s - "%s %s HTTP/%s" %d',
        ("127.0.0.1:5000", "GET", "/api/auth/github/callback?code=secret&state=s", "1.1", 302),
        None,
    )

    assert WithoutQuery().filter(record)
    assert record.getMessage() == '127.0.0.1:5000 - "GET /api/auth/github/callback HTTP/1.1" 302'
