"""Sarashina2.2-OCR inference sidecar.

The package is executed as ``python -m ocr_engine`` and speaks JSON Lines over
stdin/stdout.  Nothing except protocol frames may be written to stdout; all
logging is redirected to stderr by :mod:`ocr_engine.__main__`.
"""

from .version import ENGINE_VERSION, PROTOCOL_VERSION

__all__ = ["ENGINE_VERSION", "PROTOCOL_VERSION"]
