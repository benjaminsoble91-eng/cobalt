# Generates the DopaThemes backgrounds, icons and Themes.plist (run: gen_themes.py <outdir> <DopamineLogo.png>).
# The same blob data is saved as each theme's "motion" entry, which the Motion add-on animates.
import sys, os, plistlib, numpy as np
from PIL import Image, ImageFilter
out = sys.argv[1]; logo_path = sys.argv[2]; os.makedirs(out, exist_ok=True)
rng = np.random.default_rng(7)
W, H = 750, 500
def rgb(h): return np.array([int(h[i:i+2],16) for i in (0,2,4)], float)/255
# name, key, base, blobs, menu, window, blur, shadow, icon(top,bottom,logo)
T = [
 ("Trollamine","trollamine","0A2A55",[("1E6BFF",0.450,.10,.55,1.0),("1FD67A",0.550,.95,.55,1.0)],"4F0C3A5A","60030A0C",30,False,("2F6BFF","22D37A","FFFFFF")),
 ("Gold","gold","070400",[("FFC233",0.455,.60,.55,1.0),("FFA000",0.590,.30,.45,.9),("FFE7A0",0.470,.70,.20,.55)],"5F4A3505","600C0800",30,True,("FFD54A","D98400","FFFFFF")),
 ("Lime","lime","040700",[("B6F000",0.440,.40,.50,1.0),("6FD000",0.590,.75,.50,.9),("E4FF7A",0.455,.35,.18,.5)],"5F2A3A05","60050800",30,False,("C8FF2E","4FA000","FFFFFF")),
 ("Midnight","midnight","000000",[("2C2C2E",0.440,.30,.55,.9),("1C1C1E",0.590,.80,.50,.8)],"7F161616","99000000",12,False,("3A3A3C","050505","FFFFFF")),
 ("Frost","frost","C9DAE8",[("FFFFFF",0.440,.30,.60,1.0),("A9C8E2",0.605,.80,.55,.9),("EAF3FA",0.560,.20,.35,.8)],"5F1A2A3A","60101820",30,True,("F7FAFD","A9C4DA","1E2A38")),
 ("Mocha","mocha","7A5638",[("C08A5B",0.425,.35,.60,1.0),("E8CFA8",0.584,.65,.40,.9),("7A4E2E",0.605,.10,.45,.8)],"5F3A2412","60140C06",30,True,("D2A679","6F4A2E","FFFFFF")),
 ("Neon","neon","05010A",[("FF2BD6",0.410,.35,.45,1.0),("00E5FF",0.596,.70,.45,1.0)],"5F3A0A40","60050208",25,True,("FF2BD6","00C8FF","FFFFFF")),
]
yy, xx = np.mgrid[0:H, 0:W]; xx = xx/W*1.5; yy = yy/H
logo = Image.open(logo_path).convert('RGBA')
def make_icon(top, bot, tint, S=512):
    t = np.linspace(0,1,S)[:,None,None]; a = rgb(top)*(1-t)+rgb(bot)*t
    im = Image.fromarray((np.repeat(a,S,1)*255).astype(np.uint8)).convert('RGBA')
    L = logo.resize((int(S*.66),)*2, Image.LANCZOS)
    col = Image.new('RGBA', L.size, tuple(int(tint[i:i+2],16) for i in (0,2,4))+(255,)); col.putalpha(L.split()[3])
    im.alpha_composite(col, ((S-L.width)//2, (S-L.height)//2)); return im.convert('RGB')
plist = []
for name,key,base,blobs,menu,win,blur,shadow,ic in T:
    img = np.tile(rgb(base), (H,W,1))
    for col,cx,cy,r,s in blobs:
        d2 = (xx-cx*1.5)**2 + (yy-cy)**2
        a = s*np.exp(-d2/(2*(r*0.55)**2))[...,None]
        img = img*(1-a) + rgb(col)*a
    img = np.clip(img + (np.exp(-((xx/1.5-yy*0.6)-0.35)**2/(2*0.2**2))*0.05)[...,None], 0, 1)
    im = Image.fromarray((img*255).astype(np.uint8)).filter(ImageFilter.GaussianBlur(6)).resize((3000,2000), Image.BICUBIC)
    a = np.asarray(im).astype(np.float32); a += rng.normal(0, 2.2, a.shape[:2])[...,None]
    fn = f"dopathemes_{key}.jpg"; Image.fromarray(np.clip(a,0,255).astype(np.uint8)).save(os.path.join(out,fn), quality=86, optimize=True, progressive=True)
    icn = f"icon_{key}.png"; make_icon(*ic).save(os.path.join(out,icn), optimize=True)
    motion = dict(base=base, blobs=[dict(color=c, x=float(x), y=float(y), r=float(r), strength=float(st)) for c,x,y,r,st in blobs])
    plist.append(dict(key=f"dopathemes.{key}", name=name, image=fn, appIcon=icn, actionMenuColor=menu, windowColor=win, blur=blur, titleShadow=shadow, motion=motion))
plistlib.dump(plist, open(os.path.join(out,"Themes.plist"),"wb"))
print("ok", len(plist))
