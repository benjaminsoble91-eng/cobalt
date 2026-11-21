#!/usr/bin/env python3
"""Makes TrollDuplicator Lite's icons: TrollDuplicator's icons with a "LITE" ribbon at the bottom.
usage: makeicons.py <TrollDuplicator.app> <out dir>"""
import glob, os, sys
from PIL import Image, ImageDraw, ImageFont
src, out = sys.argv[1], sys.argv[2]
FONT = "/usr/share/fonts/truetype/google-fonts/Poppins-Bold.ttf"
os.makedirs(out, exist_ok=True)
for path in glob.glob(os.path.join(src, "AppIcon*.png")):
    im = Image.open(path).convert("RGBA")
    w, h = im.size
    band = Image.new("RGBA", im.size, (0, 0, 0, 0))
    d = ImageDraw.Draw(band)
    top = int(h * 0.70)
    d.rectangle([0, top, w, h], fill=(20, 200, 120, 235))
    font = ImageFont.truetype(FONT, max(6, int(h * 0.22)))
    text = "LITE"
    l, t, r, b = d.textbbox((0, 0), text, font=font)
    d.text(((w - (r - l)) / 2 - l, top + (h - top - (b - t)) / 2 - t), text, font=font, fill=(255, 255, 255, 255))
    Image.alpha_composite(im, band).convert("RGB").save(os.path.join(out, os.path.basename(path)))
print("icons:", len(glob.glob(os.path.join(out, "*.png"))))
