"""MLX 4bit backend for Sarashina2.2-OCR.

This follows the official recipe from ``tokimoa/sarashina2.2-ocr-mlx-4bit``:
the repository's custom model class is imported first, then mlx-vlm's
``load_model`` is used with a manual greedy decode loop (repetition penalty
1.2, EOS id 2).
"""

from __future__ import annotations

import gc
import logging
import sys
import threading
import time
from dataclasses import dataclass
from pathlib import Path

from PIL import Image

from ..errors import OcrError
from ..version import EOS_TOKEN_ID, REPETITION_PENALTY
from .base import GenerationResult, StageCallback, TokenCallback

log = logging.getLogger(__name__)

_STREAM_INTERVAL = 6


def _is_memory_error(exc: BaseException) -> bool:
    text = str(exc).lower()
    return isinstance(exc, MemoryError) or any(
        needle in text
        for needle in ("out of memory", "insufficient memory", "memory allocation", "oom")
    )


@dataclass
class _LoadedModel:
    model: object
    processor: object
    layers: int


class MlxBackend:
    name = "mlx"
    model_revision: str | None = None

    def __init__(self, model_dir: str | Path, *, revision: str | None = None):
        self.model_dir = Path(model_dir).expanduser()
        self.model_revision = revision
        self._loaded: _LoadedModel | None = None
        self._model_imported = False
        self._lock = threading.Lock()

    @property
    def is_loaded(self) -> bool:
        return self._loaded is not None

    def _ensure_model_files(self) -> None:
        if not self.model_dir.is_dir():
            raise OcrError("E1001", f"モデルディレクトリがありません: {self.model_dir}")
        if not any(self.model_dir.glob("*.safetensors")):
            raise OcrError("E1001", f"モデルの重みがありません: {self.model_dir}")
        if not (self.model_dir / "config.json").is_file():
            raise OcrError("E1001", f"config.json がありません: {self.model_dir}")

    def _import_custom_model(self) -> None:
        if self._model_imported:
            return
        path = str(self.model_dir.resolve())
        if path not in sys.path:
            sys.path.insert(0, path)
        try:
            import sarashina2_vision  # noqa: F401  (registers mlx_vlm.models.sarashina2_vision)
        except Exception as exc:  # pragma: no cover - depends on model files
            raise OcrError("E1001", f"同梱モデルコードを読み込めません: {exc}") from exc
        self._model_imported = True

    def load(self, on_stage: StageCallback | None = None) -> None:
        with self._lock:
            if self._loaded is not None:
                return
            self._ensure_model_files()
            started = time.monotonic()
            if on_stage:
                on_stage("model_load", {"progress": 0.0})
            self._import_custom_model()

            try:
                from mlx_vlm.utils import load_model

                # lazy=True keeps handshake fast; weights are evaluated on the
                # first prefill and reported there (spec section 1.3 note).
                model = load_model(self.model_dir, lazy=True)
            except Exception as exc:  # pragma: no cover - depends on model files
                if _is_memory_error(exc):
                    raise OcrError("E3001", "モデルの読み込み中にメモリが不足しました") from exc
                raise OcrError("E1001", f"モデルを読み込めません: {exc}") from exc

            try:
                from transformers import AutoProcessor

                processor = AutoProcessor.from_pretrained(
                    str(self.model_dir), trust_remote_code=True, local_files_only=True
                )
            except Exception as exc:  # pragma: no cover
                del model
                gc.collect()
                raise OcrError("E1001", f"プロセッサを読み込めません: {exc}") from exc

            layers = len(getattr(model, "layers", []) or [])
            self._loaded = _LoadedModel(model=model, processor=processor, layers=layers)
            if on_stage:
                on_stage(
                    "model_load",
                    {
                        "progress": 1.0,
                        "seconds": round(time.monotonic() - started, 3),
                        "layers": layers,
                    },
                )
            log.info("model loaded in %.3fs (lazy)", time.monotonic() - started)

    def unload(self) -> None:
        with self._lock:
            if self._loaded is None:
                return
            self._loaded = None
            gc.collect()
            try:
                import mlx.core as mx

                mx.clear_cache()
            except Exception:  # pragma: no cover
                pass

    def generate(
        self,
        image: Image.Image,
        *,
        max_new_tokens: int,
        cancel_event: threading.Event,
        on_token: TokenCallback,
        on_stage: StageCallback | None = None,
    ) -> GenerationResult:
        if self._loaded is None:
            raise OcrError("E1001", "モデルがロードされていません")

        import mlx.core as mx
        from mlx_vlm.models.cache import KVCache

        model = self._loaded.model
        processor = self._loaded.processor
        started = time.monotonic()

        try:
            mx.reset_peak_memory()
            message = [{"role": "user", "content": [{"type": "image", "image": image}]}]
            inputs = processor.apply_chat_template(
                message,
                tokenize=True,
                add_generation_prompt=True,
                return_dict=True,
                return_tensors="np",
            )
            input_ids = mx.array(inputs["input_ids"])
            pixel_values = mx.array(inputs["pixel_values"])
            grid = mx.array(inputs["image_grid_thw"])
            prompt_tokens = int(input_ids.shape[1])

            if on_stage:
                on_stage("prefill", {"prompt_tokens": prompt_tokens})
            prefill_started = time.monotonic()
            cache = [KVCache() for _ in range(self._loaded.layers)]
            output = model(
                input_ids,
                pixel_values,
                cache=cache,
                image_grid_thw=grid,
            )
            logits = output.logits if hasattr(output, "logits") else output[0]
            mx.eval(logits)
            prefill_seconds = time.monotonic() - prefill_started

            if cancel_event.is_set():
                return GenerationResult(
                    text="",
                    prompt_tokens=prompt_tokens,
                    seconds=time.monotonic() - started,
                    prefill_seconds=prefill_seconds,
                    peak_memory_mb=round(mx.get_peak_memory() / (1024 * 1024), 1),
                    cancelled=True,
                )

            if on_stage:
                on_stage("decode", {"prompt_tokens": prompt_tokens})

            seen: set[int] = {int(token) for token in inputs["input_ids"][0]}
            generated: list[int] = []
            decode_started = time.monotonic()
            eos_reached = False
            decoded = ""
            cancelled = False

            for step in range(max_new_tokens):
                if cancel_event.is_set():
                    cancelled = True
                    break

                logit = logits[0, -1, :].astype(mx.float32)
                indices = mx.array(sorted(seen))
                values = logit[indices]
                logit[indices] = mx.where(
                    values < 0, values * REPETITION_PENALTY, values / REPETITION_PENALTY
                )
                token = int(mx.argmax(logit).item())

                if token == EOS_TOKEN_ID:
                    eos_reached = True
                    break

                generated.append(token)
                seen.add(token)
                logits = model.language_model(mx.array([[token]]), cache=cache).logits

                if len(generated) % _STREAM_INTERVAL == 0:
                    current = _decode(processor, generated)
                    if current.startswith(decoded):
                        delta = current[len(decoded) :]
                        decoded = current
                        if delta:
                            on_token(delta)
                    else:
                        # Tokenizer boundary changed a previously decoded prefix.
                        decoded = current

                if step == 0 and on_stage:
                    on_stage("first_token", {})

            decode_seconds = time.monotonic() - decode_started
            final = _decode(processor, generated)
            if cancelled and final.startswith(decoded):
                delta = final[len(decoded) :]
                if delta:
                    on_token(delta)
            elif not cancelled and not final.startswith(decoded):
                # Emit the reconciliation text so callers can replace the view.
                on_token(final)

            elapsed = max(time.monotonic() - started, 1e-6)
            return GenerationResult(
                text=final,
                prompt_tokens=prompt_tokens,
                output_tokens=len(generated),
                prefill_seconds=prefill_seconds,
                decode_seconds=decode_seconds,
                seconds=elapsed,
                tok_per_s=len(generated) / max(decode_seconds, 1e-6),
                peak_memory_mb=round(mx.get_peak_memory() / (1024 * 1024), 1),
                cancelled=cancelled,
                eos_reached=eos_reached,
                metadata={
                    "backend": "mlx",
                    "model_revision": self.model_revision,
                    "bits": 4,
                },
            )
        except OcrError:
            raise
        except BaseException as exc:  # pragma: no cover - depends on MLX runtime
            if _is_memory_error(exc):
                raise OcrError("E3001", f"推論中にメモリが不足しました: {exc}") from exc
            raise


def _decode(processor: object, tokens: list[int]) -> str:
    try:
        return processor.decode(tokens, skip_special_tokens=True)  # type: ignore[attr-defined]
    except TypeError:
        return processor.tokenizer.decode(tokens, skip_special_tokens=True)  # type: ignore[attr-defined]
