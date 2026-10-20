from __future__ import annotations

from PIL import Image

from ocr_engine.postprocess import (
    detect_warnings,
    extract_figures,
    normalize_math_delimiters,
    sanitize_markdown,
    strip_code_fences,
    to_plain_text,
)


def test_strip_fences() -> None:
    assert strip_code_fences("```markdown\n# A\n```") == "# A"
    assert strip_code_fences("```\n# A\n```") == "# A"
    assert strip_code_fences("# A") == "# A"


def test_math_normalization() -> None:
    assert normalize_math_delimiters(r"\(x^2\)") == "$x^2$"
    assert normalize_math_delimiters(r"\[x^2\]") == "$$x^2$$"


def test_sanitize_removes_active_content() -> None:
    text = '<script>alert(1)</script>\n<img src="x" onerror="alert(2)">\n<table><tr><td>A</td></tr></table>'
    sanitized = sanitize_markdown(text)
    assert "script" not in sanitized.lower()
    assert "onerror" not in sanitized
    assert "<table>" in sanitized


def test_extract_figures(tmp_path) -> None:
    image = Image.new("RGB", (1000, 2000), "white")
    markdown = "前文\n\n<bbox>[(120, 340), (480, 620)]</bbox>\n\n後文"
    replaced, figures = extract_figures(markdown, image, assets_dir=tmp_path / "assets")
    assert len(figures) == 1
    assert figures[0].bbox == [120, 340, 480, 620]
    assert figures[0].bbox_px == [120, 680, 480, 1240]
    assert "![図1](assets/fig-001.png)" in replaced
    assert (tmp_path / "assets" / "fig-001.png").is_file()


def test_extract_figures_clamps_out_of_range(tmp_path) -> None:
    image = Image.new("RGB", (1000, 1000), "white")
    _, figures = extract_figures(
        "<bbox>[(-20, -10), (1200, 900)]</bbox>", image, assets_dir=tmp_path
    )
    assert figures[0].bbox == [0, 0, 1000, 900]
    assert figures[0].bbox_px == [0, 0, 1000, 900]


def test_plain_text_removes_bbox_and_markup() -> None:
    markdown = "# 見出し\n\n<bbox>[(1, 2), (3, 4)]</bbox>\n\n![図1](assets/fig-001.png)\n\n本文"
    text = to_plain_text(markdown)
    assert "bbox" not in text
    assert "![" not in text
    assert text.startswith("見出し")


def test_warning_for_truncation() -> None:
    warnings = detect_warnings(
        "text", output_tokens=6000, max_new_tokens=6000, eos_reached=False, cancelled=False
    )
    assert any(w.code == "W4002" for w in warnings)


def test_warning_for_repetition() -> None:
    repeated = "同じ文章が繰り返されています。" * 12
    warnings = detect_warnings(
        repeated, output_tokens=100, max_new_tokens=6000, eos_reached=True, cancelled=False
    )
    assert any(w.code == "W4004" for w in warnings)
