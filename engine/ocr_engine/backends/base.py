"""Backend interface shared by the MLX engine and the deterministic mock."""

from __future__ import annotations

import threading
from dataclasses import dataclass, field
from typing import Callable, Protocol

from PIL import Image

TokenCallback = Callable[[str], None]
StageCallback = Callable[[str, dict], None]


@dataclass
class GenerationResult:
    text: str
    prompt_tokens: int = 0
    output_tokens: int = 0
    prefill_seconds: float = 0.0
    decode_seconds: float = 0.0
    seconds: float = 0.0
    tok_per_s: float = 0.0
    peak_memory_mb: float | None = None
    cancelled: bool = False
    eos_reached: bool = False
    metadata: dict = field(default_factory=dict)


class Backend(Protocol):
    name: str
    model_revision: str | None

    @property
    def is_loaded(self) -> bool: ...

    def load(self, on_stage: StageCallback | None = None) -> None: ...

    def unload(self) -> None: ...

    def generate(
        self,
        image: Image.Image,
        *,
        max_new_tokens: int,
        cancel_event: threading.Event,
        on_token: TokenCallback,
        on_stage: StageCallback | None = None,
    ) -> GenerationResult: ...
