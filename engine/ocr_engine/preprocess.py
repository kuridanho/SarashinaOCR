"""Image loading and smart resizing (spec section 10.1)."""

from __future__ import annotations

import math
from dataclasses import dataclass
from pathlib import Path

from PIL import Image, ImageOps, UnidentifiedImageError

from .errors import OcrError
from .version import MIN_PIXELS, PATCH_FACTOR


@dataclass(frozen=True)
class ImageInfo:
    width: int
    height: int
    original_width: int
    original_height: int
    visual_tokens: int

    def to_dict(self) -> dict:
        return {
            "width": self.width,
            "height": self.height,
            "original_width": self.original_width,
            "original_height": self.original_height,
            "visual_tokens": self.visual_tokens,
        }


def load_image(path: str | Path) -> Image.Image:
    """Load an image as sRGB RGB, applying EXIF orientation."""

    try:
        with Image.open(path) as image:
            image = ImageOps.exif_transpose(image)
            return image.convert("RGB")
    except (UnidentifiedImageError, OSError, ValueError) as exc:
        raise OcrError("E2001", f"画像を読み込めません: {exc}") from exc


def smart_resize(
    height: int,
    width: int,
    *,
    max_pixels: int,
    min_pixels: int = MIN_PIXELS,
    factor: int = PATCH_FACTOR,
    allow_upscale: bool = False,
) -> tuple[int, int]:
    """Snap the long edge to a multiple of ``factor`` and cap at ``max_pixels``.

    ``allow_upscale=False`` implements the specification's rule: images smaller
    than ``min_pixels`` are passed through instead of being enlarged, avoiding
    fabricated detail.
    """

    if height <= 0 or width <= 0:
        raise OcrError("E2002", "画像のサイズが不正です")

    h_bar = max(factor, round(height / factor) * factor)
    w_bar = max(factor, round(width / factor) * factor)

    if h_bar * w_bar > max_pixels:
        beta = height / width
        h_bar = max(factor, math.floor(math.sqrt(max_pixels * beta) / factor) * factor)
        w_bar = max(factor, math.floor(math.sqrt(max_pixels / beta) / factor) * factor)
    elif h_bar * w_bar < min_pixels and allow_upscale:
        beta = height / width
        h_bar = max(factor, math.ceil(math.sqrt(min_pixels * beta) / factor) * factor)
        w_bar = max(factor, math.ceil(math.sqrt(min_pixels / beta) / factor) * factor)

    return h_bar, w_bar


def prepare_image(
    path: str | Path, *, max_pixels: int, allow_upscale: bool = False
) -> tuple[Image.Image, ImageInfo]:
    image = load_image(path)
    original_width, original_height = image.size
    width = original_width
    height = original_height

    target_h, target_w = smart_resize(
        height, width, max_pixels=max_pixels, allow_upscale=allow_upscale
    )
    if (target_w, target_h) != (width, height):
        image = image.resize((target_w, target_h), Image.Resampling.LANCZOS)
        width, height = target_w, target_h

    visual_tokens = (width // PATCH_FACTOR) * (height // PATCH_FACTOR) // 4
    return image, ImageInfo(
        width=width,
        height=height,
        original_width=original_width,
        original_height=original_height,
        visual_tokens=visual_tokens,
    )
