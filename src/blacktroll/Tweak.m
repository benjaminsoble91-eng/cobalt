// BlackTroll 1.0 - gives TrollStore a black Home Screen icon.
//
// How it works: SpringBoard builds every app icon image through a handful of methods that
// take an SBIconImageInfo (size, scale, corner radius). We let SpringBoard build TrollStore's
// stock icon, then repaint it: coloured pixels (the blue background) go to black, neutral
// pixels (the white face and its dark outlines) are left alone. Nothing inside TrollStore.app
// is touched, so turning the tweak off or removing it puts the stock icon back.
// Icon images are cached by SpringBoard, so changes apply after a respring.
#import "../common/cb.h"

#define BT_DOMAIN CFSTR("com.mymculture.blacktroll")
#define BT_INFO_ENC "{SBIconImageInfo={CGSize=dd}dd}"

typedef struct { CGSize size; CGFloat scale; CGFloat continuousCornerRadius; } BTIconImageInfo;

static BOOL gEnabled = YES, gLite = NO;
static const char kBTDoneKey;   // source image -> its blackened copy

static void BTLoadPrefs(void) {
    CFPreferencesAppSynchronize(BT_DOMAIN);
    gEnabled = CBPrefBool(BT_DOMAIN, CFSTR("Enabled"), YES);
    gLite    = CBPrefBool(BT_DOMAIN, CFSTR("Lite"), NO);
}

static BOOL BTWants(id bundleID) {
    if (!gEnabled || ![bundleID isKindOfClass:[NSString class]]) return NO;
    if ([bundleID isEqualToString:@"com.opa334.TrollStore"]) return YES;
    return gLite && [bundleID isEqualToString:@"com.opa334.TrollStoreLite"];
}

static inline CGFloat BTClamp01(CGFloat v) { return v < 0 ? 0 : (v > 1 ? 1 : v); }

// Returns a copy of the icon with its coloured background turned black.
// Anything unexpected (no bitmap, odd size, no memory) returns the image untouched.
static id BTBlacken(id image) {
    if (![image isKindOfClass:[UIImage class]]) return image;
    UIImage *src = image;
    UIImage *done = objc_getAssociatedObject(src, &kBTDoneKey);
    if (done) return done;

    CGImageRef cg = src.CGImage;
    if (!cg) return src;
    size_t w = CGImageGetWidth(cg), h = CGImageGetHeight(cg);
    if (w == 0 || h == 0 || w > 2048 || h > 2048) return src;

    CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    if (!cs) return src;
    CGContextRef ctx = CGBitmapContextCreate(NULL, w, h, 8, w * 4, cs,
                                             (CGBitmapInfo)kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(cs);
    if (!ctx) return src;
    CGContextDrawImage(ctx, CGRectMake(0, 0, w, h), cg);

    uint8_t *px = CGBitmapContextGetData(ctx);
    size_t bpr = CGBitmapContextGetBytesPerRow(ctx);
    if (!px) { CGContextRelease(ctx); return src; }

    for (size_t y = 0; y < h; y++) {
        uint8_t *p = px + y * bpr;
        for (size_t x = 0; x < w; x++, p += 4) {
            CGFloat a = p[3] / 255.0;
            if (a <= 0) continue;
            CGFloat r = BTClamp01(p[0] / 255.0 / a), g = BTClamp01(p[1] / 255.0 / a), b = BTClamp01(p[2] / 255.0 / a);
            CGFloat mx = MAX(r, MAX(g, b)), mn = MIN(r, MIN(g, b));
            CGFloat sat = mx > 0 ? (mx - mn) / mx : 0;
            // k: how "coloured" the pixel is. 0 = neutral (keep), 1 = fully coloured (repaint).
            CGFloat k = BTClamp01((sat - 0.12) / 0.25);
            if (k <= 0) continue;
            // What a coloured pixel becomes: black, unless it is nearly white (soft edges of the face).
            CGFloat t = BTClamp01((mn - 0.5) / 0.4);
            r += (t - r) * k; g += (t - g) * k; b += (t - b) * k;
            p[0] = (uint8_t)lround(r * a * 255.0);
            p[1] = (uint8_t)lround(g * a * 255.0);
            p[2] = (uint8_t)lround(b * a * 255.0);
        }
    }

    CGImageRef outCG = CGBitmapContextCreateImage(ctx);
    CGContextRelease(ctx);
    if (!outCG) return src;
    UIImage *out = [UIImage imageWithCGImage:outCG scale:src.scale orientation:src.imageOrientation];
    CGImageRelease(outCG);
    if (!out) return src;
    objc_setAssociatedObject(src, &kBTDoneKey, out, OBJC_ASSOCIATION_RETAIN);
    objc_setAssociatedObject(out, &kBTDoneKey, out, OBJC_ASSOCIATION_ASSIGN);   // already done: never repaint twice
    return out;
}

// -[<icon> sel:(SBIconImageInfo)info] -> UIImage. Only hooked if the signature is the one we expect.
static void BTHookIcon(Class cls, const char *name) {
    if (!cls) return;
    SEL sel = sel_registerName(name);
    Method m = class_getInstanceMethod(cls, sel);
    const char *enc = m ? method_getTypeEncoding(m) : NULL;
    if (!enc || enc[0] != '@' || !strstr(enc, BT_INFO_ENC)) return;
    IMP orig = method_getImplementation(m);
    CBHook(cls, sel, ^id(id self, BTIconImageInfo info) {
        id img = ((id (*)(id, SEL, BTIconImageInfo))orig)(self, sel, info);
        if (!gEnabled || !img) return img;
        return BTWants(CBSendID(self, "applicationBundleID")) ? BTBlacken(img) : img;
    });
}

// -[SBApplication icon:(SBIcon *)icon sel:(SBIconImageInfo)info] -> UIImage (the icon's data source).
static void BTHookSource(Class cls, const char *name) {
    if (!cls) return;
    SEL sel = sel_registerName(name);
    Method m = class_getInstanceMethod(cls, sel);
    const char *enc = m ? method_getTypeEncoding(m) : NULL;
    if (!enc || enc[0] != '@' || !strstr(enc, BT_INFO_ENC)) return;
    IMP orig = method_getImplementation(m);
    CBHook(cls, sel, ^id(id self, id icon, BTIconImageInfo info) {
        id img = ((id (*)(id, SEL, id, BTIconImageInfo))orig)(self, sel, icon, info);
        if (!gEnabled || !img) return img;
        return BTWants(CBSendID(self, "bundleIdentifier")) ? BTBlacken(img) : img;
    });
}

static BOOL gInstalled = NO;
static void BTInstall(void) {
    if (gInstalled) return;
    Class icon = objc_getClass("SBApplicationIcon") ?: objc_getClass("SBLeafIcon");
    if (!icon) return;
    gInstalled = YES;
    BTHookIcon(icon, "generateIconImageWithInfo:");
    BTHookIcon(icon, "iconImageWithInfo:");
    BTHookIcon(icon, "unmaskedIconImageWithInfo:");
    Class app = objc_getClass("SBApplication");
    BTHookSource(app, "icon:imageWithInfo:");
    BTHookSource(app, "icon:unmaskedImageWithInfo:");
}

static void BTRespring(void) {
    id svc = CBSendID(objc_getClass("FBSystemService"), "sharedInstance");
    SEL s = sel_registerName("exitAndRelaunch:");
    if ([svc respondsToSelector:s]) ((void (*)(id, SEL, BOOL))objc_msgSend)(svc, s, YES);
    else exit(0);   // launchd restarts SpringBoard
}

static void BTPrefsChanged(CFNotificationCenterRef c, void *o, CFStringRef n, const void *obj, CFDictionaryRef u) {
    BTLoadPrefs();
}
// The "Respring to apply" switch in Settings: flip it back off, then respring.
static void BTRespringRequested(CFNotificationCenterRef c, void *o, CFStringRef n, const void *obj, CFDictionaryRef u) {
    CFPreferencesAppSynchronize(BT_DOMAIN);
    if (!CBPrefBool(BT_DOMAIN, CFSTR("Respring"), NO)) return;
    CFPreferencesSetAppValue(CFSTR("Respring"), kCFBooleanFalse, BT_DOMAIN);
    CFPreferencesAppSynchronize(BT_DOMAIN);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ BTRespring(); });
}

__attribute__((constructor)) static void BTInit(void) {
    @autoreleasepool {
        if (!CBIsSpringBoard()) return;
        BTLoadPrefs();
        CFNotificationCenterRef dc = CFNotificationCenterGetDarwinNotifyCenter();
        CFNotificationCenterAddObserver(dc, NULL, BTPrefsChanged, CFSTR("com.mymculture.blacktroll/prefs"), NULL,
                                        CFNotificationSuspensionBehaviorDeliverImmediately);
        CFNotificationCenterAddObserver(dc, NULL, BTRespringRequested, CFSTR("com.mymculture.blacktroll/respring"), NULL,
                                        CFNotificationSuspensionBehaviorDeliverImmediately);
        BTInstall();
        if (!gInstalled) {
            // SpringBoardHome not loaded yet: catch it as soon as SpringBoard finishes launching.
            [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidFinishLaunchingNotification object:nil
                                                               queue:[NSOperationQueue mainQueue]
                                                          usingBlock:^(NSNotification *n) { BTInstall(); }];
        }
    }
}
