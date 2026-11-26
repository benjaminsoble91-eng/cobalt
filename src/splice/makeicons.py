# Draws the Splice icon: cobalt gradient, a white app tile with a tweak puzzle piece clicking into it.
import sys
from PIL import Image, ImageDraw, ImageFilter
S = 1024
def grad():
    img = Image.new("RGB", (S, S))
    px = img.load()
    a, b = (34, 84, 255), (0, 200, 255)
    for y in range(S):
        for x in range(S):
            t = (x * 0.45 + (S - y) * 0.55) / S
            px[x, y] = tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(3))
    return img
img = grad().convert("RGBA")
# soft glow
glow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
ImageDraw.Draw(glow).ellipse((150, 120, 900, 870), fill=(255, 255, 255, 60))
img = Image.alpha_composite(img, glow.filter(ImageFilter.GaussianBlur(120)))
# shadow + app tile
def tile(d, off, fill):
    x, y = 220 + off, 300 + off
    d.rounded_rectangle((x, y, x + 470, y + 470), radius=110, fill=fill)
sh = Image.new("RGBA", (S, S), (0, 0, 0, 0))
tile(ImageDraw.Draw(sh), 18, (0, 20, 90, 110))
img = Image.alpha_composite(img, sh.filter(ImageFilter.GaussianBlur(26)))
d = ImageDraw.Draw(img)
tile(d, 0, (255, 255, 255, 255))
# puzzle piece (tweak) overlapping the top-right corner
def piece(d, ox, oy, fill):
    s = 300
    d.rounded_rectangle((ox, oy, ox + s, oy + s), radius=60, fill=fill)
    k = 92
    d.ellipse((ox + s / 2 - k / 2, oy - k * 0.62, ox + s / 2 + k / 2, oy + k * 0.38), fill=fill)          # top knob
    d.ellipse((ox + s - k * 0.38, oy + s / 2 - k / 2, ox + s + k * 0.62, oy + s / 2 + k / 2), fill=fill)  # right knob
ps = Image.new("RGBA", (S, S), (0, 0, 0, 0))
piece(ImageDraw.Draw(ps), 545, 205, (20, 0, 80, 120))
img = Image.alpha_composite(img, ps.filter(ImageFilter.GaussianBlur(22)))
d = ImageDraw.Draw(img)
piece(d, 530, 190, (139, 92, 246, 255))
# little highlight stripes on the tile = "app content"
for i, w in enumerate((250, 190, 220)):
    y = 470 + i * 80
    d.rounded_rectangle((300, y, 300 + w, y + 36), radius=18, fill=(34, 84, 255, 70))
out = sys.argv[1]
img = img.convert("RGB")
img.save(f"{out}/icon1024.png")
for name, px in [("AppIcon29x29@2x", 58), ("AppIcon29x29@3x", 87), ("AppIcon40x40@2x", 80), ("AppIcon40x40@3x", 120),
                 ("AppIcon60x60@2x", 120), ("AppIcon60x60@3x", 180), ("AppIcon76x76@2x~ipad", 152), ("AppIcon83.5x83.5@2x~ipad", 167)]:
    img.resize((px, px), Image.LANCZOS).save(f"{out}/{name}.png")

# Store art for the Cobalt source: 300px icon + 789x444 Sileo banner.
if len(sys.argv) > 2:
    from PIL import ImageFont
    assets = sys.argv[2]
    img.resize((300, 300), Image.LANCZOS).save(f"{assets}/icon_com.mymculture.splice.png")
    W, H = 789, 444
    b = Image.new("RGB", (W, H))
    bp = b.load()
    for y in range(H):
        for x in range(W):
            t = (x / W) * 0.4 + (1 - y / H) * 0.6
            bp[x, y] = (int(16 + 26 * t), int(28 + 40 * t), int(90 + 80 * t))
    b = b.convert("RGBA")
    ic = img.resize((200, 200), Image.LANCZOS)
    mask = Image.new("L", (200, 200), 0)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, 199, 199), radius=46, fill=255)
    sh = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    ImageDraw.Draw(sh).rounded_rectangle((56, 130, 256, 330), radius=46, fill=(0, 0, 0, 130))
    b = Image.alpha_composite(b, sh.filter(ImageFilter.GaussianBlur(14)))
    b.paste(ic, (56, 122), mask)
    d = ImageDraw.Draw(b)
    F = "/usr/share/fonts/opentype/inter/"
    d.text((300, 133), "APP", font=ImageFont.truetype(F + "Inter-Bold.otf", 20), fill=(140, 180, 255))
    d.text((298, 160), "Splice", font=ImageFont.truetype(F + "Inter-Bold.otf", 64), fill=(255, 255, 255))
    small = ImageFont.truetype(F + "Inter-Regular.otf", 23)
    d.text((300, 250), "Drop in an app and its tweaks.", font=small, fill=(205, 218, 255))
    d.text((300, 284), "Get the modded app back.", font=small, fill=(205, 218, 255))
    b.convert("RGB").save(f"{assets}/banner_com.mymculture.splice.png")
