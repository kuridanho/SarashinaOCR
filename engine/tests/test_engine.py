from __future__ import annotations

from pathlib import Path

import pytest
from PIL import Image

from ocr_engine.backends.mock import MockBackend
from ocr_engine.engine import EngineService
from ocr_engine.errors import OcrError


@pytest.fixture()
def image_path(tmp_path: Path) -> Path:
    path = tmp_path / "page.png"
    Image.new("RGB", (800, 1200), "white").save(path)
    return path


def test_mock_pipeline(image_path: Path, tmp_path: Path) -> None:
    service = EngineService(MockBackend(), model_revision="mock")
    events: list[tuple[str, dict]] = []
    data = service.ocr(
        {
            "image": str(image_path),
            "preset": "fast",
            "figures_dir": str(tmp_path / "assets"),
        },
        lambda event, payload: events.append((event, payload)),
    )

    assert data["markdown"].startswith("# 請求書")
    assert "![図1](assets/fig-001.png)" in data["markdown"]
    assert len(data["figures"]) == 1
    assert data["stats"]["output_tokens"] > 0
    assert (tmp_path / "assets" / "fig-001.png").is_file()
    assert any(event == "token" for event, _ in events)
    assert any(payload.get("stage") == "postprocess" for _, payload in events)


def test_missing_image_reports_e2001(tmp_path: Path) -> None:
    service = EngineService(MockBackend(), model_revision="mock")
    with pytest.raises(OcrError) as info:
        service.ocr({"image": str(tmp_path / "missing.png")}, lambda *_: None)
    assert info.value.code == "E2001"


def test_cancel_preserves_partial_result(image_path: Path, tmp_path: Path, monkeypatch) -> None:
    backend = MockBackend(delay=0.01)
    service = EngineService(backend, model_revision="mock")

    import threading

    timer = threading.Timer(0.05, service.cancel)
    timer.start()
    data = service.ocr(
        {"image": str(image_path), "figures_dir": str(tmp_path / "assets")},
        lambda *_: None,
    )
    timer.cancel()
    assert data["cancelled"] is True
    assert any(w["code"] == "W4001" for w in data["warnings"])
