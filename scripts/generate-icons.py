#!/usr/bin/env python3
"""Regenerate the Vidyut desktop icons from the official app mark.

Source of truth: app/assets/icon/icon-foreground.png (the same artwork the
Android launcher uses). The previous set was a lightning-bolt placeholder that
never matched the brand.

App/window icons are the bare mark, cropped to its alpha bounds and centred.
Tray icons keep the mark and add a state-coloured badge, because the mark is a
full-colour illustration and cannot be tinted to signal state the way the old
placeholder could.

State colours come from design/tokens.css.
"""

from pathlib import Path

from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parents[1]
MARK = ROOT / "app/assets/icon/icon-foreground.png"
ICONS = ROOT / "src-tauri/icons"

# design/tokens.css
STATE = {
    "ready": "#2D8A4A",  # --success
    "attention": "#A05A00",  # --warning
    "down": "#B3283E",  # --error
    "stopped": "#856674",  # --muted
}

APP_SIZES = {
    "icon.png": 512,
    "128x128@2x.png": 256,
    "128x128.png": 128,
    "32x32.png": 32,
}

TRAY_SIZES = {
    "ready.png": 512,
    "attention.png": 512,
    "down.png": 512,
    "stopped.png": 512,
    "ready-32.png": 32,
    "attention-32.png": 32,
    "down-32.png": 32,
    "stopped-32.png": 32,
}


def mark() -> Image.Image:
    """The official mark, cropped to its alpha bounds."""
    return Image.open(MARK).convert("RGBA").crop(Image.open(MARK).convert("RGBA").getbbox())


def place(src: Image.Image, size: int, fill: float) -> Image.Image:
    """Centre the mark on a transparent square, scaled to `fill` of the width."""
    target = int(size * fill)
    scaled = src.resize((target, max(1, round(target * src.height / src.width))), Image.LANCZOS)
    canvas = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    canvas.alpha_composite(scaled, ((size - target) // 2, (size - scaled.height) // 2))
    return canvas


def badge(canvas: Image.Image, colour: str) -> Image.Image:
    """A state dot in the top-right, ringed so it reads on any background."""
    size = canvas.width
    d = ImageDraw.Draw(canvas)
    r = max(2, round(size * 0.105))
    cx, cy = size - r - max(1, round(size * 0.02)), r + max(1, round(size * 0.02))
    ring = max(1, round(size * 0.03))
    d.ellipse([cx - r - ring, cy - r - ring, cx + r + ring, cy + r + ring], fill=(255, 255, 255, 235))
    d.ellipse([cx - r, cy - r, cx + r, cy + r], fill=colour)
    return canvas


def main() -> None:
    m = mark()
    for name, size in APP_SIZES.items():
        # Small sizes need a fuller mark to survive downscaling.
        fill = 0.94 if size <= 32 else 0.84
        place(m, size, fill).save(ICONS / name)
        print(f"app   {name:18s} {size}x{size}")

    for name, size in TRAY_SIZES.items():
        state = name.split("-")[0].removesuffix(".png")
        fill = 0.90 if size <= 32 else 0.74
        badge(place(m, size, fill), STATE[state]).save(ICONS / "tray" / name)
        print(f"tray  {name:18s} {size}x{size} {STATE[state]}")


if __name__ == "__main__":
    main()
