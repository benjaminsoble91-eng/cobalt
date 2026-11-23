# Makes the alternate-icon PNGs Dopamine's Info.plist points at, from res/icon_<name>.png (512px).
import sys, os, glob, plistlib
from PIL import Image
res, out = sys.argv[1], sys.argv[2]; os.makedirs(out, exist_ok=True)
SIZES = [("60x60@2x", 120), ("60x60@3x", 180), ("60x60@2x~ipad", 120),
         ("76x76~ipad", 76), ("76x76@2x~ipad", 152), ("83.5x83.5@2x~ipad", 167)]
for t in plistlib.load(open(os.path.join(res, "Themes.plist"), "rb")):
    short = t["key"].split(".", 1)[1]
    src = Image.open(os.path.join(res, t["appIcon"])).convert("RGB")
    for suffix, px in SIZES:
        src.resize((px, px), Image.LANCZOS).save(os.path.join(out, f"AppIcon_DopaThemes_{short}{suffix}.png"), optimize=True)
print("icons:", len(os.listdir(out)))
