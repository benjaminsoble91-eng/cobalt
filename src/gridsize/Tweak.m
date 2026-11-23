// GridSize 1.0 - choose how many apps go in each Home Screen row (and how many rows),
// plus how many fit in the dock. Icons shrink (or grow) automatically so everything fits.
//
// How it works: SpringBoard asks SBHDefaultIconListLayoutProvider to make one layout per
// icon location (Home Screen, dock, folder...). We let it build the stock layout, then
// rewrite that layout's grid configuration: column/row counts and the icon image size.
// Layouts are made once at launch, so changes apply after a respring.
#import "../common/cb.h"

#define GS_DOMAIN CFSTR("com.mymculture.gridsize")

typedef struct { CGSize size; CGFloat scale; CGFloat continuousCornerRadius; } GSIconImageInfo;

static BOOL gEnabled = YES, gAutoSize = YES, gHideLabels = NO, gDock = NO;
static NSInteger gColumns = 4, gRows = 6, gDockColumns = 4, gIconPercent = 100;

static NSInteger GSPrefInt(CFStringRef key, NSInteger def, NSInteger lo, NSInteger hi) {
    CFPropertyListRef v = CFPreferencesCopyAppValue(key, GS_DOMAIN);
    NSInteger r = def;
    if (v) {
        if (CFGetTypeID(v) == CFNumberGetTypeID()) {
            double d = def; CFNumberGetValue((CFNumberRef)v, kCFNumberDoubleType, &d); r = (NSInteger)llround(d);
        }
        CFRelease(v);
    }
    return MAX(lo, MIN(hi, r));
}

static void GSLoadPrefs(void) {
    CFPreferencesAppSynchronize(GS_DOMAIN);
    gEnabled     = CBPrefBool(GS_DOMAIN, CFSTR("Enabled"), YES);
    gColumns     = GSPrefInt(CFSTR("Columns"), 4, 3, 8);
    gRows        = GSPrefInt(CFSTR("Rows"), 6, 3, 10);
    gAutoSize    = CBPrefBool(GS_DOMAIN, CFSTR("AutoSize"), YES);
    gIconPercent = GSPrefInt(CFSTR("IconPercent"), 100, 50, 130);
    gHideLabels  = CBPrefBool(GS_DOMAIN, CFSTR("HideLabels"), NO);
    gDock        = CBPrefBool(GS_DOMAIN, CFSTR("DockEnabled"), NO);
    gDockColumns = GSPrefInt(CFSTR("DockColumns"), 4, 3, 7);
}

// ---- grid configuration helpers ------------------------------------------
static NSUInteger GSGetUInt(id o, const char *getter) {
    SEL s = sel_registerName(getter);
    if (!o || ![o respondsToSelector:s]) return 0;
    return ((NSUInteger (*)(id, SEL))objc_msgSend)(o, s);
}
// Prefer the property setter; fall back to writing the backing ivar.
static void GSSetUInt(id o, const char *setter, const char *ivar, NSUInteger value) {
    SEL s = sel_registerName(setter);
    if ([o respondsToSelector:s]) { ((void (*)(id, SEL, NSUInteger))objc_msgSend)(o, s, value); return; }
    Ivar iv = class_getInstanceVariable(object_getClass(o), ivar);
    if (iv && ivar_getTypeEncoding(iv)[0] == 'Q')
        *(NSUInteger *)((uint8_t *)(__bridge void *)o + ivar_getOffset(iv)) = value;
}
// Only touch the icon size if SpringBoard's struct is the shape we expect.
static BOOL GSHasImageInfo(id cfg) {
    SEL g = sel_registerName("iconImageInfo"), s = sel_registerName("setIconImageInfo:");
    if (![cfg respondsToSelector:g] || ![cfg respondsToSelector:s]) return NO;
    Method m = class_getInstanceMethod(object_getClass(cfg), g);
    const char *t = m ? method_getTypeEncoding(m) : NULL;
    return t && strncmp(t, "{SBIconImageInfo={CGSize=dd}dd}", 31) == 0;
}

static void GSApply(id cfg, NSInteger cols, NSInteger rows, BOOL resize) {
    if (!cfg) return;
    NSUInteger oc = GSGetUInt(cfg, "numberOfPortraitColumns");
    NSUInteger orw = GSGetUInt(cfg, "numberOfPortraitRows");
    if (!oc || !orw) return;
    NSUInteger lc = GSGetUInt(cfg, "numberOfLandscapeColumns");
    NSUInteger lr = GSGetUInt(cfg, "numberOfLandscapeRows");
    BOOL swapped = lc && lr && lc == orw && lr == oc;   // iPad: landscape is portrait turned sideways

    if (rows <= 0) rows = orw;  // dock: keep its single row
    GSSetUInt(cfg, "setNumberOfPortraitColumns:", "_numberOfPortraitColumns", cols);
    GSSetUInt(cfg, "setNumberOfPortraitRows:", "_numberOfPortraitRows", rows);
    if (lc && lr) {
        GSSetUInt(cfg, "setNumberOfLandscapeColumns:", "_numberOfLandscapeColumns", swapped ? rows : cols);
        GSSetUInt(cfg, "setNumberOfLandscapeRows:", "_numberOfLandscapeRows", swapped ? cols : rows);
    }

    if (!resize || !GSHasImageInfo(cfg)) return;
    GSIconImageInfo info = ((GSIconImageInfo (*)(id, SEL))objc_msgSend)(cfg, sel_registerName("iconImageInfo"));
    if (info.size.width <= 0) return;
    // Fit: shrink by whichever direction got more crowded. Fewer apps per row can grow
    // icons, but only a little, so they never run into each other.
    CGFloat f = 1.0;
    if (gAutoSize) {
        f = MIN((CGFloat)oc / cols, (CGFloat)orw / rows);
        f = MIN(f, 1.2);
    }
    f *= gIconPercent / 100.0;
    if (fabs(f - 1.0) < 0.001) return;
    info.size = CGSizeMake(round(info.size.width * f), round(info.size.height * f));
    info.continuousCornerRadius *= f;
    ((void (*)(id, SEL, GSIconImageInfo))objc_msgSend)(cfg, sel_registerName("setIconImageInfo:"), info);
}

static BOOL GSIsHomeLocation(NSString *loc) {
    return [loc isEqualToString:@"SBIconLocationRoot"] || [loc isEqualToString:@"SBIconLocationRootWithWidgets"];
}

// ---- hooks ----------------------------------------------------------------
static IMP origMakeLayout;
static IMP origIconLayout;

static void GSInstall(void) {
    static BOOL done;
    if (done) return;
    Class prov = objc_getClass("SBHDefaultIconListLayoutProvider");
    if (!prov) return;
    done = YES;

    SEL mk = sel_registerName("makeLayoutForIconLocation:");
    origMakeLayout = CBHook(prov, mk, ^id(id self, NSString *loc) {
        id layout = ((id (*)(id, SEL, NSString *))origMakeLayout)(self, mk, loc);
        if (!gEnabled || ![loc isKindOfClass:[NSString class]]) return layout;
        id cfg = CBSendID(layout, "layoutConfiguration");
        if (GSIsHomeLocation(loc)) GSApply(cfg, gColumns, gRows, YES);
        else if (gDock && [loc isEqualToString:@"SBIconLocationDock"]) GSApply(cfg, gDockColumns, 0, YES);
        return layout;
    });

    // Hide app names on the Home Screen (helps a lot with 6+ apps per row).
    Class iv = objc_getClass("SBIconView");
    SEL ls = sel_registerName("layoutSubviews");
    origIconLayout = CBHook(iv, ls, ^(UIView *self) {
        ((void (*)(id, SEL))origIconLayout)(self, ls);
        if (!gEnabled || !gHideLabels) return;
        id loc = CBSendID(self, "location");
        if (![loc isKindOfClass:[NSString class]] || !GSIsHomeLocation(loc)) return;
        UIView *label = CBIvar(self, "_labelView");
        if ([label isKindOfClass:[UIView class]]) label.hidden = YES;
    });
}

static void GSRespring(void) {
    id svc = CBSendID(objc_getClass("FBSystemService"), "sharedInstance");
    SEL s = sel_registerName("exitAndRelaunch:");
    if ([svc respondsToSelector:s]) ((void (*)(id, SEL, BOOL))objc_msgSend)(svc, s, YES);
    else exit(0);   // launchd restarts SpringBoard
}

static void GSPrefsChanged(CFNotificationCenterRef c, void *o, CFStringRef n, const void *obj, CFDictionaryRef u) {
    GSLoadPrefs();
}
// The "Respring to apply" switch in Settings: flip it back off, then respring.
static void GSRespringRequested(CFNotificationCenterRef c, void *o, CFStringRef n, const void *obj, CFDictionaryRef u) {
    CFPreferencesAppSynchronize(GS_DOMAIN);
    if (!CBPrefBool(GS_DOMAIN, CFSTR("Respring"), NO)) return;
    CFPreferencesSetAppValue(CFSTR("Respring"), kCFBooleanFalse, GS_DOMAIN);
    CFPreferencesAppSynchronize(GS_DOMAIN);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ GSRespring(); });
}

__attribute__((constructor)) static void GSInit(void) {
    @autoreleasepool {
        if (!CBIsSpringBoard()) return;
        GSLoadPrefs();
        CFNotificationCenterRef dc = CFNotificationCenterGetDarwinNotifyCenter();
        CFNotificationCenterAddObserver(dc, NULL, GSPrefsChanged, CFSTR("com.mymculture.gridsize/prefs"), NULL,
                                        CFNotificationSuspensionBehaviorDeliverImmediately);
        CFNotificationCenterAddObserver(dc, NULL, GSRespringRequested, CFSTR("com.mymculture.gridsize/respring"), NULL,
                                        CFNotificationSuspensionBehaviorDeliverImmediately);
        GSInstall();
        if (!objc_getClass("SBHDefaultIconListLayoutProvider")) {
            // SpringBoardHome not loaded yet: catch it as soon as SpringBoard finishes launching.
            [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidFinishLaunchingNotification object:nil
                                                               queue:[NSOperationQueue mainQueue]
                                                          usingBlock:^(NSNotification *n) { GSInstall(); }];
        }
    }
}
