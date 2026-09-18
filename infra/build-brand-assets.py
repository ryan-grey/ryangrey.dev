#!/usr/bin/env python3
"""Export website assets from Ryan's approved cloud-g master without redrawing it.

Usage: python3 infra/build-brand-assets.py --source /path/to/grey-cloud-g-black.png
Requires Pillow. The source hash is pinned so rejected artwork cannot be exported.
"""
import argparse
import hashlib
from pathlib import Path
from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parent.parent
APPROVED_SHA256 = "873cae2675d4c7e7f50bd003615106fe7e76d20d3749b98cb85ab8e27459eee1"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", required=True, type=Path)
    parser.add_argument("--review-dir", type=Path)
    args = parser.parse_args()

    if hashlib.sha256(args.source.read_bytes()).hexdigest() != APPROVED_SHA256:
        raise ValueError("Source is not the approved cloud-g master")
    master = Image.open(args.source)
    if master.size != (1254, 1254) or master.mode != "RGB":
        raise ValueError("Expected the approved 1254px RGB cloud-g master")
    source = Image.frombytes("RGB", master.size, master.tobytes())

    avatar = source.resize((512, 512), Image.Resampling.LANCZOS)
    avatar.save(ROOT / "rg-avatar-v4.png", optimize=True)
    avatar.save(ROOT / "rg-avatar.png", optimize=True)

    icon = source.resize((256, 256), Image.Resampling.LANCZOS)
    icon.save(ROOT / "favicon-v5.png", optimize=True)
    icon.save(ROOT / "favicon-v5.ico", sizes=[(16, 16), (32, 32), (48, 48),
                                               (64, 64), (128, 128), (256, 256)])
    (ROOT / "favicon.ico").write_bytes((ROOT / "favicon-v5.ico").read_bytes())

    touch = source.resize((180, 180), Image.Resampling.LANCZOS)
    touch.save(ROOT / "apple-touch-icon-v5.png", optimize=True)
    touch.save(ROOT / "apple-touch-icon.png", optimize=True)

    # Keep the existing social-card typography and certification badge; replace
    # only the superseded mark with the approved master, resized without cropping.
    previous = Image.open(ROOT / "og-card-v4.png").convert("RGB")
    card = previous.copy()
    ImageDraw.Draw(card).rectangle((215, 95, 489, 359), fill=previous.getpixel((0, 0)))
    card.paste(source.resize((260, 260), Image.Resampling.LANCZOS), (225, 95))
    card.save(ROOT / "og-card-v5.png", optimize=True)
    card.save(ROOT / "og-card.png", optimize=True)

    if args.review_dir:
        args.review_dir.mkdir(parents=True, exist_ok=True)
        board = Image.new("RGB", (1000, 650), "#ffffff")
        draw = ImageDraw.Draw(board)
        draw.rectangle((500, 0, 999, 649), fill="#0d1117")
        for column, foreground in ((0, "#1f2328"), (500, "#f0f6fc")):
            draw.text((column + 20, 15), "Approved mark: hero 150px / error 96px; favicon 16 / 32 / 48 / 64px", fill=foreground)
            for x, size in ((20, 150), (195, 96)):
                sample = source.resize((size, size), Image.Resampling.LANCZOS)
                board.paste(sample, (column + x, 55))
            for x, size in ((20, 16), (65, 32), (125, 48), (205, 64)):
                sample = source.resize((size, size), Image.Resampling.LANCZOS)
                board.paste(sample, (column + x, 245))
                draw.text((column + x, 320), str(size), fill=foreground)
            zoom = source.resize((16, 16), Image.Resampling.LANCZOS).resize((192, 192), Image.Resampling.NEAREST)
            board.paste(zoom, (column + 20, 370))
            board.paste(touch, (column + 255, 370))
        board.save(args.review_dir / "brand-sizes.png")
    print("Exported approved cloud-g website assets")


if __name__ == "__main__":
    main()
