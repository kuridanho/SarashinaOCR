"""Deterministic mock backend used by tests and by UI development without MLX."""

from __future__ import annotations

import threading
import time

from PIL import Image

from .base import GenerationResult, StageCallback, TokenCallback

_MOCK_MARKDOWN = """# 請求書

以下の内容でご請求申し上げます。

| 品目 | 数量 | 金額 |
|---|---|---|
| 印刷費 | 1 | 12,000 |
| 配送費 | 1 | 1,500 |

合計 **13,500 円**（税込）

数式: $E = mc^2$

<bbox>[(120, 340), (480, 620)]</bbox>

以上
"""


class MockBackend:
    name = "mock"
    model_revision = "mock"

    def __init__(self, *, delay: float = 0.0):
        self._loaded = False
        self._delay = delay

    @property
    def is_loaded(self) -> bool:
        return self._loaded

    def load(self, on_stage: StageCallback | None = None) -> None:
        if on_stage:
            on_stage("model_load", {"progress": 0.0})
        time.sleep(0.01)
        self._loaded = True
        if on_stage:
            on_stage("model_load", {"progress": 1.0})

    def unload(self) -> None:
        self._loaded = False

    def generate(
        self,
        image: Image.Image,
        *,
        max_new_tokens: int,
        cancel_event: threading.Event,
        on_token: TokenCallback,
        on_stage: StageCallback | None = None,
    ) -> GenerationResult:
        if not self._loaded:
            raise RuntimeError("mock backend is not loaded")
        if on_stage:
            on_stage("prefill", {"detail": "mock"})
        time.sleep(self._delay)
        started = time.monotonic()
        text = _MOCK_MARKDOWN[: max(0, max_new_tokens)]
        chunks = [text[i : i + 12] for i in range(0, len(text), 12)]
        emitted = ""
        for chunk in chunks:
            if cancel_event.is_set():
                return GenerationResult(
                    text=emitted,
                    prompt_tokens=3201,
                    output_tokens=len(emitted) // 2,
                    seconds=time.monotonic() - started,
                    cancelled=True,
                    eos_reached=False,
                )
            emitted += chunk
            on_token(chunk)
            if self._delay:
                time.sleep(self._delay)
        elapsed = max(time.monotonic() - started, 1e-6)
        return GenerationResult(
            text=text,
            prompt_tokens=3201,
            output_tokens=len(chunks) * 6,
            seconds=elapsed,
            tok_per_s=len(chunks) * 6 / elapsed,
            eos_reached=True,
            metadata={"backend": "mock"},
        )
