"""Entry point for ``python -m ocr_engine`` (JSON Lines over stdio)."""

from __future__ import annotations

import argparse
import logging
import os
import sys
from pathlib import Path

from . import ENGINE_VERSION, PROTOCOL_VERSION
from .backends.mock import MockBackend
from .config import MANIFEST_PATH, default_model_dir, model_revision
from .engine import EngineService
from .manifest import verify_or_raise
from .rpc import RpcServer


def _redirect_stdout() -> "object":
    """Reserve fd 1 for protocol frames; everything else goes to stderr."""

    sys.stdout.flush()
    protocol_fd = os.dup(1)
    os.dup2(2, 1)
    sys.stdout = sys.stderr
    return os.fdopen(protocol_fd, "w", encoding="utf-8", buffering=1)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="ocr-engine")
    parser.add_argument("--model-dir", default=None, help="Sarashina MLX model directory")
    parser.add_argument(
        "--backend", choices=["mlx", "mock"], default="mlx", help="inference backend"
    )
    parser.add_argument("--revision", default=None, help="model revision label")
    parser.add_argument("--verify-model", action="store_true", help="verify SHA-256 before serving")
    parser.add_argument("--mock-delay", type=float, default=0.0, help=argparse.SUPPRESS)
    parser.add_argument("--log-level", default="INFO")
    parser.add_argument("--version", action="version", version=f"%(prog)s {ENGINE_VERSION}")
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    stdout = _redirect_stdout()
    logging.basicConfig(
        level=getattr(logging, args.log_level.upper(), logging.INFO),
        stream=sys.stderr,
        format="%(asctime)s %(levelname)s %(name)s: %(message)s",
    )
    logging.getLogger("ocr_engine").info(
        "starting engine=%s protocol=%d", ENGINE_VERSION, PROTOCOL_VERSION
    )

    model_dir = Path(args.model_dir).expanduser() if args.model_dir else default_model_dir()
    revision = args.revision or model_revision(model_dir)

    if args.backend == "mock":
        backend = MockBackend(delay=args.mock_delay)
        service = EngineService(backend, model_dir=None, model_revision="mock")
    else:
        from .backends.mlx import MlxBackend

        if args.verify_model and MANIFEST_PATH.is_file() and model_dir.is_dir():
            report = verify_or_raise(model_dir, MANIFEST_PATH)
            logging.getLogger("ocr_engine").info("model verified: %s", report)
        backend = MlxBackend(model_dir, revision=revision)
        service = EngineService(backend, model_dir=model_dir, model_revision=revision)

    try:
        sys.stdin.reconfigure(encoding="utf-8")  # type: ignore[union-attr]
    except Exception:
        pass

    RpcServer(service, sys.stdin, stdout).serve()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
