#!/usr/bin/env python3
"""Makes BlobKeeper's app icons + the Cobalt source icon/banner.
usage: makeicons.py <icons dir> <assets dir>"""
import os, sys
from PIL import Image, ImageDraw, ImageFilter, ImageFont
out, assets = sys.argv[1], sys.argv[2]
os.makedirs(out, exist_ok=True)
S = 1024

def gradient(w, h, top, bot):
    im = Image.new("RGB", (w, h))
    d = ImageDraw.Draw(im)
    for y in range(h):
        t = y / (h - 1)
        d.line([(0, y), (w, y)], fill=tuple(int(top[i] + (bot[i] - top[i]) * t) for i in range(3)))
    return im

def blob_mark(size):
    """White ticket-shaped card with a notch on each side and a blue check, plus soft glow."""
    layer = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)
    w, h = int(size * 0.58), int(size * 0.66)
    x0, y0 = (size - w) // 2, (size - h) // 2
    d.rounded_rectangle([x0, y0, x0 + w, y0 + h], radius=int(size * 0.07), fill=(255, 255, 255, 255))
    r = int(size * 0.055)
    cy = y0 + int(h * 0.62)
    d.ellipse([x0 - r, cy - r, x0 + r, cy + r], fill=(0, 0, 0, 0))
    d.ellipse([x0 + w - r, cy - r, x0 + w + r, cy + r], fill=(0, 0, 0, 0))
    # dashed tear line
    dash = int(size * 0.03)
    for x in range(x0 + r + dash, x0 + w - r - dash, dash * 2):
        d.line([(x, cy), (x + dash, cy)], fill=(110, 162, 255, 255), width=max(2, size // 120))
    # check mark in the top part
    cx, cy2 = size // 2, y0 + int(h * 0.31)
    k = int(size * 0.11)
    d.line([(cx - k, cy2), (cx - k // 3, cy2 + k * 2 // 3), (cx + k, cy2 - k * 2 // 3)],
           fill=(46, 107, 255, 255), width=int(size * 0.05), joint="curve")
    # small lines in the bottom stub
    for i in range(2):
        yy = cy + int(h * 0.11) + i * int(h * 0.09)
        d.rounded_rectangle([x0 + int(w * 0.22), yy, x0 + int(w * (0.78 - 0.22 * i)), yy + int(size * 0.025)],
                            radius=int(size * 0.012), fill=(190, 208, 255, 255))
    return layer

def icon():
    bg = gradient(S, S, (46, 107, 255), (11, 19, 48)).convert("RGBA")
    glow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    ImageDraw.Draw(glow).ellipse([S * 0.18, S * 0.12, S * 0.82, S * 0.88], fill=(110, 162, 255, 120))
    bg = Image.alpha_composite(bg, glow.filter(ImageFilter.GaussianBlur(S // 10)))
    mark = blob_mark(S)
    shadow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    shadow.paste((0, 0, 30, 140), mask=mark.split()[3])
    bg = Image.alpha_composite(bg, shadow.filter(ImageFilter.GaussianBlur(S // 40)).transform((S, S), Image.AFFINE, (1, 0, 0, 0, 1, -S // 60)))
    return Image.alpha_composite(bg, mark).convert("RGB")

big = icon()
sizes = {"AppIcon29x29@2x.png": 58, "AppIcon29x29@3x.png": 87, "AppIcon40x40@2x.png": 80, "AppIcon40x40@3x.png": 120,
         "AppIcon60x60@2x.png": 120, "AppIcon60x60@3x.png": 180, "AppIcon29x29~ipad.png": 29, "AppIcon29x29@2x~ipad.png": 58,
         "AppIcon40x40~ipad.png": 40, "AppIcon40x40@2x~ipad.png": 80, "AppIcon76x76~ipad.png": 76, "AppIcon76x76@2x~ipad.png": 152,
         "AppIcon83.5x83.5@2x~ipad.png": 167}
for name, px in sizes.items():
    big.resize((px, px), Image.LANCZOS).save(os.path.join(out, name))
big.resize((256, 256), Image.LANCZOS).save(os.path.join(assets, "icon_com.mymculture.blobkeeper.png"))

# Sileo featured banner (same 2x size the other banners use is checked by the caller)
W, H = 1052, 592
ban = gradient(W, H, (14, 26, 70), (46, 107, 255)).convert("RGBA")
m = blob_mark(380)
ban.alpha_composite(m, (W - 380 - 30, (H - 380) // 2))
d = ImageDraw.Draw(ban)
bold = "/usr/share/fonts/truetype/google-fonts/Poppins-Bold.ttf"
reg = "/usr/share/fonts/truetype/google-fonts/Poppins-Medium.ttf"
if not os.path.exists(reg): reg = bold
d.text((64, 200), "BlobKeeper", font=ImageFont.truetype(bold, 96), fill=(255, 255, 255))
d.text((68, 326), "Your onboard blob, saved in one tap", font=ImageFont.truetype(reg, 32), fill=(205, 217, 255))
ban.convert("RGB").resize((789, 444), Image.LANCZOS).save(os.path.join(assets, "banner_com.mymculture.blobkeeper.png"))
print("ok")
