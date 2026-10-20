"""Model manifest loading and SHA-256 verification (spec section 8.6)."""

from __future__ import annotations

import hashlib
import json
from dataclasses import dataclass
from pathlib import Path

from .errors import OcrError

MANIFEST_FILENAME = "model_manifest.json"

# Pinned source revision of tokimoa/sarashina2.2-ocr-mlx-4bit.
DEFAULT_REVISION = "6585fb9ed1fbb263eb39c57a2b45c5c21a8aadff"


@dataclass
class Manifest:
    revision: str
    total_bytes: int
    files: dict[str, dict]

    @classmethod
    def load(cls, path: str | Path) -> "Manifest":
        try:
            data = json.loads(Path(path).read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as exc:
            raise OcrError("E1002", f"マニフェストを読み込めません: {exc}") from exc
        return cls(
            revision=data.get("revision", DEFAULT_REVISION),
            total_bytes=int(data.get("total_bytes", 0)),
            files={item["path"]: item for item in data.get("files", [])},
        )


def sha256_file(path: Path, chunk_size: int = 8 * 1024 * 1024) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        while chunk := handle.read(chunk_size):
            digest.update(chunk)
    return digest.hexdigest()


def verify_model_dir(model_dir: str | Path, manifest_path: str | Path) -> dict:
    """Verify sizes and hashes. Returns a report instead of raising per-file."""

    model_dir = Path(model_dir)
    manifest = Manifest.load(manifest_path)
    missing: list[str] = []
    mismatched: list[str] = []
    for relative, entry in manifest.files.items():
        target = model_dir / relative
        if not target.is_file():
            missing.append(relative)
            continue
        expected_size = entry.get("size")
        if expected_size is not None and target.stat().st_size != int(expected_size):
            mismatched.append(relative)
            continue
        expected_hash = entry.get("sha256")
        if expected_hash and sha256_file(target) != expected_hash:
            mismatched.append(relative)
    return {
        "ok": not missing and not mismatched,
        "revision": manifest.revision,
        "missing": missing,
        "mismatched": mismatched,
        "file_count": len(manifest.files),
        "total_bytes": manifest.total_bytes,
    }


def verify_or_raise(model_dir: str | Path, manifest_path: str | Path) -> dict:
    report = verify_model_dir(model_dir, manifest_path)
    if not report["ok"]:
        detail = ", ".join(report["missing"] + report["mismatched"][:5])
        raise OcrError("E1002", f"モデルの検証に失敗しました: {detail}")
    return report
