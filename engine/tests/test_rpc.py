from __future__ import annotations

import json
import os
import subprocess
import sys
import threading
from pathlib import Path

import pytest
from PIL import Image

ENGINE_ROOT = Path(__file__).resolve().parents[1]


class EngineProcess:
    def __init__(self):
        env = dict(os.environ)
        env["PYTHONPATH"] = str(ENGINE_ROOT)
        self.proc = subprocess.Popen(
            [sys.executable, "-m", "ocr_engine", "--backend", "mock", "--mock-delay", "0.01"],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            bufsize=1,
            cwd=ENGINE_ROOT,
            env=env,
        )
        self._counter = 0
        self._lock = threading.Lock()

    def request(self, method: str, params: dict | None = None, request_id: str | None = None) -> str:
        if request_id is None:
            with self._lock:
                self._counter += 1
                request_id = f"req-{self._counter}"
        frame = {"v": 1, "id": request_id, "method": method, "params": params or {}}
        assert self.proc.stdin is not None
        self.proc.stdin.write(json.dumps(frame, ensure_ascii=False) + "\n")
        self.proc.stdin.flush()
        return request_id

    def wait(self, request_id: str, timeout: float = 20.0) -> tuple[list[dict], dict]:
        assert self.proc.stdout is not None
        events: list[dict] = []
        while True:
            line = self.proc.stdout.readline()
            if not line:
                raise RuntimeError("engine closed stdout")
            frame = json.loads(line)
            if frame.get("id") != request_id:
                continue
            events.append(frame)
            if frame["event"] in ("done", "error"):
                return events, frame

    def close(self):
        if self.proc.poll() is None:
            try:
                self.request("shutdown")
                self.proc.wait(timeout=10)
            except Exception:
                self.proc.kill()


@pytest.fixture()
def engine():
    process = EngineProcess()
    yield process
    process.close()


@pytest.fixture()
def image_path(tmp_path: Path) -> Path:
    path = tmp_path / "page.png"
    Image.new("RGB", (900, 1400), "white").save(path)
    return path


def test_hello(engine: EngineProcess) -> None:
    request_id = engine.request("hello")
    _, final = engine.wait(request_id)
    assert final["event"] == "done"
    assert final["data"]["protocol"] == 1
    assert final["data"]["backend"] == "mock"


def test_load_and_ocr_stream(engine: EngineProcess, image_path: Path, tmp_path: Path) -> None:
    request_id = engine.request("load")
    _, final = engine.wait(request_id)
    assert final["event"] == "done"

    request_id = engine.request(
        "ocr",
        {"image": str(image_path), "figures_dir": str(tmp_path / "assets"), "preset": "fast"},
    )
    events, final = engine.wait(request_id)
    assert final["event"] == "done"
    assert final["data"]["markdown"].startswith("# 請求書")
    assert any(event["event"] == "token" for event in events)
    assert (tmp_path / "assets" / "fig-001.png").is_file()


def test_cancel_rpc(engine: EngineProcess, image_path: Path) -> None:
    engine.wait(engine.request("load"))
    ocr_id = engine.request(
        "ocr", {"image": str(image_path), "max_new_tokens": 4000, "preset": "fast"}
    )
    cancel_id = engine.request("cancel", {"target": ocr_id})
    _, cancel_frame = engine.wait(cancel_id)
    assert cancel_frame["event"] == "done"

    events, final = engine.wait(ocr_id)
    assert final["event"] == "done"
    assert final["data"]["cancelled"] is True


def test_ocr_without_load_auto_loads(engine: EngineProcess, image_path: Path) -> None:
    request_id = engine.request("ocr", {"image": str(image_path), "preset": "fast"})
    _, final = engine.wait(request_id)
    assert final["event"] == "done"
