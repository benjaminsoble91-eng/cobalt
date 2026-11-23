// DopaThemes 1.1 (SpringBoard side) - draws the DopaThemes icon for any Dopamine copy that is
// using one of our themes (Home Screen, dock, App Library, folders, app switcher).
//
// Dopamine writes { bundleID : themeKey } to DT_ICON_MAP when a theme is picked. SpringBoard
// renders app icons through -[SBApplicationIcon generateIconImageWithInfo:] (iOS 13+); for a
// mapped bundle we return the theme's appIcon PNG, masked to the size/corner radius asked for.
#import "Shared.h"

typedef struct { CGSize size; CGFloat scale; CGFloat continuousCornerRadius; } DTIconImageInfo;

static NSDictionary *gMap;            // bundleID -> themeKey
static NSDictionary *gIconPaths;      // themeKey -> PNG path
static struct timespec gMapMTime;
static NSCache *gRendered;
static BOOL gEnabled = YES;

static void DTLoadIconPaths(void) {
    NSMutableDictionary *p = [NSMutableDictionary dictionary];
    for (NSDictionary *d in DTLoadThemeDicts()) {
        NSString *icon = d[@"appIcon"];
        if ([icon isKindOfClass:[NSString class]]) p[d[@"key"]] = [DT_DIR stringByAppendingPathComponent:icon];
    }
    gIconPaths = p;
}

// Re-read the map only if the file changed (cheap stat), so a redraw never sees stale data.
static void DTRefreshMapIfNeeded(void) {
    struct stat st;
    if (stat(DT_ICON_MAP.fileSystemRepresentation, &st) != 0) { gMap = @{}; memset(&gMapMTime, 0, sizeof gMapMTime); return; }
    if (gMap && st.st_mtimespec.tv_sec == gMapMTime.tv_sec && st.st_mtimespec.tv_nsec == gMapMTime.tv_nsec) return;
    gMapMTime = st.st_mtimespec;
    gMap = DTReadIconMap();
    DTLoadIconPaths();
    [gRendered removeAllObjects];
}

static UIImage *DTIconFor(id icon, DTIconImageInfo info, BOOL masked) {
    if (!gEnabled) return nil;
    NSString *bid = CBSendID(icon, "applicationBundleID");
    if (!bid) return nil;
    DTRefreshMapIfNeeded();
    NSString *key = gMap[bid];
    NSString *path = key ? gIconPaths[key] : nil;
    if (!path || info.size.width < 1 || info.size.height < 1) return nil;

    NSString *cacheKey = [NSString stringWithFormat:@"%@|%.1fx%.1f@%.1f|%.2f|%d", path, info.size.width, info.size.height,
                          info.scale, info.continuousCornerRadius, masked];
    UIImage *hit = [gRendered objectForKey:cacheKey];
    if (hit) return hit;
    UIImage *src = [UIImage imageWithContentsOfFile:path];
    if (!src) return nil;

    UIGraphicsImageRendererFormat *fmt = [UIGraphicsImageRendererFormat preferredFormat];
    fmt.scale = info.scale > 0 ? info.scale : [UIScreen mainScreen].scale;
    fmt.opaque = NO;
    CGRect r = { CGPointZero, info.size };
    UIImage *out = [[[UIGraphicsImageRenderer alloc] initWithSize:info.size format:fmt] imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        if (masked) {
            CGFloat radius = info.continuousCornerRadius > 0 ? info.continuousCornerRadius : info.size.width * 0.225;
            [[UIBezierPath bezierPathWithRoundedRect:r cornerRadius:radius] addClip];
        }
        [src drawInRect:r];
    }];
    if (out) [gRendered setObject:out forKey:cacheKey];
    return out;
}

// Only hook methods whose argument is the {size, scale, cornerRadius} struct we expect.
static BOOL DTTakesImageInfo(Class cls, SEL sel) {
    Method m = class_getInstanceMethod(cls, sel);
    const char *t = m ? method_getTypeEncoding(m) : NULL;
    if (!t || t[0] != '@') return NO;
    const char *arg = strstr(t, ":");           // skip return, self, _cmd
    return arg && (strstr(arg, "{CGSize=dd}dd}") != NULL || strstr(arg, "{?={CGSize=dd}dd}") != NULL);
}

static void DTHookImageMethod(Class cls, const char *name, BOOL masked) {
    SEL sel = sel_registerName(name);
    if (!DTTakesImageInfo(cls, sel)) return;
    __block IMP orig = CBHook(cls, sel, ^UIImage *(id self, DTIconImageInfo info) {
        UIImage *mine = DTIconFor(self, info, masked);
        return mine ?: ((UIImage *(*)(id, SEL, DTIconImageInfo))orig)(self, sel, info);
    });
}

// Ask SpringBoard to redraw the icons we may have changed. Several spellings across iOS versions;
// Dopamine also forces a redraw by switching its real icon, so these are a best-effort extra.
static void DTReloadIcons(NSSet *bundleIDs) {
    id ctl = CBSendID(objc_getClass("SBIconController"), "sharedInstance");
    id model = CBSendID(ctl, "model") ?: CBIvar(ctl, "_iconModel") ?: CBSendID(CBSendID(ctl, "iconManager"), "iconModel");
    id cache = CBSendID(CBSendID(ctl, "iconManager"), "iconImageCache");
    for (NSString *bid in bundleIDs) {
        id icon = nil;
        SEL byBundle = sel_registerName("applicationIconForBundleIdentifier:");
        SEL byDisplay = sel_registerName("expectedIconForDisplayIdentifier:");
        if ([model respondsToSelector:byBundle]) icon = ((id (*)(id, SEL, id))objc_msgSend)(model, byBundle, bid);
        if (!icon && [model respondsToSelector:byDisplay]) icon = ((id (*)(id, SEL, id))objc_msgSend)(model, byDisplay, bid);
        if (!icon) continue;
        SEL purgeIcons = sel_registerName("purgeCachedImagesForIcons:");
        if ([cache respondsToSelector:purgeIcons]) ((void (*)(id, SEL, id))objc_msgSend)(cache, purgeIcons, @[icon]);
        SEL reloadPurge = sel_registerName("reloadIconImagePurgingImageCache:");
        if ([icon respondsToSelector:reloadPurge]) { ((void (*)(id, SEL, BOOL))objc_msgSend)(icon, reloadPurge, YES); continue; }
        for (NSString *s in @[@"_notifyImageDidUpdate", @"reloadIconImage"]) {
            SEL x = NSSelectorFromString(s);
            if ([icon respondsToSelector:x]) { ((void (*)(id, SEL))objc_msgSend)(icon, x); break; }
        }
    }
}

static void DTIconMapChanged(CFNotificationCenterRef c, void *o, CFStringRef n, const void *obj, CFDictionaryRef u) {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSDictionary *old = gMap ?: @{};
        CFPreferencesAppSynchronize(DT_DOMAIN);
        gEnabled = CBPrefBool(DT_DOMAIN, CFSTR("Enabled"), YES);
        DTRefreshMapIfNeeded();
        NSMutableSet *changed = [NSMutableSet setWithArray:old.allKeys];
        [changed addObjectsFromArray:gMap.allKeys];
        DTReloadIcons(changed);
    });
}

static BOOL gInstalled;
static void DTInstallSB(void) {
    Class cls = objc_getClass("SBApplicationIcon");
    if (gInstalled || !cls) return;
    gInstalled = YES;
    DTHookImageMethod(cls, "generateIconImageWithInfo:", YES);
    DTHookImageMethod(cls, "unmaskedIconImageWithInfo:", NO);
}

__attribute__((constructor)) static void DTInitSB(void) {
    @autoreleasepool {
        if (!CBIsSpringBoard()) return;
        gRendered = [NSCache new];
        CFPreferencesAppSynchronize(DT_DOMAIN);
        gEnabled = CBPrefBool(DT_DOMAIN, CFSTR("Enabled"), YES);
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, DTIconMapChanged,
                                        CFSTR(DT_ICON_NOTIFY), NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, DTIconMapChanged,
                                        CFSTR("com.mymculture.dopathemes/prefs"), NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
        DTInstallSB();
        if (!gInstalled)
            [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidFinishLaunchingNotification object:nil
                                                               queue:[NSOperationQueue mainQueue]
                                                          usingBlock:^(NSNotification *n) { DTInstallSB(); }];
    }
}
