"""Build warm Gruvbox variants of the repository's existing artwork."""

import sys
from pathlib import Path
from PIL import Image, ImageEnhance, ImageOps

source, destination = map(Path, sys.argv[1:])
destination.mkdir(parents=True, exist_ok=True)
for mode, images in {
    "dark": {"center": "fuji-pagoda-sunset.jpg", "portrait": "atake-sudden-shower.jpg"},
    "light": {"center": "blue-jays.png", "portrait": "kameido-plum-park.jpg"},
}.items():
    for slot, name in images.items():
        image = Image.open(source / name).convert("RGB")
        image = ImageEnhance.Color(image).enhance(0.65)
        warm = ImageOps.colorize(ImageOps.grayscale(image), "#282828", "#ebdbb2")
        image = Image.blend(image, warm, 0.45)
        image = ImageEnhance.Brightness(image).enhance(0.82 if mode == "dark" else 1.08)
        image.save(destination / f"{slot}-{mode}.jpg", quality=94)
