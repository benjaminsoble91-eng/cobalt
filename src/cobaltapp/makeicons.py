#!/usr/bin/env python3
"""Makes the Cobalt app icons from assets/cobalt-icon.png (fills the transparent corners so iOS's mask is clean).
usage: makeicons.py <cobalt-icon.png> <out dir>"""
import os, sys
from PIL import Image
src, out = sys.argv[1], sys.argv[2]
os.makedirs(out, exist_ok=True)
im = Image.open(src).convert("RGBA")
bg = Image.new("RGBA", im.size, (5, 26, 78, 255))
flat = Image.alpha_composite(bg, im).convert("RGB")
sizes = {
    "AppIcon20x20@2x.png": 40, "AppIcon20x20@3x.png": 60,
    "AppIcon29x29@2x.png": 58, "AppIcon29x29@3x.png": 87,
    "AppIcon40x40@2x.png": 80, "AppIcon40x40@3x.png": 120,
    "AppIcon60x60@2x.png": 120, "AppIcon60x60@3x.png": 180,
    "AppIcon20x20~ipad.png": 20, "AppIcon20x20@2x~ipad.png": 40,
    "AppIcon29x29~ipad.png": 29, "AppIcon29x29@2x~ipad.png": 58,
    "AppIcon40x40~ipad.png": 40, "AppIcon40x40@2x~ipad.png": 80,
    "AppIcon76x76~ipad.png": 76, "AppIcon76x76@2x~ipad.png": 152,
    "AppIcon83.5x83.5@2x~ipad.png": 167,
}
for name, px in sizes.items():
    flat.resize((px, px), Image.LANCZOS).save(os.path.join(out, name))
print("icons:", len(sizes))
