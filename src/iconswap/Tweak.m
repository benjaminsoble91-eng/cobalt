// IconSwap 1.1 - in jiggle mode, tap one app and then another to swap them.
#import "../common/cb.h"

#define IS_DOMAIN CFSTR("com.mymculture.iconswap")
static BOOL gEnabled = YES, gHaptics = YES, gHighlight = YES, gHints = YES;

static __weak UIView *gSelected;
static UIView *gHighlightView;
static NSTimer *gTimer;
static char kTapKey;

static void ISClearSelection(void) {
    [gHighlightView removeFromSuperview];
    gHighlightView = nil;
    gSelected = nil;
    [gTimer invalidate];
    gTimer = nil;
}

static void ISLoadPrefs(void) {
    CFPreferencesAppSynchronize(IS_DOMAIN);
    gEnabled   = CBPrefBool(IS_DOMAIN, CFSTR("Enabled"), YES);
    gHaptics   = CBPrefBool(IS_DOMAIN, CFSTR("Haptics"), YES);
    gHighlight = CBPrefBool(IS_DOMAIN, CFSTR("Highlight"), YES);
    gHints     = CBPrefBool(IS_DOMAIN, CFSTR("Hints"), YES);
    if (!gEnabled) ISClearSelection();
    else if (!gHighlight) { [gHighlightView removeFromSuperview]; gHighlightView = nil; }
}

static void ISToast(UIView *anchor, NSString *msg, BOOL force) {
    if (!gHints && !force) return;
    UIWindow *win = anchor.window;
    if (!win) return;
    UILabel *l = [UILabel new];
    l.text = msg;
    l.numberOfLines = 0;
    l.textAlignment = NSTextAlignmentCenter;
    l.font = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
    l.textColor = [UIColor whiteColor];
    l.backgroundColor = [UIColor colorWithWhite:0 alpha:0.78];
    l.layer.cornerRadius = 12;
    l.layer.masksToBounds = YES;
    CGRect b = win.bounds;
    CGSize fit = [l sizeThatFits:CGSizeMake(b.size.width - 24 - 28, CGFLOAT_MAX)];
    CGFloat w = MIN(fit.width + 28, b.size.width - 24), h = fit.height + 18;
    l.frame = CGRectMake((b.size.width - w) * 0.5, win.safeAreaInsets.top + 56, w, h);
    l.alpha = 0;
    l.userInteractionEnabled = NO;
    [win addSubview:l];
    [UIView animateWithDuration:0.2 animations:^{ l.alpha = 1; } completion:^(BOOL f) {
        [UIView animateWithDuration:0.3 delay:1.6 options:0 animations:^{ l.alpha = 0; }
                         completion:^(BOOL f2) { [l removeFromSuperview]; }];
    }];
}

static BOOL ISEligible(UIView *v) {
    if (!gEnabled || !v) return NO;
    if (!CBSendBOOL(v, "isEditing")) return NO;
    id icon = CBSendID(v, "icon");
    if (!icon) return NO;
    if (CBSendBOOL(icon, "isFolderIcon")) return NO;
    if (CBSendBOOL(icon, "isWidgetIcon")) return NO;
    if (CBSendBOOL(icon, "isWidgetStackIcon")) return NO;
    return YES;
}

// ---- icon model helpers -------------------------------------------------
static NSArray *ISIcons(id list) {
    id a = CBSendID(list, "icons");
    return [a isKindOfClass:[NSArray class]] ? a : nil;
}
static BOOL ISListContains(id list, id icon) {
    SEL s = sel_registerName("directlyContainsIcon:");
    if ([list respondsToSelector:s]) return ((BOOL (*)(id, SEL, id))objc_msgSend)(list, s, icon);
    NSArray *a = ISIcons(list);
    return a && [a indexOfObjectIdenticalTo:icon] != NSNotFound;
}
// Find the list (page, dock, or a list inside a folder) that directly holds `icon`.
static id ISFindList(id folder, id icon, int depth) {
    if (!folder || depth > 4) return nil;
    NSMutableArray *lists = [NSMutableArray array];
    id ls = CBSendID(folder, "lists");
    if ([ls isKindOfClass:[NSArray class]]) [lists addObjectsFromArray:ls];
    id dock = CBSendID(folder, "dock");
    if (dock && [lists indexOfObjectIdenticalTo:dock] == NSNotFound) [lists addObject:dock];
    for (id list in lists) if (ISListContains(list, icon)) return list;
    for (id list in lists) {
        for (id i in ISIcons(list)) {
            if (!CBSendBOOL(i, "isFolderIcon")) continue;
            id found = ISFindList(CBSendID(i, "folder"), icon, depth + 1);
            if (found) return found;
        }
    }
    return nil;
}
static NSUInteger ISIndex(id list, id icon) {
    SEL s = sel_registerName("indexForIcon:");
    if ([list respondsToSelector:s]) return ((NSUInteger (*)(id, SEL, id))objc_msgSend)(list, s, icon);
    NSArray *a = ISIcons(list);
    return a ? [a indexOfObjectIdenticalTo:icon] : NSNotFound;
}
static NSUInteger ISCount(id list) { return ISIcons(list).count; }
static void ISRemove(id list, id icon) {
    ((void (*)(id, SEL, id))objc_msgSend)(list, sel_registerName("removeIcon:"), icon);
}
static void ISInsert(id list, id icon, NSUInteger idx) {
    NSUInteger n = ISCount(list);
    if (idx > n) idx = n;
    ((id (*)(id, SEL, id, NSUInteger))objc_msgSend)(list, sel_registerName("insertIcon:atIndex:"), icon, idx);
}

// Returns nil on success, or a short reason.
static NSString *ISSwap(id iconA, id iconB) {
    id ctrl = CBSendID(objc_getClass("SBIconController"), "sharedInstance");
    id mgr = CBSendID(ctrl, "iconManager") ?: ctrl;
    if (!mgr) return @"couldn't reach the icon manager";
    id root = CBSendID(mgr, "rootFolder");
    if (!root) return @"couldn't reach the root folder";
    id listA = ISFindList(root, iconA, 0), listB = ISFindList(root, iconB, 0);
    if (!listA || !listB) return @"couldn't find where one of the icons lives";
    SEL rm = sel_registerName("removeIcon:"), ins = sel_registerName("insertIcon:atIndex:");
    if (![listA respondsToSelector:rm] || ![listA respondsToSelector:ins] ||
        ![listB respondsToSelector:rm] || ![listB respondsToSelector:ins])
        return @"this iOS version uses different list methods";
    NSUInteger ia = ISIndex(listA, iconA), ib = ISIndex(listB, iconB);
    if (ia == NSNotFound || ib == NSNotFound) return @"couldn't read the icon positions";

    if (listA == listB) {
        // take out the later one first so the earlier index stays valid
        id first = ia < ib ? iconA : iconB, second = ia < ib ? iconB : iconA;
        NSUInteger lo = MIN(ia, ib), hi = MAX(ia, ib);
        ISRemove(listA, second);
        ISRemove(listA, first);
        ISInsert(listA, second, lo);
        ISInsert(listA, first, hi);
    } else {
        ISRemove(listA, iconA);
        ISRemove(listB, iconB);
        ISInsert(listA, iconB, ia);
        ISInsert(listB, iconA, ib);
    }

    SEL lay = sel_registerName("layoutIconListsWithAnimationType:forceRelayout:");
    if ([mgr respondsToSelector:lay]) ((void (*)(id, SEL, NSInteger, BOOL))objc_msgSend)(mgr, lay, 0, YES);
    id model = CBSendID(mgr, "iconModel");
    SEL dirty = sel_registerName("setIconStateDirty:");
    if ([model respondsToSelector:dirty]) ((void (*)(id, SEL, BOOL))objc_msgSend)(model, dirty, YES);
    SEL save = sel_registerName("saveIconStateIfNeeded");
    if ([model respondsToSelector:save]) ((void (*)(id, SEL))objc_msgSend)(model, save);
    return nil;
}

// ---- selection ----------------------------------------------------------
static void ISSelect(UIView *v) {
    ISClearSelection();
    gSelected = v;
    if (gHighlight) {
        CGRect r = CGRectZero;
        SEL fs = sel_registerName("iconImageFrame");
        if ([v respondsToSelector:fs]) r = ((CGRect (*)(id, SEL))objc_msgSend)(v, fs);
        if (CGRectIsEmpty(r)) {
            CGFloat w = v.bounds.size.width, h = v.bounds.size.height, side = MIN(w, h);
            r = CGRectMake((w - side) * 0.5, 0, side, side);
        }
        UIView *hl = [[UIView alloc] initWithFrame:CGRectInset(r, -4, -4)];
        hl.userInteractionEnabled = NO;
        UIColor *c = [UIColor colorWithRed:0.235 green:0.47 blue:1 alpha:1];
        hl.backgroundColor = [c colorWithAlphaComponent:0.25];
        hl.layer.borderColor = c.CGColor;
        hl.layer.borderWidth = 3;
        hl.layer.cornerRadius = hl.bounds.size.width * 0.235;
        [v addSubview:hl];
        gHighlightView = hl;
    }
    // drop the selection by itself once jiggle mode ends or the icon goes away
    gTimer = [NSTimer scheduledTimerWithTimeInterval:0.5 repeats:YES block:^(NSTimer *t) {
        UIView *s = gSelected;
        if (!s || !s.window || !CBSendBOOL(s, "isEditing")) ISClearSelection();
    }];
    ISToast(v, @"IconSwap: now tap another app to swap them", NO);
    if (gHaptics) [[UISelectionFeedbackGenerator new] selectionChanged];
}

@interface ISTapHandler : NSObject <UIGestureRecognizerDelegate>
@end
@implementation ISTapHandler
+ (instancetype)shared {
    static ISTapHandler *h; static dispatch_once_t once;
    dispatch_once(&once, ^{ h = [ISTapHandler new]; });
    return h;
}
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gr shouldReceiveTouch:(UITouch *)touch {
    @try {
        UIView *iconView = gr.view;
        if (!ISEligible(iconView)) return NO;
        // leave the delete badge and other controls alone
        for (UIView *v = touch.view; v && v != iconView; v = v.superview) {
            NSString *n = NSStringFromClass([v class]);
            if ([v isKindOfClass:[UIControl class]] || [n containsString:@"CloseBox"] ||
                [n containsString:@"Accessory"] || [n containsString:@"Button"]) return NO;
        }
        return YES;
    } @catch (__unused NSException *e) { return NO; }
}
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)a shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)b {
    return YES;
}
- (void)tapped:(UITapGestureRecognizer *)gr {
    if (gr.state != UIGestureRecognizerStateEnded) return;
    UIView *v = gr.view;
    if (!ISEligible(v)) return;
    UIView *sel = gSelected;
    if (!sel || !sel.window || !CBSendBOOL(sel, "isEditing")) { ISSelect(v); return; }
    if (sel == v) { ISClearSelection(); return; }
    @try {
        id a = CBSendID(sel, "icon"), b = CBSendID(v, "icon");
        ISClearSelection();
        NSString *err = (a && b) ? ISSwap(a, b) : @"couldn't read the icons";
        if (err) {
            ISToast(v, [NSString stringWithFormat:@"IconSwap: %@", err], YES);
            if (gHaptics) [[UINotificationFeedbackGenerator new] notificationOccurred:UINotificationFeedbackTypeError];
        } else if (gHaptics) {
            [[[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium] impactOccurred];
        }
    } @catch (NSException *e) {
        ISClearSelection();
        ISToast(v, [NSString stringWithFormat:@"IconSwap error: %@", e.reason ?: e.name], YES);
    }
}
@end

static void ISInstall(void) {
    static BOOL done; if (done) return;
    Class cls = objc_getClass("SBIconView");
    SEL sel = sel_registerName("setIcon:");
    if (!cls || !class_getInstanceMethod(cls, sel)) return;
    done = YES;
    __block IMP orig = NULL;
    orig = CBHook(cls, sel, ^(UIView *self, id icon) {
        ((void (*)(id, SEL, id))orig)(self, sel, icon);
        @try {
            if (![self isKindOfClass:[UIView class]] || objc_getAssociatedObject(self, &kTapKey)) return;
            UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:[ISTapHandler shared] action:@selector(tapped:)];
            tap.delegate = [ISTapHandler shared];
            tap.cancelsTouchesInView = NO;
            tap.delaysTouchesEnded = NO;
            [self addGestureRecognizer:tap];
            objc_setAssociatedObject(self, &kTapKey, tap, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        } @catch (__unused NSException *e) {}
    });
}

static void ISPrefsChanged(CFNotificationCenterRef c, void *o, CFStringRef n, const void *obj, CFDictionaryRef i) {
    dispatch_async(dispatch_get_main_queue(), ^{ ISLoadPrefs(); });
}

__attribute__((constructor)) static void ISInit(void) {
    @autoreleasepool {
        if (!CBIsSpringBoard()) return;
        ISLoadPrefs();
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, ISPrefsChanged,
                                        CFSTR("com.mymculture.iconswap/prefs"), NULL,
                                        CFNotificationSuspensionBehaviorDeliverImmediately);
        ISInstall();
        [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidFinishLaunchingNotification object:nil
                                                           queue:[NSOperationQueue mainQueue]
                                                      usingBlock:^(NSNotification *n) { ISInstall(); }];
    }
}
