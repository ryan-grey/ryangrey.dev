#!/usr/bin/env python3
"""Export website assets from the selected transparent master without redrawing it.

Usage: python3 infra/build-brand-assets.py --source /path/to/rg-primary-1254.png
Requires Pillow. The source is an explicit input; old brand generators are not used.
"""
import argparse
from pathlib import Path
from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parent.parent


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', required=True, type=Path)
    parser.add_argument('--review-dir', type=Path)
    args = parser.parse_args()
    master = Image.open(args.source)
    if master.size != (1254, 1254) or master.mode != 'RGBA':
        raise ValueError('Expected the selected 1254px RGBA primary master')
    # Fresh images drop source metadata while retaining RGBA pixels.
    source = Image.frombytes('RGBA', master.size, master.tobytes())
    avatar = source.resize((600, 600), Image.Resampling.LANCZOS)
    avatar.save(ROOT / 'rg-avatar-v3.png', optimize=True)
    avatar.save(ROOT / 'rg-avatar.png', optimize=True)
    # Tight square framing for small uses; includes both letters and the cloud.
    small = source.crop((215, 245, 1040, 1070))
    icon = small.resize((256, 256), Image.Resampling.LANCZOS)
    icon.save(ROOT / 'favicon-v4.png', optimize=True)
    icon.save(ROOT / 'favicon-v4.ico', sizes=[(16,16),(32,32),(48,48),(64,64),(256,256)])
    (ROOT / 'favicon.ico').write_bytes((ROOT / 'favicon-v4.ico').read_bytes())
    # Apple touch icons are opaque tiles to avoid OS-dependent alpha flattening.
    touch = Image.new('RGBA', (180, 180), '#0d1117')
    touch.alpha_composite(source.resize((180, 180), Image.Resampling.LANCZOS))
    touch.convert('RGB').save(ROOT / 'apple-touch-icon-v4.png', optimize=True)
    (ROOT / 'apple-touch-icon.png').write_bytes((ROOT / 'apple-touch-icon-v4.png').read_bytes())
    # Preserve the social card's existing typography and credential badge exactly.
    previous = Image.open(ROOT / 'og-card-v3.png').convert('RGB')
    card = previous.copy()
    ImageDraw.Draw(card).rectangle((215, 95, 489, 359), fill=previous.getpixel((0, 0)))
    tile = source.resize((260, 260), Image.Resampling.LANCZOS)
    card.paste(tile, (225, 95), tile)
    card.save(ROOT / 'og-card-v4.png', optimize=True)
    card.save(ROOT / 'og-card.png', optimize=True)
    if args.review_dir:
        args.review_dir.mkdir(parents=True, exist_ok=True)
        board = Image.new('RGB', (1000, 650), '#ffffff')
        draw = ImageDraw.Draw(board)
        draw.rectangle((500, 0, 999, 649), fill='#0d1117')
        for column, foreground in ((0, '#1f2328'), (500, '#f0f6fc')):
            draw.text((column + 20, 15), 'Exact master: hero 150px / error 96px; tight mark: 16 / 32 / 48 / 64px', fill=foreground)
            for x, size in ((20, 150), (195, 96)):
                board.paste(source.resize((size,size), Image.Resampling.LANCZOS), (column+x, 55), source.resize((size,size), Image.Resampling.LANCZOS))
            for x, size in ((20,16),(65,32),(125,48),(205,64)):
                sample = small.resize((size,size), Image.Resampling.LANCZOS)
                board.paste(sample, (column+x, 245), sample)
                draw.text((column+x, 320), str(size), fill=foreground)
            zoom = small.resize((16,16), Image.Resampling.LANCZOS).resize((192,192), Image.Resampling.NEAREST)
            board.paste(zoom, (column+20, 370), zoom)
            board.paste(touch.convert('RGB'), (column+255, 370))
        board.save(args.review_dir / 'brand-sizes.png')
    print('Exported primary mark, small icons, Apple touch tile, and social card')


if __name__ == '__main__':
    main()
