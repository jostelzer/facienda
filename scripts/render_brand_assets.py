#!/usr/bin/env python3
"""Render the selected transparent Facienda mark into native icon assets.

Run from any directory with Python and Pillow installed. The source mark is
kept separately from the generated app, appearance, and menu-bar assets.
"""

import json
from pathlib import Path

from PIL import Image, ImageDraw


ROOT = Path(__file__).resolve().parents[1]
ASSETS = ROOT / "Assets"
CATALOG = ASSETS / "Assets.xcassets"
PAPER = (249, 248, 245, 255)
INK = (41, 45, 41, 255)
BLUE = (113, 174, 255, 255)
SCALE = 4


def place_mark(mark: Image.Image, size: int, height: int) -> Image.Image:
    """Center the complete silhouette on a transparent square canvas."""
    width = round(height * mark.width / mark.height)
    resized = mark.resize((width, height), Image.Resampling.LANCZOS)
    canvas = Image.new("RGBA", (size, size))
    canvas.alpha_composite(resized, ((size - width) // 2, (size - height) // 2))
    return canvas


def recolor(mark: Image.Image, *, template: bool = False) -> Image.Image:
    if template:
        result = Image.new("RGBA", mark.size)
        result.putalpha(mark.getchannel("A"))
        return result
    result = mark.copy()
    pixels = result.load()
    for y in range(result.height):
        for x in range(result.width):
            red, _, blue, alpha = pixels[x, y]
            color = BLUE if blue > red + 30 else PAPER
            pixels[x, y] = (*color[:3], alpha)
    return result


def save_scaled(image: Image.Image, destination: Path, size: int) -> None:
    image.resize((size, size), Image.Resampling.LANCZOS).save(destination)


def main() -> None:
    mark = Image.open(ASSETS / "Brand/facienda-fold-mark.png").convert("RGBA")
    resolution = 1024 * SCALE

    # Conventional macOS icon margins; only the glyph is used inside the app.
    icon = Image.new("RGBA", (resolution, resolution))
    drawing = ImageDraw.Draw(icon)
    drawing.rounded_rectangle(
        (100 * SCALE, 100 * SCALE, 924 * SCALE, 924 * SCALE),
        radius=184 * SCALE,
        fill=PAPER,
    )
    icon.alpha_composite(place_mark(mark, resolution, 600 * SCALE))
    save_scaled(icon, ASSETS / "Brand/facienda-fold-app-icon.png", 1024)
    appicon = CATALOG / "AppIcon.appiconset"
    for entry in json.loads((appicon / "Contents.json").read_text())["images"]:
        size = int(entry["size"].split("x")[0]) * int(entry["scale"][0])
        save_scaled(icon, appicon / entry["filename"], size)

    brand = CATALOG / "BrandIcon.imageset"
    save_scaled(place_mark(mark, resolution, 880 * SCALE), brand / "brand.png", 512)
    save_scaled(
        place_mark(recolor(mark), resolution, 880 * SCALE),
        brand / "brand-dark.png",
        512,
    )

    # Template rendering lets macOS choose a legible menu-bar foreground color.
    menu = CATALOG / "MenuBarIcon.imageset"
    monochrome = recolor(mark, template=True)
    for scale in (1, 2):
        name = "menu-bar.png" if scale == 1 else f"menu-bar@{scale}x.png"
        save_scaled(place_mark(monochrome, 216, 204), menu / name, 18 * scale)

    print("Rendered macOS, light/dark brand, and menu-bar icons.")


if __name__ == "__main__":
    main()
