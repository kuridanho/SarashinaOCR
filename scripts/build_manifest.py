#!/usr/bin/env python3
"""Generate the bundled model manifest from a downloaded model directory."""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        while chunk := handle.read(8 * 1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest()


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--model-dir", required=True)
    parser.add_argument("--revision", required=True)
    parser.add_argument("--out", required=True)
    parser.add_argument("--repo", default="tokimoa/sarashina2.2-ocr-mlx-4bit")
    args = parser.parse_args()

    model_dir = Path(args.model_dir)
    files = []
    total = 0
    for path in sorted(model_dir.rglob("*")):
        if not path.is_file():
            continue
        relative = path.relative_to(model_dir)
        if any(part.startswith(".") or part == "__pycache__" for part in relative.parts):
            continue
        if path.name == ".DS_Store":
            continue
        relative_path = relative.as_posix()
        size = path.stat().st_size
        total += size
        files.append(
            {
                "path": relative_path,
                "size": size,
                "sha256": sha256_file(path),
                "url": f"https://huggingface.co/{args.repo}/resolve/{args.revision}/{relative_path}",
            }
        )
        print(f"{relative_path}\t{size}")

    manifest = {
        "name": "sarashina2.2-ocr-mlx-4bit",
        "repo": args.repo,
        "revision": args.revision,
        "total_bytes": total,
        "license": "MIT",
        "quantization": {"bits": 4, "group_size": 64, "mode": "affine"},
        "files": files,
    }
    out = Path(args.out)
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(f"wrote {out} ({len(files)} files, {total / 1024**3:.2f} GiB)")


if __name__ == "__main__":
    main()
