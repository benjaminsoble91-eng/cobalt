// BarText 1.0.2 - replace status bar pieces (carrier name, cellular bars, network badge, Wi-Fi bars) with your own text.
//
// Settings live in SpringBoard's reach only, and the status bar is drawn inside every app, so SpringBoard
// publishes the settings through notify(3) state slots, which sandboxed apps are allowed to read.
#import "../common/cb.h"
#import <fcntl.h>
#import <signal.h>

#define BT_DOMAIN  CFSTR("com.mymculture.bartext")
#define BT_PREFS   "com.mymculture.bartext/prefs"     // posted by Settings
#define BT_CHANGED "com.mymculture.bartext/changed"   // posted by SpringBoard after publishing
#define BT_SLOT    "com.mymculture.bartext.slot%d"
#define BT_SLOTS   96                                 // 96 x 8 bytes; slot 0 holds the length

static NSString *const kCarrier = @"carrier", *const kCellBars = @"cellbars", *const kNetType = @"nettype", *const kWifiBars = @"wifibars";
static NSDictionary *gPrefs;           // role -> replacement text (present only when that override is on)
static char kRoleKey, kOrigTextKey, kLabelKey;
static NSHashTable *gViews;            // weak set of views we've tagged
static Class gStringCls, gSignalCls;
static BOOL gIsSB, gHooked, gTripped, gGuardOver, gSkipPublish;

// ---- crash guard ----------------------------------------------------------
// While SpringBoard is starting up with BarText active, a small breadcrumb file says so.
// 1.0.2: only a real crash (a fault signal or abort) inside the guard window marks the
// breadcrumb "crashed". A respring, userspace reboot or kill leaves it unmarked, so it no
// longer switches BarText off. After a real crash BarText stays off until a setting changes.
#define BT_CRUMB "/var/mobile/Library/Caches/com.mymculture.bartext.crumb"
#define BT_GUARD_SECONDS 30
static void BTCrumbWrite(const char *text) {
    FILE *f = fopen(BT_CRUMB, "w");
    if (f) { fputs(text, f); fclose(f); }
}
static NSString *BTCrumbRead(void) {
    NSString *s = [NSString stringWithContentsOfFile:@BT_CRUMB encoding:NSUTF8StringEncoding error:nil];
    return s.length ? s : nil;
}
// What the crash handler writes. Fixed strings so the handler never formats anything.
static const char *const kCrashText[] = { "crashed in visit", "crashed in settext", "crashed in signal", "crashed in size",
                                          "crashed in refresh", "crashed in hooks", "crashed in publish",
                                          "crashed while loading", "crashed between steps" };
enum { kCrashLoading = 7, kCrashBetween = 8 };
static volatile int gCrashIdx = kCrashLoading;
static const int kSignals[] = { SIGSEGV, SIGBUS, SIGILL, SIGABRT, SIGTRAP, SIGFPE, SIGSYS };
#define BT_NSIG (sizeof kSignals / sizeof kSignals[0])
static struct sigaction gOldAct[BT_NSIG];
static BOOL gHandlersOn;
static void BTCrashHandler(int sig, siginfo_t *info, void *uctx) {
    int idx = gCrashIdx; if (idx < 0 || idx > 8) idx = kCrashBetween;
    const char *t = kCrashText[idx];
    int fd = open(BT_CRUMB, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (fd >= 0) { size_t n = 0; while (t[n]) n++; write(fd, t, n); close(fd); }
    // hand the signal back to whoever had it before (crash reporter / tweak loader);
    // a fault re-triggers on return, abort() raises again by itself
    for (unsigned i = 0; i < BT_NSIG; i++) if (kSignals[i] == sig) { sigaction(sig, &gOldAct[i], NULL); return; }
    signal(sig, SIG_DFL);
}
static void BTCrashHandlersOn(void) {
    if (gHandlersOn) return;
    for (unsigned i = 0; i < BT_NSIG; i++) {
        struct sigaction sa; memset(&sa, 0, sizeof sa);
        sa.sa_sigaction = BTCrashHandler; sa.sa_flags = SA_SIGINFO | SA_ONSTACK; sigemptyset(&sa.sa_mask);
        sigaction(kSignals[i], &sa, &gOldAct[i]);
    }
    gHandlersOn = YES;
}
static void BTCrashHandlersOff(void) {
    if (!gHandlersOn) return;
    for (unsigned i = 0; i < BT_NSIG; i++) {
        struct sigaction cur;
        // only put the old handler back if nobody replaced ours in the meantime
        if (sigaction(kSignals[i], NULL, &cur) == 0 && (cur.sa_flags & SA_SIGINFO) && cur.sa_sigaction == BTCrashHandler)
            sigaction(kSignals[i], &gOldAct[i], NULL);
    }
    gHandlersOn = NO;
}

static void BTStep(int step, BOOL enter) {
    static const char *names[] = { "visit", "settext", "signal", "size", "refresh", "hooks", "publish" };
    static int counts[7];
    if (!gIsSB || gGuardOver || gTripped || step < 0 || step > 6) return;
    gCrashIdx = enter ? step : kCrashBetween;
    if (enter) { if (counts[step] >= 5) return; counts[step]++; }
    char buf[48];
    if (enter) snprintf(buf, sizeof buf, "in %s", names[step]); else snprintf(buf, sizeof buf, "between steps");
    BTCrumbWrite(buf);
}
enum { kStepVisit, kStepSetText, kStepSignal, kStepSize, kStepRefresh, kStepHooks, kStepPublish };
static void BTSetStatus(NSString *status) {
    if (!gIsSB) return;
    CFPreferencesSetAppValue(CFSTR("Status"), (__bridge CFStringRef)status, BT_DOMAIN);
    CFPreferencesAppSynchronize(BT_DOMAIN);
}

// ---- settings transport -------------------------------------------------
static int BTToken(int slot) {
    static int tokens[BT_SLOTS]; static BOOL have[BT_SLOTS];
    if (slot < 0 || slot >= BT_SLOTS) return -1;
    if (!have[slot]) {
        char name[64]; snprintf(name, sizeof name, BT_SLOT, slot);
        if (notify_register_check(name, &tokens[slot]) != NOTIFY_STATUS_OK) return -1;
        have[slot] = YES;
    }
    return tokens[slot];
}

static void BTPublish(NSDictionary *d) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:d ?: @{} options:0 error:nil];
    NSUInteger max = (BT_SLOTS - 1) * 8;
    if (!data || data.length > max) data = [@"{}" dataUsingEncoding:NSUTF8StringEncoding];
    const uint8_t *b = data.bytes; NSUInteger n = data.length;
    notify_set_state(BTToken(0), 0);   // mark as being rewritten
    for (NSUInteger i = 0; i * 8 < n; i++) {
        uint64_t v = 0; memcpy(&v, b + i * 8, MIN((NSUInteger)8, n - i * 8));
        notify_set_state(BTToken((int)i + 1), v);
    }
    notify_set_state(BTToken(0), (uint64_t)n);
    notify_post(BT_CHANGED);
}

static NSDictionary *BTReadPublished(void) {
    uint64_t n = 0;
    if (BTToken(0) < 0 || notify_get_state(BTToken(0), &n) != NOTIFY_STATUS_OK) return nil;
    if (n == 0 || n > (BT_SLOTS - 1) * 8) return nil;
    NSMutableData *data = [NSMutableData dataWithLength:(NSUInteger)n];
    uint8_t *b = data.mutableBytes;
    for (NSUInteger i = 0; i * 8 < n; i++) {
        uint64_t v = 0;
        if (notify_get_state(BTToken((int)i + 1), &v) != NOTIFY_STATUS_OK) return nil;
        memcpy(b + i * 8, &v, MIN((NSUInteger)8, (NSUInteger)n - i * 8));
    }
    id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    return [obj isKindOfClass:[NSDictionary class]] ? obj : nil;
}

static NSString *BTPrefString(CFStringRef key) {
    CFPropertyListRef v = CFPreferencesCopyAppValue(key, BT_DOMAIN);
    NSString *s = nil;
    if (v && CFGetTypeID(v) == CFStringGetTypeID()) s = [(__bridge NSString *)v copy];
    if (v) CFRelease(v);
    return s ?: @"";
}

// SpringBoard only: read the real settings and boil them down to role -> text.
static NSDictionary *BTReadSettings(void) {
    CFPreferencesAppSynchronize(BT_DOMAIN);
    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    if (!CBPrefBool(BT_DOMAIN, CFSTR("Enabled"), YES)) return d;
    struct { CFStringRef on, text; NSString *role; } rows[] = {
        { CFSTR("CarrierOn"),  CFSTR("CarrierText"),  kCarrier },
        { CFSTR("CellBarsOn"), CFSTR("CellBarsText"), kCellBars },
        { CFSTR("NetTypeOn"),  CFSTR("NetTypeText"),  kNetType },
        { CFSTR("WifiBarsOn"), CFSTR("WifiBarsText"), kWifiBars },
    };
    for (int i = 0; i < 4; i++) {
        if (!CBPrefBool(BT_DOMAIN, rows[i].on, NO)) continue;
        NSString *t = BTPrefString(rows[i].text);
        if (t.length > 40) t = [t substringToIndex:40];
        d[rows[i].role] = t;
    }
    return d;
}

static NSString *BTOverride(NSString *role) { return role ? gPrefs[role] : nil; }

// ---- applying to views --------------------------------------------------
static UIColor *BTColor(UIView *v) {
    @try {
        SEL s = sel_registerName("activeColor");
        if ([v respondsToSelector:s]) { id c = ((id (*)(id, SEL))objc_msgSend)(v, s); if ([c isKindOfClass:[UIColor class]]) return c; }
    } @catch (__unused NSException *e) {}
    return v.tintColor ?: [UIColor whiteColor];
}

// Signal views (bars): hide the bars and show a label in their place.
static void BTApplySignal(UIView *v) {
    NSString *text = BTOverride(objc_getAssociatedObject(v, &kRoleKey));
    UILabel *lab = objc_getAssociatedObject(v, &kLabelKey);
    if (!text) {
        if (lab) {
            [lab removeFromSuperview];
            objc_setAssociatedObject(v, &kLabelKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            for (CALayer *l in v.layer.sublayers) l.hidden = NO;
        }
        return;
    }
    if (!lab) {
        lab = [UILabel new];
        lab.font = [UIFont systemFontOfSize:12 weight:UIFontWeightSemibold];
        lab.userInteractionEnabled = NO;
        objc_setAssociatedObject(v, &kLabelKey, lab, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (lab.superview != v) [v addSubview:lab];
    if (![lab.text isEqualToString:text]) lab.text = text;
    lab.textColor = BTColor(v);
    CGSize s = [lab sizeThatFits:CGSizeMake(CGFLOAT_MAX, CGFLOAT_MAX)];
    CGRect f = CGRectMake(0, floor((v.bounds.size.height - s.height) * 0.5), ceil(s.width), ceil(s.height));
    if (!CGRectEqualToRect(lab.frame, f)) lab.frame = f;
    for (CALayer *l in v.layer.sublayers) if (l != lab.layer && !l.hidden) l.hidden = YES;
}

static CGSize BTSignalSize(UIView *v, CGSize orig) {
    NSString *text = BTOverride(objc_getAssociatedObject(v, &kRoleKey));
    if (!text) return orig;
    if (text.length == 0) return CGSizeMake(0, orig.height);
    CGSize s = [text sizeWithAttributes:@{ NSFontAttributeName: [UIFont systemFontOfSize:12 weight:UIFontWeightSemibold] }];
    return CGSizeMake(ceil(s.width), MAX(orig.height, ceil(s.height)));
}

static void BTRefreshView(UIView *v) {
    @try {
        if (gStringCls && [v isKindOfClass:gStringCls]) {
            NSString *orig = objc_getAssociatedObject(v, &kOrigTextKey) ?: ((UILabel *)v).text;
            ((UILabel *)v).text = orig;      // goes back through our setText: hook
        } else {
            [v invalidateIntrinsicContentSize];
            [v setNeedsLayout];
            BTApplySignal(v);
        }
        [v.superview setNeedsLayout];
    } @catch (__unused NSException *e) {}
}

static void BTTag(UIView *v, NSString *role) {
    if (!v || !role) return;
    if (![objc_getAssociatedObject(v, &kRoleKey) isEqual:role]) {
        objc_setAssociatedObject(v, &kRoleKey, role, OBJC_ASSOCIATION_COPY_NONATOMIC);
        [gViews addObject:v];
    }
}
static void BTTagStrings(UIView *v, NSString *role, int depth) {
    if (!v || depth > 4) return;
    if ([v isKindOfClass:gStringCls]) BTTag(v, role);
    for (UIView *s in v.subviews) BTTagStrings(s, role, depth + 1);
}

static NSString *BTRoleFor(id item, id displayItem) {
    NSString *cls = NSStringFromClass([item class]);
    BOOL cell = [cls containsString:@"Cellular"], wifi = [cls containsString:@"Wifi"];
    if (!cell && !wifi) return nil;
    id ident = CBIvar(displayItem, "_identifier") ?: CBSendID(displayItem, "identifier");
    NSString *s = CBIvar(ident, "_string");
    if (![s isKindOfClass:[NSString class]]) s = [ident description];
    s = s.lowercaseString;
    if (!s) return nil;
    if ([s containsString:@"signalstrength"]) return cell ? kCellBars : kWifiBars;
    if (!cell) return nil;
    if ([s containsString:@"name"]) return kCarrier;
    if ([s containsString:@"type"]) return kNetType;
    return nil;
}

static void BTVisit(id item, id displayItem, BOOL after) {
    NSString *role = BTRoleFor(item, displayItem);
    if (!role) return;
    if (!BTOverride(role) && gViews.count == 0) return;  // nothing switched on for this piece
    UIView *view = CBIvar(displayItem, "_view");         // never force a view into existence
    if (![view isKindOfClass:[UIView class]]) {
        // only ask for the view of an item the status bar is already showing
        if (!after || !CBSendBOOL(displayItem, "isEnabled")) return;
        view = CBSendID(displayItem, "view");
        if (![view isKindOfClass:[UIView class]]) return;
    }
    if (role == kCellBars || role == kWifiBars) {
        if (gSignalCls && [view isKindOfClass:gSignalCls]) {
            BOOL had = objc_getAssociatedObject(view, &kLabelKey) != nil;
            if (!BTOverride(role) && !had) return;
            BTTag(view, role);
            if (after) {
                BOOL fresh = !had || ![((UILabel *)objc_getAssociatedObject(view, &kLabelKey)).text isEqualToString:BTOverride(role) ?: @""];
                BTApplySignal(view);
                if (fresh) [view invalidateIntrinsicContentSize];
            }
        }
        return;
    }
    if (!BTOverride(role)) return;
    BTTagStrings(view, role, 0);
    if (!after) return;
    NSString *want = BTOverride(role);
    if (!want) return;
    for (UIView *v in gViews.allObjects)
        if ([v isKindOfClass:gStringCls] && [objc_getAssociatedObject(v, &kRoleKey) isEqual:role] &&
            [v isDescendantOfView:view] && ![((UILabel *)v).text ?: @"" isEqualToString:want])
            BTRefreshView(v);
}

static void BTHookApply(Class cls) {
    SEL sel = sel_registerName("applyUpdate:toDisplayItem:");
    if (!cls) return;
    // only where the class has its own implementation, so each override is wrapped exactly once
    unsigned int n = 0; Method *ms = class_copyMethodList(cls, &n); BOOL own = NO;
    for (unsigned int i = 0; i < n; i++) if (method_getName(ms[i]) == sel) own = YES;
    free(ms);
    if (!own) return;
    __block IMP orig = NULL;
    orig = CBHook(cls, sel, ^id(id self, id update, id displayItem) {
        id r = ((id (*)(id, SEL, id, id))orig)(self, sel, update, displayItem);
        if (gPrefs.count || gViews.count) {
            BTStep(kStepVisit, YES);
            @try { BTVisit(self, displayItem, YES); } @catch (__unused NSException *e) {}
            BTStep(kStepVisit, NO);
        }
        return r;
    });
}

static void BTInstallHooks(void) {
    if (gHooked) return;
    gHooked = YES;
    BTStep(kStepHooks, YES);

    // text pieces
    SEL setText = @selector(setText:);
    __block IMP origSet = NULL;
    origSet = CBHook(gStringCls, setText, ^(UILabel *self, NSString *text) {
        NSString *role = objc_getAssociatedObject(self, &kRoleKey);
        if (role) {
            BTStep(kStepSetText, YES);
            if (text == nil || [text isKindOfClass:[NSString class]])
                objc_setAssociatedObject(self, &kOrigTextKey, text, OBJC_ASSOCIATION_COPY_NONATOMIC);
            NSString *o = BTOverride(role);
            if (o) text = o;
            BTStep(kStepSetText, NO);
        }
        ((void (*)(id, SEL, id))origSet)(self, setText, text);
    });

    // bars
    for (NSString *name in @[ @"_UIStatusBarCellularSignalView", @"_UIStatusBarWifiSignalView" ]) {
        Class c = objc_getClass(name.UTF8String);
        if (!c) continue;
        SEL lay = @selector(layoutSubviews);
        __block IMP origLay = NULL;
        origLay = CBHook(c, lay, ^(UIView *self) {
            ((void (*)(id, SEL))origLay)(self, lay);
            if (objc_getAssociatedObject(self, &kRoleKey)) {
                BTStep(kStepSignal, YES);
                @try { BTApplySignal(self); } @catch (__unused NSException *e) {}
                BTStep(kStepSignal, NO);
            }
        });
        SEL ics = @selector(intrinsicContentSize);
        __block IMP origSize = NULL;
        origSize = CBHook(c, ics, ^CGSize(UIView *self) {
            CGSize s = ((CGSize (*)(id, SEL))origSize)(self, ics);
            if (objc_getAssociatedObject(self, &kRoleKey)) {
                BTStep(kStepSize, YES);
                @try { s = BTSignalSize(self, s); } @catch (__unused NSException *e) {}
                BTStep(kStepSize, NO);
            }
            return s;
        });
    }

    // find out which view is which as the status bar updates them
    for (NSString *name in @[ @"_UIStatusBarItem", @"_UIStatusBarCellularItem", @"_UIStatusBarCellularCondensedItem",
                              @"_UIStatusBarCellularExpandedItem", @"_UIStatusBarWifiItem" ])
        BTHookApply(objc_getClass(name.UTF8String));
    BTStep(kStepHooks, NO);
}

// userChanged: a setting was just changed in Settings (that is what re-arms BarText after a crash).
static void BTReload(BOOL userChanged) {
    NSDictionary *d;
    if (gIsSB) {
        if (gTripped && userChanged) {
            gTripped = NO; gSkipPublish = NO;
            unlink(BT_CRUMB);
        }
        d = gTripped ? @{} : BTReadSettings();
        if (!gSkipPublish) {
            BTStep(kStepPublish, YES);
            BTPublish(d);
            BTStep(kStepPublish, NO);
        }
        if (!gTripped) BTSetStatus(d.count ? @"Running" : @"Idle (nothing switched on)");
    } else {
        d = BTReadPublished();
    }
    gPrefs = [d copy] ?: @{};
    if (gPrefs.count && !gHooked) {
        if (gIsSB && !gGuardOver) {
            BTCrumbWrite("between steps");
            gCrashIdx = kCrashBetween;
            BTCrashHandlersOn();
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(BT_GUARD_SECONDS * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                gGuardOver = YES;
                BTCrashHandlersOff();
                BTCrumbWrite("ok");
            });
        }
        BTInstallHooks();
    }
    if (!gHooked) return;
    BTStep(kStepRefresh, YES);
    for (UIView *v in gViews.allObjects) BTRefreshView(v);
    BTStep(kStepRefresh, NO);
}

static void BTNote(CFNotificationCenterRef c, void *o, CFStringRef n, const void *obj, CFDictionaryRef i) {
    BOOL user = n && CFEqual(n, CFSTR(BT_PREFS));
    dispatch_async(dispatch_get_main_queue(), ^{ BTReload(user); });
}

__attribute__((constructor)) static void BTInit(void) {
    @autoreleasepool {
        NSString *path = [[NSBundle mainBundle] bundlePath];
        if (![path hasSuffix:@".app"]) return;                      // apps and SpringBoard only
        gStringCls = objc_getClass("_UIStatusBarStringView");
        gSignalCls = objc_getClass("_UIStatusBarSignalView");
        if (!gStringCls || !objc_getClass("_UIStatusBarItem")) return;
        gViews = [NSHashTable weakObjectsHashTable];
        gIsSB = CBIsSpringBoard();

        if (gIsSB) {
            NSString *crumb = BTCrumbRead();
            if ([crumb hasPrefix:@"crashed"]) {
                gTripped = YES;       // SpringBoard went down last time while BarText was starting up
                gSkipPublish = [crumb containsString:@"loading"] || [crumb containsString:@"publish"];
                BTSetStatus([NSString stringWithFormat:@"Off after crash (%@)", crumb]);
            } else {
                BTCrumbWrite("loading");
                gCrashIdx = kCrashLoading;
                BTCrashHandlersOn();      // removed again once the guard window ends
            }
        }

        CFNotificationCenterRef dc = CFNotificationCenterGetDarwinNotifyCenter();
        if (gIsSB)
            CFNotificationCenterAddObserver(dc, NULL, BTNote, CFSTR(BT_PREFS), NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
        else
            CFNotificationCenterAddObserver(dc, NULL, BTNote, CFSTR(BT_CHANGED), NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
        BTReload(NO);
        if (gIsSB && !gTripped && !gHooked) { BTCrashHandlersOff(); BTCrumbWrite("ok"); }   // loaded fine with nothing switched on
    }
}
