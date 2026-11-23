// GridSize 1.1 - choose how many apps go in each Home Screen row (and how many rows),
// plus how many fit in the dock. Widgets resize to match the new grid. Icons shrink (or grow) automatically so everything fits.
//
// How it works: SpringBoard asks SBHDefaultIconListLayoutProvider to make one layout per
// icon location (Home Screen, dock, folder...). We let it build the stock layout, then
// rewrite that layout's grid configuration: column/row counts and the icon image size.
// Layouts are made once at launch, so changes apply after a respring.
#import "../common/cb.h"

#define GS_DOMAIN CFSTR("com.mymculture.gridsize")

typedef struct { CGSize size; CGFloat scale; CGFloat continuousCornerRadius; } GSIconImageInfo;

static BOOL gEnabled = YES, gAutoSize = YES, gHideLabels = NO, gDock = NO, gWidgets = YES;
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
    gWidgets     = CBPrefBool(GS_DOMAIN, CFSTR("ResizeWidgets"), YES);
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

// ---- widgets ----------------------------------------------------------------
// SpringBoard keeps two per-size tables in the grid configuration (iOS 14+):
//   _iconGridSizeClassSizes       how many grid cells each widget size spans (small 2x2, medium 4x2, large 4x4...)
//   _iconGridSizeClassIconImageInfos  the pixel size each widget size is drawn at (entry 0 is the app icon)
// Stock sizes are tuned for 4 columns, so with more apps per row widgets overlap or float in
// odd gaps. We rescale both: spans keep the same share of the page, and the drawn size is
// recomputed to fill exactly that area while keeping Apple's shape.
typedef struct { uint16_t columns, rows; } GSGridSize;

static int GSCount(const char *enc, const char *needle) {
    int n = 0;
    for (const char *p = enc; p && (p = strstr(p, needle)); p += strlen(needle)) n++;
    return n;
}
static void *GSIvarPtr(id o, const char *name, const char *needle, int *count) {
    Ivar iv = class_getInstanceVariable(object_getClass(o), name);
    if (!iv) return NULL;
    const char *enc = ivar_getTypeEncoding(iv);
    int n = enc ? GSCount(enc, needle) : 0;
    if (n < 2 || n > 12) return NULL;
    *count = n;
    return (uint8_t *)(__bridge void *)o + ivar_getOffset(iv);
}

typedef struct {
    int nInfos, nSpans;
    GSIconImageInfo infos[12];
    GSGridSize spans[12];
    CGSize list; UIEdgeInsets insets;
} GSStock;

static BOOL GSReadStock(id cfg, GSStock *s) {
    memset(s, 0, sizeof(*s));
    GSIconImageInfo *infos = GSIvarPtr(cfg, "_iconGridSizeClassIconImageInfos", "{SBIconImageInfo=", &s->nInfos);
    GSGridSize *spans = GSIvarPtr(cfg, "_iconGridSizeClassSizes", "{SBHIconGridSize=", &s->nSpans);
    if (!infos || !spans) return NO;
    memcpy(s->infos, infos, sizeof(GSIconImageInfo) * s->nInfos);
    memcpy(s->spans, spans, sizeof(GSGridSize) * s->nSpans);
    SEL ls = sel_registerName("listSizeForIconSpacingCalculation");
    if ([cfg respondsToSelector:ls]) s->list = ((CGSize (*)(id, SEL))objc_msgSend)(cfg, ls);
    if (s->list.width <= 0 || s->list.height <= 0) {
        CGSize b = [UIScreen mainScreen].bounds.size;
        s->list = CGSizeMake(MIN(b.width, b.height), MAX(b.width, b.height) * 0.78);  // minus dock/status bar
    }
    SEL in = sel_registerName("portraitLayoutInsets");
    if ([cfg respondsToSelector:in]) s->insets = ((UIEdgeInsets (*)(id, SEL))objc_msgSend)(cfg, in);
    return YES;
}

// Distance from the leading edge of the first cell to the trailing edge of the last cell
// for a widget spanning `span` cells in a grid of `count` cells of size `item`.
static CGFloat GSExtent(CGFloat avail, NSInteger count, CGFloat item, NSInteger span) {
    if (count <= 1 || span <= 1) return span <= 1 ? item : avail;
    CGFloat pitch = (avail - item) / (count - 1);
    return item + pitch * (span - 1);
}

static void GSApplyWidgets(id cfg, const GSStock *s, NSUInteger oc, NSUInteger orw,
                           NSInteger cols, NSInteger rows, CGFloat newIcon) {
    int nInfos, nSpans;
    GSIconImageInfo *infos = GSIvarPtr(cfg, "_iconGridSizeClassIconImageInfos", "{SBIconImageInfo=", &nInfos);
    GSGridSize *spans = GSIvarPtr(cfg, "_iconGridSizeClassSizes", "{SBHIconGridSize=", &nSpans);
    if (!infos || !spans || nInfos - nSpans < 0 || nInfos - nSpans > 1) return;
    CGFloat availW = s->list.width - s->insets.left - s->insets.right;
    CGFloat availH = s->list.height - s->insets.top - s->insets.bottom;
    CGFloat stockIcon = s->infos[0].size.width;
    if (availW <= 0 || availH <= 0 || stockIcon <= 0) return;

    for (int i = 0; i < nSpans; i++) {
        GSGridSize st = s->spans[i];
        if (!st.columns || !st.rows) continue;
        // New span: same share of the page. Half-width widgets stay at least 2 wide so they
        // never shrink to a single app slot; full-width ones always fill the row.
        NSInteger w = st.columns >= oc ? cols : MAX(2, (NSInteger)floor((double)st.columns * cols / oc));
        NSInteger h = st.rows >= orw ? rows : (NSInteger)llround((double)st.rows * rows / orw);
        w = MIN(MAX(w, 1), cols);
        h = MIN(MAX(h, MIN((NSInteger)st.rows, 2)), rows);
        spans[i] = (GSGridSize){ (uint16_t)w, (uint16_t)h };

        // Drawn size. The image-info table usually has the app icon first, then one entry per
        // widget size in the same order as the span table.
        int k = i + (nInfos - nSpans);
        if (k >= nInfos) continue;
        GSIconImageInfo stock = s->infos[k];
        if (stock.size.width <= 0 || stock.size.height <= 0) continue;
        // Calibrate against how stock maps its span to its size, then apply the new grid.
        CGFloat stockW = GSExtent(availW, oc, stockIcon, st.columns);
        CGFloat stockH = GSExtent(availH, orw, stockIcon, st.rows);
        CGFloat newW = stock.size.width * GSExtent(availW, cols, newIcon, w) / stockW;
        CGFloat maxH = stock.size.height * GSExtent(availH, rows, newIcon, h) / stockH;
        CGFloat aspect = stock.size.height / stock.size.width;   // keep Apple's shape
        CGFloat newH = newW * aspect;
        if (newH > maxH) { newW *= maxH / newH; newH = maxH; }
        newW = MIN(newW, availW);
        CGFloat f = newW / stock.size.width;
        infos[k].size = CGSizeMake(round(newW), round(newW * aspect));
        infos[k].continuousCornerRadius = stock.continuousCornerRadius * f;
    }
}

static void GSApply(id cfg, NSInteger cols, NSInteger rows, BOOL resize, BOOL widgets) {
    if (!cfg) return;
    NSUInteger oc = GSGetUInt(cfg, "numberOfPortraitColumns");
    NSUInteger orw = GSGetUInt(cfg, "numberOfPortraitRows");
    if (!oc || !orw) return;
    NSUInteger lc = GSGetUInt(cfg, "numberOfLandscapeColumns");
    NSUInteger lr = GSGetUInt(cfg, "numberOfLandscapeRows");
    BOOL swapped = lc && lr && lc == orw && lr == oc;   // iPad: landscape is portrait turned sideways
    GSStock stock;
    BOOL haveStock = widgets && GSReadStock(cfg, &stock);   // snapshot before we change anything

    if (rows <= 0) rows = orw;  // dock: keep its single row
    GSSetUInt(cfg, "setNumberOfPortraitColumns:", "_numberOfPortraitColumns", cols);
    GSSetUInt(cfg, "setNumberOfPortraitRows:", "_numberOfPortraitRows", rows);
    if (lc && lr) {
        GSSetUInt(cfg, "setNumberOfLandscapeColumns:", "_numberOfLandscapeColumns", swapped ? rows : cols);
        GSSetUInt(cfg, "setNumberOfLandscapeRows:", "_numberOfLandscapeRows", swapped ? cols : rows);
    }

    CGFloat newIcon = 0;
    if (resize && GSHasImageInfo(cfg)) {
        GSIconImageInfo info = ((GSIconImageInfo (*)(id, SEL))objc_msgSend)(cfg, sel_registerName("iconImageInfo"));
        if (info.size.width > 0) {
            // Fit: shrink by whichever direction got more crowded. Fewer apps per row can grow
            // icons, but only a little, so they never run into each other.
            CGFloat f = 1.0;
            if (gAutoSize) f = MIN(MIN((CGFloat)oc / cols, (CGFloat)orw / rows), 1.2);
            f *= gIconPercent / 100.0;
            if (fabs(f - 1.0) >= 0.001) {
                info.size = CGSizeMake(round(info.size.width * f), round(info.size.height * f));
                info.continuousCornerRadius *= f;
                ((void (*)(id, SEL, GSIconImageInfo))objc_msgSend)(cfg, sel_registerName("setIconImageInfo:"), info);
            }
            newIcon = info.size.width;
        }
    }
    if (haveStock && (cols != (NSInteger)oc || rows != (NSInteger)orw || newIcon != stock.infos[0].size.width)) {
        if (newIcon <= 0) newIcon = stock.infos[0].size.width;
        // setIconImageInfo: may have rewritten entry 0 of the table; keep it in step either way.
        GSApplyWidgets(cfg, &stock, oc, orw, cols, rows, newIcon);
    }
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
        if (GSIsHomeLocation(loc)) GSApply(cfg, gColumns, gRows, YES, gWidgets);
        else if (gDock && [loc isEqualToString:@"SBIconLocationDock"]) GSApply(cfg, gDockColumns, 0, YES, NO);
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
