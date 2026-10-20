"""JSON Lines RPC loop.

The reader thread answers ``ping``/``cancel`` immediately so that a long OCR
request never blocks cancellation.  ``load``/``unload``/``ocr`` are serialized
on a single worker thread because the engine owns exactly one model instance.
"""

from __future__ import annotations

import json
import logging
import queue
import threading
from typing import Any, TextIO

from .engine import EngineService
from .errors import OcrError
from .protocol import encode_frame, error_frame, event_frame, parse_frame

log = logging.getLogger(__name__)


class RpcServer:
    def __init__(self, service: EngineService, stdin: TextIO, stdout: TextIO):
        self.service = service
        self.stdin = stdin
        self.stdout = stdout
        self._queue: queue.Queue[tuple[str, str, dict[str, Any]] | None] = queue.Queue()
        self._write_lock = threading.Lock()
        self._current_id: str | None = None
        self._current_lock = threading.Lock()
        self._queued_ids: set[str] = set()
        self._pending_cancel: set[str] = set()
        self._stopping = threading.Event()

    # ------------------------------------------------------------------ output
    def send(self, frame: dict[str, Any]) -> None:
        line = encode_frame(frame)
        with self._write_lock:
            self.stdout.write(line + "\n")
            self.stdout.flush()

    def emit(self, request_id: str, event: str, data: dict[str, Any]) -> None:
        self.send(event_frame(request_id, event, data))

    # -------------------------------------------------------------------- loop
    def serve(self) -> None:
        worker = threading.Thread(target=self._work_loop, name="ocr-worker", daemon=True)
        worker.start()

        for line in self.stdin:
            if not line.strip():
                continue
            try:
                request_id, message = parse_frame(line)
            except OcrError as exc:
                self.send(error_frame(_raw_id(line), exc))
                continue

            method = message["method"]
            params = message.get("params") or {}
            if not isinstance(params, dict):
                self.send(error_frame(request_id, OcrError("E5001", "params はオブジェクトで指定してください")))
                continue

            if method == "ping":
                self.send(event_frame(request_id, "done", {"pong": True, "state": self.service.state}))
            elif method == "cancel":
                target = params.get("target")
                matched = False
                with self._current_lock:
                    active = self._current_id
                    if target is None:
                        matched = active is not None
                        if matched:
                            self.service.cancel()
                    elif target == active:
                        matched = True
                        self.service.cancel()
                    elif target in self._queued_ids:
                        # Cancel arrived before the request left the queue.
                        matched = True
                        self._pending_cancel.add(target)
                self.send(
                    event_frame(
                        request_id,
                        "done",
                        {"cancelled": matched, "target": active or target},
                    )
                )
            elif method == "shutdown":
                self.service.cancel()
                self.send(event_frame(request_id, "done", {"bye": True}))
                self._stopping.set()
                break
            elif method == "hello":
                self.send(event_frame(request_id, "done", self.service.hello()))
            else:
                with self._current_lock:
                    self._queued_ids.add(request_id)
                self._queue.put((request_id, method, params))

        self._queue.put(None)
        worker.join(timeout=30)

    def _work_loop(self) -> None:
        while not self._stopping.is_set():
            item = self._queue.get()
            if item is None:
                return
            request_id, method, params = item
            with self._current_lock:
                self._queued_ids.discard(request_id)
                self._current_id = request_id

            def emit(event: str, data: dict[str, Any], rid: str = request_id) -> None:
                self.emit(rid, event, data)

            with self._current_lock:
                pre_cancelled = request_id in self._pending_cancel
                self._pending_cancel.discard(request_id)
            if pre_cancelled and method == "ocr":
                self.send(event_frame(request_id, "done", _cancelled_payload()))
                with self._current_lock:
                    self._current_id = None
                continue

            try:
                if method == "load":
                    data = self.service.load(emit)
                elif method == "unload":
                    data = self.service.unload()
                elif method == "ocr":
                    data = self.service.ocr(params, emit)
                else:
                    raise OcrError("E5002", f"未対応のメソッドです: {method}")
                self.send(event_frame(request_id, "done", data))
            except OcrError as exc:
                log.warning("%s failed: %s (%s)", method, exc.message, exc.code)
                self.send(error_frame(request_id, exc))
            except Exception as exc:  # pragma: no cover - defensive
                log.exception("%s crashed", method)
                self.send(
                    error_frame(
                        request_id,
                        OcrError("E3002", f"エンジン内部エラー: {exc}", recoverable=True),
                    )
                )
            finally:
                with self._current_lock:
                    self._current_id = None
                # Keep memory bounded between requests.
                try:
                    import mlx.core as mx

                    mx.clear_cache()
                except Exception:
                    pass


def _cancelled_payload() -> dict[str, Any]:
    return {
        "raw": "",
        "markdown": "",
        "text": "",
        "figures": [],
        "warnings": [{"code": "W4001", "message": "生成を中断しました。部分結果を保存しています"}],
        "cancelled": True,
        "image": {},
        "stats": {
            "prompt_tokens": 0,
            "output_tokens": 0,
            "seconds": 0.0,
            "prefill_seconds": 0.0,
            "decode_seconds": 0.0,
            "tok_per_s": 0.0,
            "peak_memory_mb": None,
            "truncated": False,
            "eos_reached": False,
        },
    }


def _raw_id(line: str) -> str:
    try:
        value = json.loads(line)
        if isinstance(value, dict) and isinstance(value.get("id"), str):
            return value["id"]
    except Exception:
        pass
    return "unknown"
