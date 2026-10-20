"""Markdown post-processing: bbox extraction, figures, warnings (spec 10.3)."""

from __future__ import annotations

import html
import re
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable

from PIL import Image

from .errors import WarningMessage
from .version import FIGURE_PADDING

_BBOX_PAIR = re.compile(
    r"<bbox>\s*\[\s*\(\s*(-?\d+(?:\.\d+)?)\s*,\s*(-?\d+(?:\.\d+)?)\s*\)"
    r"\s*,\s*\(\s*(-?\d+(?:\.\d+)?)\s*,\s*(-?\d+(?:\.\d+)?)\s*\)\s*\]\s*</bbox>",
    re.IGNORECASE,
)
_FENCE_START = re.compile(r"^\s*```(?:markdown|md)?\s*\n", re.IGNORECASE)
_FENCE_END = re.compile(r"\n```\s*$")
_SCRIPT = re.compile(r"<script\b[^>]*>.*?</script\s*>", re.IGNORECASE | re.DOTALL)
_IFRAME = re.compile(r"<iframe\b[^>]*>.*?</iframe\s*>", re.IGNORECASE | re.DOTALL)
_DANGEROUS_ATTR = re.compile(
    r"\s+on[a-zA-Z]+\s*=\s*(?:\"[^\"]*\"|'[^']*'|[^\s>]+)", re.IGNORECASE
)
_JS_URL = re.compile(r"(?i)(href|src)\s*=\s*([\"'])\s*javascript:[^\"']*\2")
_HTML_TAG = re.compile(r"<[^>]+>")


@dataclass
class Figure:
    index: int
    bbox: list[float]          # normalized 0-1000
    bbox_px: list[int]         # pixels in the processed image
    path: str | None           # relative path (assets/fig-001.png) if saved
    absolute_path: str | None

    def to_dict(self) -> dict:
        return {
            "index": self.index,
            "bbox": self.bbox,
            "bbox_px": self.bbox_px,
            "path": self.path,
            "absolute_path": self.absolute_path,
        }


def strip_code_fences(text: str) -> str:
    text = text.strip()
    if text.startswith("```"):
        text = _FENCE_START.sub("", text, count=1)
        text = _FENCE_END.sub("", text, count=1)
    return text.strip()


def normalize_math_delimiters(text: str) -> str:
    text = text.replace(r"\[", "$$").replace(r"\]", "$$")
    text = text.replace(r"\(", "$").replace(r"\)", "$")
    return text


def sanitize_markdown(text: str) -> str:
    """Remove active content while keeping OCR-relevant HTML tables."""

    text = _SCRIPT.sub("", text)
    text = _IFRAME.sub("", text)
    text = _DANGEROUS_ATTR.sub("", text)
    text = _JS_URL.sub(lambda m: f'{m.group(1)}={m.group(2)}#{m.group(2)}', text)
    return text


def _clamp(value: float, low: float, high: float) -> float:
    return max(low, min(high, value))


def extract_figures(
    markdown: str,
    image: Image.Image,
    *,
    assets_dir: str | Path | None,
    asset_prefix: str = "assets",
) -> tuple[str, list[Figure]]:
    """Crop every bbox, save it, and replace the tag with an image link."""

    width, height = image.size
    figures: list[Figure] = []
    counter = 0

    def replace(match: re.Match[str]) -> str:
        nonlocal counter
        counter += 1
        x1, y1, x2, y2 = (float(match.group(i)) for i in range(1, 5))
        x1, x2 = sorted((x1, x2))
        y1, y2 = sorted((y1, y2))
        x1 = _clamp(x1, 0, 1000)
        x2 = _clamp(x2, 0, 1000)
        y1 = _clamp(y1, 0, 1000)
        y2 = _clamp(y2, 0, 1000)

        px = [
            int(round(x1 / 1000 * width)),
            int(round(y1 / 1000 * height)),
            int(round(x2 / 1000 * width)),
            int(round(y2 / 1000 * height)),
        ]
        px[2] = max(px[0] + 1, px[2])
        px[3] = max(px[1] + 1, px[3])

        pad_x = int(round(width * FIGURE_PADDING))
        pad_y = int(round(height * FIGURE_PADDING))
        left = max(0, px[0] - pad_x)
        top = max(0, px[1] - pad_y)
        right = min(width, px[2] + pad_x)
        bottom = min(height, px[3] + pad_y)

        relative: str | None = None
        absolute: str | None = None
        if assets_dir is not None and right > left and bottom > top:
            assets = Path(assets_dir)
            assets.mkdir(parents=True, exist_ok=True)
            name = f"fig-{counter:03d}.png"
            target = assets / name
            image.crop((left, top, right, bottom)).save(target, format="PNG")
            relative = f"{asset_prefix}/{name}"
            absolute = str(target.resolve())

        figures.append(
            Figure(
                index=counter,
                bbox=[x1, y1, x2, y2],
                bbox_px=px,
                path=relative,
                absolute_path=absolute,
            )
        )
        if relative is None:
            # Keep the content but avoid a broken image reference.
            return f"（図 {counter}）"
        return f"![図{counter}]({relative})"

    replaced = _BBOX_PAIR.sub(replace, markdown)
    # Standalone image links read better with surrounding blank lines.
    replaced = re.sub(r"(?<!\n)\n?!\[図(\d+)\]\(([^)]+)\)(?!\n)", r"\n\n![図\1](\2)\n\n", replaced)
    replaced = re.sub(r"\n{3,}", "\n\n", replaced)
    return replaced.strip(), figures


def to_plain_text(markdown: str) -> str:
    text = _BBOX_PAIR.sub("", markdown)
    text = re.sub(r"!\[[^\]]*\]\([^)]*\)", "", text)
    text = re.sub(r"\[([^\]]*)\]\([^)]*\)", r"\1", text)
    text = re.sub(r"<br\s*/?>", "\n", text, flags=re.IGNORECASE)
    text = re.sub(r"</(?:p|div|tr|h[1-6]|li)>", "\n", text, flags=re.IGNORECASE)
    text = _HTML_TAG.sub("", text)
    text = html.unescape(text)
    text = re.sub(r"^[ \t]*[-*+]\s+", "", text, flags=re.MULTILINE)
    text = re.sub(r"^#{1,6}\s*", "", text, flags=re.MULTILINE)
    text = re.sub(r"\n{3,}", "\n\n", text)
    return text.strip()


def detect_warnings(
    raw: str,
    *,
    output_tokens: int,
    max_new_tokens: int,
    eos_reached: bool,
    cancelled: bool,
) -> list[WarningMessage]:
    warnings: list[WarningMessage] = []

    if cancelled:
        warnings.append(WarningMessage("W4001", "生成を中断しました。部分結果を保存しています"))
    elif not raw.strip():
        warnings.append(WarningMessage("W4003", "出力が空でした。プリセットを変えて再実行してください"))
    elif not eos_reached and output_tokens >= max_new_tokens:
        warnings.append(
            WarningMessage("W4002", "出力がトークン上限に達しました。結果が途中の可能性があります")
        )

    # Character n-gram repetition (works for Japanese without word breaks).
    if len(raw) > 100:
        match = re.search(r"(.{12,}?)\1{3,}", raw, re.DOTALL)
        if match:
            unit = match.group(1)
            if unit.strip() and not set(unit).issubset(set("-|: \n\t")):
                warnings.append(WarningMessage("W4004", "同じ内容の繰り返しを検出しました"))

    return warnings
