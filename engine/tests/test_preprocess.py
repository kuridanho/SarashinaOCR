from __future__ import annotations

import math

import pytest

from ocr_engine.preprocess import smart_resize


def test_smart_resize_caps_pixels_and_aligns() -> None:
    width, height = smart_resize(3024, 4032, max_pixels=2_458_624)
    assert width % 28 == 0
    assert height % 28 == 0
    assert width * height <= 2_458_624
    # Aspect ratio is preserved within one patch.
    assert abs((width / height) - (3024 / 4032)) < 0.02


def test_small_image_is_not_upscaled() -> None:
    assert smart_resize(200, 300, max_pixels=2_458_624) == (196, 308)


@pytest.mark.parametrize("preset_max", [2_458_624, 1_324_960, 705_600])
def test_visual_tokens_within_limit(preset_max: int) -> None:
    width, height = smart_resize(2000, 3000, max_pixels=preset_max)
    tokens = (width // 28) * (height // 28) // 4
    assert tokens <= math.ceil(preset_max / 784)
