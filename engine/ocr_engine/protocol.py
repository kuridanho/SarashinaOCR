"""JSON Lines protocol frame helpers (spec section 8.4)."""

from __future__ import annotations

import json
from typing import Any

from .errors import OcrError
from .version import PROTOCOL_VERSION

METHODS = {"hello", "load", "unload", "ocr", "cancel", "ping", "shutdown"}


def encode_frame(frame: dict[str, Any]) -> str:
    return json.dumps(frame, ensure_ascii=False, separators=(",", ":"))


def event_frame(request_id: str, event: str, data: dict[str, Any]) -> dict[str, Any]:
    return {"v": PROTOCOL_VERSION, "id": request_id, "event": event, "data": data}


def error_frame(request_id: str, error: OcrError) -> dict[str, Any]:
    return event_frame(request_id, "error", error.to_dict())


def parse_frame(line: str) -> tuple[str, dict[str, Any]]:
    """Parse one request line, returning ``(id, message)``.

    Raises :class:`OcrError` with code ``E5001`` for malformed input so the
    caller can report a protocol error without crashing the engine.
    """

    try:
        message = json.loads(line)
    except json.JSONDecodeError as exc:
        raise OcrError("E5001", f"JSON を解析できません: {exc}") from exc
    if not isinstance(message, dict):
        raise OcrError("E5001", "リクエストは JSON オブジェクトである必要があります")
    request_id = message.get("id")
    if not isinstance(request_id, str) or not request_id:
        raise OcrError("E5001", "リクエストに id がありません")
    method = message.get("method")
    if method not in METHODS:
        raise OcrError("E5002", f"未知のメソッドです: {method!r}")
    version = message.get("v", PROTOCOL_VERSION)
    if version != PROTOCOL_VERSION:
        raise OcrError("E5003", f"未対応のプロトコル版です: {version!r}")
    return request_id, message
