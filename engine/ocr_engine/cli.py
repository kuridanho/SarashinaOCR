"""Command line OCR used by developers and smoke tests (spec section 16, M1)."""

from __future__ import annotations

import argparse
import json
import logging
import sys
from pathlib import Path

from .backends.mock import MockBackend
from .config import default_model_dir, model_revision
from .engine import EngineService


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="sarashina-ocr")
    parser.add_argument("--image", action="append", required=True, help="input image (repeatable)")
    parser.add_argument("--out", required=True, help="output directory")
    parser.add_argument("--preset", choices=["high", "standard", "fast"], default="high")
    parser.add_argument("--max-new-tokens", type=int, default=6000)
    parser.add_argument("--max-pixels", type=int, default=None)
    parser.add_argument("--model-dir", default=None)
    parser.add_argument("--backend", choices=["mlx", "mock"], default="mlx")
    parser.add_argument("--stream", action="store_true", help="stream tokens to stderr")
    parser.add_argument("--quiet", action="store_true")
    parser.add_argument("--log-level", default="WARNING")
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    logging.basicConfig(
        level=getattr(logging, args.log_level.upper(), logging.WARNING),
        stream=sys.stderr,
        format="%(levelname)s %(name)s: %(message)s",
    )

    model_dir = Path(args.model_dir).expanduser() if args.model_dir else default_model_dir()
    if args.backend == "mock":
        backend = MockBackend()
        service = EngineService(backend, model_revision="mock")
    else:
        from .backends.mlx import MlxBackend

        backend = MlxBackend(model_dir, revision=model_revision(model_dir))
        service = EngineService(backend, model_dir=model_dir, model_revision=model_revision(model_dir))

    out_root = Path(args.out).expanduser()
    out_root.mkdir(parents=True, exist_ok=True)

    def emit(event: str, data: dict) -> None:
        if event == "token":
            if args.stream:
                sys.stderr.write(data.get("text", ""))
                sys.stderr.flush()
            return
        if args.quiet:
            return
        if event == "stage":
            stage = data.get("stage")
            if stage == "preprocess_done":
                print(
                    f"[preprocess] {data['width']}x{data['height']} "
                    f"({data['visual_tokens']} visual tokens)",
                    file=sys.stderr,
                )
            elif stage == "prefill":
                print(f"[prefill] {data.get('prompt_tokens')} prompt tokens", file=sys.stderr)
            elif stage == "model_load":
                print(f"[load] {data.get('progress', 0):.0%}", file=sys.stderr)
            else:
                print(f"[{stage}]", file=sys.stderr)
        elif event == "warning":
            print(f"[warning] {data.get('message')}", file=sys.stderr)

    if hasattr(service.backend, "load"):
        service.load(emit)
    if args.stream:
        sys.stderr.write("\n")

    results = []
    failures = 0
    for index, image_arg in enumerate(args.image, start=1):
        image_path = Path(image_arg).expanduser()
        page_dir = out_root if len(args.image) == 1 else out_root / f"page-{index:03d}"
        page_dir.mkdir(parents=True, exist_ok=True)
        assets = page_dir / "assets"
        try:
            data = service.ocr(
                {
                    "image": str(image_path),
                    "preset": args.preset,
                    "max_new_tokens": args.max_new_tokens,
                    "max_pixels": args.max_pixels,
                    "figures_dir": str(assets),
                },
                emit,
            )
        except Exception as exc:
            failures += 1
            print(f"error: {image_path}: {exc}", file=sys.stderr)
            continue

        (page_dir / "result.md").write_text(data["markdown"], encoding="utf-8")
        (page_dir / "raw.md").write_text(data["raw"], encoding="utf-8")
        (page_dir / "plain.txt").write_text(data["text"], encoding="utf-8")
        (page_dir / "result.json").write_text(
            json.dumps(data, ensure_ascii=False, indent=2), encoding="utf-8"
        )
        results.append(
            {
                "image": str(image_path),
                "out": str(page_dir),
                "chars": len(data["markdown"]),
                "figures": len(data["figures"]),
                "stats": data["stats"],
                "warnings": data["warnings"],
            }
        )
        if not args.quiet:
            stats = data["stats"]
            print(
                f"[done] {image_path.name}: {stats['output_tokens']} tokens, "
                f"{stats['tok_per_s']} tok/s, {stats['seconds']}s -> {page_dir}",
                file=sys.stderr,
            )

    print(json.dumps({"results": results, "failures": failures}, ensure_ascii=False, indent=2))
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
