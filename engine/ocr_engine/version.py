from __future__ import annotations

ENGINE_VERSION = "1.0.0"
PROTOCOL_VERSION = 1

# Generation defaults from the model card / specification (section 3.3).
DEFAULT_MAX_NEW_TOKENS = 6000
MAX_NEW_TOKENS_LIMIT = 8192
REPETITION_PENALTY = 1.2
EOS_TOKEN_ID = 2

# Resolution presets (section 10.1).
PRESETS: dict[str, int] = {
    "high": 2_458_624,
    "standard": 1_324_960,
    "fast": 705_600,
}
DEFAULT_PRESET = "high"

MIN_PIXELS = 3_136
PATCH_FACTOR = 28
FIGURE_PADDING = 0.015


def preset_max_pixels(name: str | None) -> int:
    if name is None:
        return PRESETS[DEFAULT_PRESET]
    try:
        return PRESETS[name]
    except KeyError as exc:
        raise ValueError(f"unknown preset: {name!r}") from exc
