from __future__ import annotations

from dataclasses import dataclass

# Error codes from spec section 8.4.
ERROR_MESSAGES = {
    "E1001": ("モデルが見つかりません", False),
    "E1002": ("モデルのチェックサムが一致しません", False),
    "E2001": ("画像を読み込めませんでした", False),
    "E2002": ("画像の解像度が範囲外です", True),
    "E3001": ("メモリが不足しています", True),
    "E3002": ("推論エンジンがクラッシュしました", True),
    "E4001": ("生成がタイムアウトしました", True),
    "E4002": ("出力トークンの上限に達しました", True),
}


class OcrError(Exception):
    """An error that can be reported to the host with a stable code."""

    def __init__(self, code: str, message: str | None = None, recoverable: bool | None = None):
        default_message, default_recoverable = ERROR_MESSAGES.get(
            code, ("不明なエラー", True)
        )
        self.code = code
        self.message = message or default_message
        self.recoverable = default_recoverable if recoverable is None else recoverable
        super().__init__(self.message)

    def to_dict(self) -> dict:
        return {
            "code": self.code,
            "message": self.message,
            "recoverable": self.recoverable,
        }


@dataclass
class WarningMessage:
    code: str
    message: str

    def to_dict(self) -> dict:
        return {"code": self.code, "message": self.message}
