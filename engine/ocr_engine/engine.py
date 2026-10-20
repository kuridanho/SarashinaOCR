"""Engine state machine and OCR pipeline (spec sections 8.3 and 10)."""

from __future__ import annotations

import logging
import os
import platform
import threading
import time
from pathlib import Path
from typing import Any, Callable

from .backends.base import Backend
from .errors import OcrError
from .postprocess import (
    detect_warnings,
    extract_figures,
    normalize_math_delimiters,
    sanitize_markdown,
    strip_code_fences,
    to_plain_text,
)
from .preprocess import prepare_image
from .version import (
    DEFAULT_MAX_NEW_TOKENS,
    DEFAULT_PRESET,
    ENGINE_VERSION,
    MAX_NEW_TOKENS_LIMIT,
    PRESETS,
    PROTOCOL_VERSION,
    REPETITION_PENALTY,
    preset_max_pixels,
)

log = logging.getLogger(__name__)

Emit = Callable[[str, dict[str, Any]], None]


class EngineService:
    """Serializes requests against a single backend instance."""

    def __init__(
        self,
        backend: Backend,
        *,
        model_dir: str | Path | None = None,
        model_revision: str | None = None,
    ):
        self.backend = backend
        self.model_dir = Path(model_dir).expanduser() if model_dir else None
        self.model_revision = model_revision or backend.model_revision
        self.state = "unloaded"
        self.last_error: OcrError | None = None
        self._cancel = threading.Event()
        self._busy = False

    # ------------------------------------------------------------------ hello
    def hello(self) -> dict[str, Any]:
        model_present = bool(
            self.model_dir
            and self.model_dir.is_dir()
            and any(self.model_dir.glob("*.safetensors"))
        )
        return {
            "protocol": PROTOCOL_VERSION,
            "engine": ENGINE_VERSION,
            "backend": self.backend.name,
            "device": _device_name(),
            "memory_gb": _memory_gb(),
            "python": platform.python_version(),
            "state": self.state,
            "busy": self._busy,
            "model": {
                "present": model_present,
                "path": str(self.model_dir) if self.model_dir else None,
                "revision": self.model_revision,
                "state": self.state,
                "last_error": self.last_error.to_dict() if self.last_error else None,
            },
            "presets": PRESETS,
            "defaults": {
                "preset": DEFAULT_PRESET,
                "max_new_tokens": DEFAULT_MAX_NEW_TOKENS,
                "repetition_penalty": REPETITION_PENALTY,
            },
        }

    # ------------------------------------------------------------------- load
    def load(self, emit: Emit | None = None) -> dict[str, Any]:
        def stage(name: str, data: dict) -> None:
            if emit:
                emit("stage", {"stage": name, **data})

        if self.backend.is_loaded:
            self.state = "ready"
            return {"state": self.state, "loaded": True}
        self.state = "loading"
        self.last_error = None
        try:
            self.backend.load(on_stage=stage)
        except OcrError as exc:
            self.state = "error"
            self.last_error = exc
            raise
        except Exception as exc:  # pragma: no cover - backend specific
            self.state = "error"
            self.last_error = OcrError("E1001", str(exc))
            raise self.last_error from exc
        self.state = "ready"
        return {"state": self.state, "loaded": True}

    def unload(self) -> dict[str, Any]:
        self._cancel.set()
        try:
            self.backend.unload()
        finally:
            self.state = "unloaded"
            self._cancel.clear()
        return {"state": self.state, "loaded": False}

    def cancel(self) -> None:
        self._cancel.set()

    # -------------------------------------------------------------------- ocr
    def ocr(self, params: dict[str, Any], emit: Emit) -> dict[str, Any]:
        if self.state == "running":
            raise OcrError("E5004", "別のリクエストを実行中です")
        if not self.backend.is_loaded:
            # The host is allowed to send ocr without an explicit load.
            self.load(emit)

        image_path = params.get("image")
        if not isinstance(image_path, str) or not image_path:
            raise OcrError("E2001", "image パラメータがありません")
        image_file = Path(image_path).expanduser()
        if not image_file.is_file():
            raise OcrError("E2001", f"画像が見つかりません: {image_file}")

        preset = params.get("preset") or DEFAULT_PRESET
        try:
            max_pixels = int(params.get("max_pixels") or preset_max_pixels(preset))
        except ValueError as exc:
            raise OcrError("E2002", str(exc)) from exc
        max_new_tokens = int(params.get("max_new_tokens") or DEFAULT_MAX_NEW_TOKENS)
        max_new_tokens = max(1, min(max_new_tokens, MAX_NEW_TOKENS_LIMIT))
        figures_dir = params.get("figures_dir")
        if figures_dir is not None:
            figures_dir = Path(str(figures_dir)).expanduser()
        asset_prefix = str(params.get("asset_prefix") or "assets")

        self._cancel.clear()
        self.state = "running"
        self._busy = True
        started = time.monotonic()
        try:
            emit("stage", {"stage": "preprocess", "preset": preset, "max_pixels": max_pixels})
            pre_started = time.monotonic()
            image, info = prepare_image(image_file, max_pixels=max_pixels)
            emit(
                "stage",
                {
                    "stage": "preprocess_done",
                    "seconds": round(time.monotonic() - pre_started, 3),
                    **info.to_dict(),
                },
            )

            def on_stage(name: str, data: dict) -> None:
                emit("stage", {"stage": name, **data})

            def on_token(text: str) -> None:
                emit("token", {"text": text})

            result = self.backend.generate(
                image,
                max_new_tokens=max_new_tokens,
                cancel_event=self._cancel,
                on_token=on_token,
                on_stage=on_stage,
            )

            post_started = time.monotonic()
            emit("stage", {"stage": "postprocess"})
            raw = result.text
            markdown = strip_code_fences(raw)
            markdown = normalize_math_delimiters(markdown)
            markdown = sanitize_markdown(markdown)
            markdown, figures = extract_figures(
                markdown, image, assets_dir=figures_dir, asset_prefix=asset_prefix
            )
            plain = to_plain_text(markdown)
            warnings = detect_warnings(
                raw,
                output_tokens=result.output_tokens,
                max_new_tokens=max_new_tokens,
                eos_reached=result.eos_reached,
                cancelled=result.cancelled,
            )
            elapsed = time.monotonic() - started
            data = {
                "raw": raw,
                "markdown": markdown,
                "text": plain,
                "figures": [figure.to_dict() for figure in figures],
                "warnings": [warning.to_dict() for warning in warnings],
                "cancelled": result.cancelled,
                "image": info.to_dict(),
                "stats": {
                    "prompt_tokens": result.prompt_tokens,
                    "output_tokens": result.output_tokens,
                    "seconds": round(elapsed, 3),
                    "prefill_seconds": round(result.prefill_seconds, 3),
                    "decode_seconds": round(result.decode_seconds, 3),
                    "tok_per_s": round(result.tok_per_s, 2),
                    "peak_memory_mb": result.peak_memory_mb,
                    "truncated": bool(
                        not result.eos_reached
                        and result.output_tokens >= max_new_tokens
                        and not result.cancelled
                    ),
                    "eos_reached": result.eos_reached,
                    "postprocess_seconds": round(time.monotonic() - post_started, 3),
                    "preset": preset,
                    "max_new_tokens": max_new_tokens,
                    "max_pixels": max_pixels,
                    "model_revision": self.model_revision,
                },
                "metadata": result.metadata,
            }
            return data
        finally:
            self._busy = False
            self.state = "ready" if self.backend.is_loaded else "unloaded"


def _device_name() -> str:
    try:
        import subprocess

        return (
            subprocess.check_output(["sysctl", "-n", "machdep.cpu.brand_string"], text=True)
            .strip()
        )
    except Exception:
        return platform.processor() or platform.machine()


def _memory_gb() -> float:
    try:
        return round(os.sysconf("SC_PHYS_PAGES") * os.sysconf("SC_PAGE_SIZE") / 1024**3, 1)
    except (ValueError, OSError, AttributeError):
        return 0.0
