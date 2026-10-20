"""Paths, defaults, and dev/production model discovery."""

from __future__ import annotations

import os
from pathlib import Path

from .manifest import DEFAULT_REVISION

APP_NAME = "SarashinaOCR"
APP_SUPPORT = Path.home() / "Library" / "Application Support" / APP_NAME
MODELS_ROOT = APP_SUPPORT / "models" / "sarashina2.2-ocr"
DEFAULT_OUTPUT_ROOT = Path.home() / "Documents" / "Sarashina OCR Output"

REPO_ROOT = Path(__file__).resolve().parents[2]
DEV_MODEL_DIR = REPO_ROOT / "models" / "sarashina2.2-ocr-mlx-4bit"
MANIFEST_PATH = Path(__file__).resolve().parent / "resources" / "model_manifest.json"


def default_model_dir() -> Path:
    """Resolution order used by the dev CLI and by the packaged sidecar."""

    env = os.environ.get("SARASHINA_MODEL_DIR")
    if env:
        return Path(env).expanduser()

    current = MODELS_ROOT / "current"
    if current.exists():
        return current.resolve()
    if MODELS_ROOT.is_dir():
        candidates = sorted(
            (path for path in MODELS_ROOT.iterdir() if path.is_dir()),
            key=lambda path: path.stat().st_mtime,
            reverse=True,
        )
        if candidates:
            return candidates[0]

    return DEV_MODEL_DIR


def model_revision(model_dir: Path) -> str:
    revision_file = model_dir / ".revision"
    if revision_file.is_file():
        value = revision_file.read_text(encoding="utf-8").strip()
        if value:
            return value
    return DEFAULT_REVISION
