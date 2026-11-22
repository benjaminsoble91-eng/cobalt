// Freefall 1.0 - drop your Home Screen icons into a real physics world.
// Shake the device on the Home Screen (or optionally double-tap it) and every visible icon
// falls with gravity, follows the tilt of the device, bounces off the edges and each
// other, and can be grabbed and flicked. Tap an icon to open its app. Double-tap empty
// space or press Home to send everything home.
#import "../common/cb.h"
#import <CoreMotion/CoreMotion.h>

#define FF_DOMAIN CFSTR("com.mymculture.freefall")

static BOOL gEnabled = YES, gTilt = YES, gDock = YES, gLabels = NO, gHaptics = YES, gShake = YES, gRotate = YES;
static NSInteger gFingers = 2, gTrigger = 0; // trigger: 0 shake, 1 double-tap, 2 both
static CGFloat gSensitivity = 0.5;
static CGFloat gGravity = 1.0, gBounce = 0.55, gFriction = 0.3;

static CGFloat FFPrefFloat(CFStringRef key, CGFloat def) {
    CFPropertyListRef v = CFPreferencesCopyAppValue(key, FF_DOMAIN);
    CGFloat r = def;
    if (v) {
        if (CFGetTypeID(v) == CFNumberGetTypeID()) { double d = def; CFNumberGetValue((CFNumberRef)v, kCFNumberDoubleType, &d); r = d; }
        else if (CFGetTypeID(v) == CFStringGetTypeID()) r = [(__bridge NSString *)v doubleValue];
        CFRelease(v);
    }
    return r;
}

@class FFWorld;
static FFWorld *gWorld;
static void FFStop(BOOL animated);

static void FFLoadPrefs(void) {
    CFPreferencesAppSynchronize(FF_DOMAIN);
    gEnabled  = CBPrefBool(FF_DOMAIN, CFSTR("Enabled"), YES);
    gTilt     = CBPrefBool(FF_DOMAIN, CFSTR("Tilt"), YES);
    gDock     = CBPrefBool(FF_DOMAIN, CFSTR("Dock"), YES);
    gLabels   = CBPrefBool(FF_DOMAIN, CFSTR("Labels"), NO);
    gHaptics  = CBPrefBool(FF_DOMAIN, CFSTR("Haptics"), YES);
    gShake    = CBPrefBool(FF_DOMAIN, CFSTR("Shake"), YES);
    gRotate   = CBPrefBool(FF_DOMAIN, CFSTR("Rotate"), YES);
    gFingers  = (NSInteger)FFPrefFloat(CFSTR("Fingers"), 2);
    if (gFingers < 1 || gFingers > 4) gFingers = 2;
    gTrigger  = (NSInteger)FFPrefFloat(CFSTR("Trigger"), 0);
    if (gTrigger < 0 || gTrigger > 2) gTrigger = 0;
    gSensitivity = MAX(0.0, MIN(1.0, FFPrefFloat(CFSTR("Sensitivity"), 0.5)));
    gGravity  = MAX(0.1, MIN(5.0, FFPrefFloat(CFSTR("Gravity"), 1.0)));
    gBounce   = MAX(0.0, MIN(1.0, FFPrefFloat(CFSTR("Bounce"), 0.55)));
    gFriction = MAX(0.0, MIN(1.0, FFPrefFloat(CFSTR("Friction"), 0.3)));
    if (!gEnabled) FFStop(NO);
}
static void FFWatchTick(void);

// ---- SpringBoard state ---------------------------------------------------
static BOOL FFHomeScreenIsUp(void) {
    UIApplication *app = [UIApplication sharedApplication];
    if (CBSendID(app, "_accessibilityFrontMostApplication")) return NO;
    id lsm = CBSendID(objc_getClass("SBLockScreenManager"), "sharedInstance");
    if (CBSendBOOL(lsm, "isUILocked")) return NO;
    id ctrl = CBSendID(objc_getClass("SBIconController"), "sharedInstance");
    id mgr = CBSendID(ctrl, "iconManager");
    if (CBSendBOOL(mgr, "isEditing") || CBSendBOOL(ctrl, "isEditing")) return NO;
    return YES;
}

static BOOL FFVisible(UIView *v, UIWindow *win) {
    CGFloat alpha = 1;
    for (UIView *p = v; p; p = p.superview) {
        if (p.hidden) return NO;
        alpha *= p.alpha;
        if (alpha < 0.05) return NO;
        if (p == win) break;
    }
    CGRect r = [v convertRect:v.bounds toView:win];
    if (CGRectIsEmpty(r) || r.size.width < 8) return NO;
    CGPoint c = CGPointMake(CGRectGetMidX(r), CGRectGetMidY(r));
    return CGRectContainsPoint(win.bounds, c);
}

static BOOL FFInDock(UIView *v) {
    for (UIView *p = v.superview; p; p = p.superview) {
        if ([NSStringFromClass([p class]) containsString:@"Dock"]) return YES;
    }
    return NO;
}

static void FFCollectIconViews(UIView *root, UIWindow *win, Class iconCls, NSMutableArray *out) {
    if (root.hidden || root.alpha < 0.05) return;
    if (iconCls && [root isKindOfClass:iconCls]) {
        if (CBSendID(root, "icon") && FFVisible(root, win) && (gDock || !FFInDock(root))) [out addObject:root];
        return; // never descend into an icon view (folder icons hold mini icons)
    }
    for (UIView *s in root.subviews) FFCollectIconViews(s, win, iconCls, out);
}

static UIView *FFImageViewOf(UIView *iconView) {
    if (gLabels) return iconView;
    UIView *v = CBSendID(iconView, "_iconImageView");
    if (![v isKindOfClass:[UIView class]]) v = CBSendID(iconView, "iconImageView");
    if (![v isKindOfClass:[UIView class]]) v = CBIvar(iconView, "_iconImageView");
    if (![v isKindOfClass:[UIView class]] || v.bounds.size.width < 8) return iconView;
    return v;
}

static NSString *FFBundleID(UIView *iconView) {
    id icon = CBSendID(iconView, "icon");
    if (CBSendBOOL(icon, "isFolderIcon")) return nil;
    const char *names[] = {"applicationBundleID", "bundleIdentifier"};
    for (int i = 0; i < 2; i++) {
        id b = CBSendID(icon, names[i]);
        if ([b isKindOfClass:[NSString class]] && [b length]) return b;
    }
    id app = CBSendID(icon, "application");
    id b = CBSendID(app, "bundleIdentifier");
    return [b isKindOfClass:[NSString class]] ? b : nil;
}

static void FFLaunch(NSString *bid) {
    if (!bid) return;
    UIApplication *app = [UIApplication sharedApplication];
    SEL s = sel_registerName("launchApplicationWithIdentifier:suspended:");
    if ([app respondsToSelector:s]) {
        ((BOOL (*)(id, SEL, id, BOOL))objc_msgSend)(app, s, bid, NO);
        return;
    }
    id ws = CBSendID(objc_getClass("LSApplicationWorkspace"), "defaultWorkspace");
    SEL o = sel_registerName("openApplicationWithBundleID:");
    if ([ws respondsToSelector:o]) ((BOOL (*)(id, SEL, id))objc_msgSend)(ws, o, bid);
}

// ---- the physics world ---------------------------------------------------
@interface FFBody : NSObject
@property (nonatomic, strong) UIView *view;       // snapshot that moves around
@property (nonatomic, weak) UIView *original;     // the real SBIconView
@property (nonatomic, assign) CGFloat originalAlpha;
@property (nonatomic, assign) CGPoint homeCenter; // where it lives on the Home Screen (overlay coords)
@property (nonatomic, copy) NSString *bundleID;
@property (nonatomic, strong) UIAttachmentBehavior *drag;
@end
@implementation FFBody
@end

@interface FFOverlay : UIView
@property (nonatomic, copy) void (^onLayout)(void);
@end
@implementation FFOverlay
- (void)layoutSubviews { [super layoutSubviews]; if (self.onLayout) self.onLayout(); }
@end

@interface FFWorld : NSObject <UICollisionBehaviorDelegate, UIGestureRecognizerDelegate>
@property (nonatomic, strong) FFOverlay *overlay;
@property (nonatomic, strong) NSMutableArray<FFBody *> *bodies;
@property (nonatomic, strong) UIDynamicAnimator *animator;
@property (nonatomic, strong) UIGravityBehavior *gravity;
@property (nonatomic, strong) UICollisionBehavior *collision;
@property (nonatomic, strong) UIDynamicItemBehavior *material;
@property (nonatomic, strong) CMMotionManager *motion;
@property (nonatomic, strong) NSTimer *watchdog;
@property (nonatomic, strong) UIImpactFeedbackGenerator *thud;
@property (nonatomic, assign) CFTimeInterval lastThud, lastShake;
@property (nonatomic, assign) CGSize lastSize;
@property (nonatomic, assign) BOOL stopping;
@end

@implementation FFWorld

- (instancetype)initInWindow:(UIWindow *)win iconViews:(NSArray<UIView *> *)views {
    if (!(self = [super init])) return nil;
    _bodies = [NSMutableArray array];
    _overlay = [[FFOverlay alloc] initWithFrame:win.bounds];
    _overlay.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _overlay.backgroundColor = [UIColor clearColor];
    _overlay.userInteractionEnabled = YES;
    [win addSubview:_overlay];

    for (UIView *iv in views) {
        UIView *src = FFImageViewOf(iv);
        UIView *snap = [src snapshotViewAfterScreenUpdates:NO];
        if (!snap) continue;
        CGRect r = [src convertRect:src.bounds toView:_overlay];
        snap.bounds = CGRectMake(0, 0, r.size.width, r.size.height);
        snap.center = CGPointMake(CGRectGetMidX(r), CGRectGetMidY(r));
        snap.userInteractionEnabled = YES;
        snap.layer.allowsEdgeAntialiasing = YES;
        [_overlay addSubview:snap];

        FFBody *b = [FFBody new];
        b.view = snap;
        b.original = iv;
        b.originalAlpha = iv.alpha;
        b.homeCenter = snap.center;
        b.bundleID = FFBundleID(iv);
        [_bodies addObject:b];

        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(dragged:)];
        pan.maximumNumberOfTouches = 1;
        [snap addGestureRecognizer:pan];
        UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(tappedIcon:)];
        [tap requireGestureRecognizerToFail:pan];
        [snap addGestureRecognizer:tap];
    }
    for (FFBody *b in _bodies) b.original.alpha = 0;

    UITapGestureRecognizer *empty = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(tappedEmpty:)];
    empty.numberOfTapsRequired = 2;
    empty.delegate = self;
    [_overlay addGestureRecognizer:empty];

    NSArray *items = [_bodies valueForKey:@"view"];
    _animator = [[UIDynamicAnimator alloc] initWithReferenceView:_overlay];
    _gravity = [[UIGravityBehavior alloc] initWithItems:items];
    _gravity.magnitude = gGravity;
    _collision = [[UICollisionBehavior alloc] initWithItems:items];
    _collision.collisionDelegate = self;
    _collision.collisionMode = UICollisionBehaviorModeEverything;
    [self rebuildBounds];
    _material = [[UIDynamicItemBehavior alloc] initWithItems:items];
    _material.elasticity = gBounce;
    _material.friction = gFriction;
    _material.resistance = 0.05;
    _material.angularResistance = 0.6;
    _material.allowsRotation = gRotate;
    [_animator addBehavior:_gravity];
    [_animator addBehavior:_collision];
    [_animator addBehavior:_material];

    // a small random nudge so a perfect grid doesn't just drop like a block
    for (FFBody *b in _bodies) {
        [_material addLinearVelocity:CGPointMake(arc4random_uniform(81) - 40.0, -(CGFloat)arc4random_uniform(60)) forItem:b.view];
        if (gRotate) [_material addAngularVelocity:((CGFloat)arc4random_uniform(200) - 100.0) / 100.0 forItem:b.view];
    }

    __weak FFWorld *ws = self;
    _lastSize = _overlay.bounds.size;
    _overlay.onLayout = ^{
        FFWorld *s = ws; if (!s) return;
        if (!CGSizeEqualToSize(s.lastSize, s.overlay.bounds.size)) { s.lastSize = s.overlay.bounds.size; [s rebuildBounds]; }
    };

    if (gHaptics) { _thud = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight]; [_thud prepare]; }
    [self startMotion];

    _watchdog = [NSTimer scheduledTimerWithTimeInterval:0.5 repeats:YES block:^(NSTimer *t) {
        FFWorld *s = ws;
        if (!s) { [t invalidate]; return; }
        if (!s.overlay.window || !FFHomeScreenIsUp()) FFStop(NO);
    }];
    return self;
}

- (void)rebuildBounds {
    [_collision removeAllBoundaries];
    CGRect b = _overlay.bounds;
    // keep icons out from under the status bar a little, but let them sit on the very bottom
    CGFloat top = MIN(_overlay.safeAreaInsets.top, 20);
    [_collision addBoundaryWithIdentifier:@"edges" forPath:[UIBezierPath bezierPathWithRect:UIEdgeInsetsInsetRect(b, UIEdgeInsetsMake(top, 0, 0, 0))]];
    // pull back anything that ended up outside after a rotation
    for (FFBody *body in _bodies) {
        CGPoint c = body.view.center;
        CGFloat hw = body.view.bounds.size.width / 2, hh = body.view.bounds.size.height / 2;
        CGPoint n = CGPointMake(MAX(hw, MIN(b.size.width - hw, c.x)), MAX(top + hh, MIN(b.size.height - hh, c.y)));
        if (!CGPointEqualToPoint(c, n)) { body.view.center = n; [_animator updateItemUsingCurrentState:body.view]; }
    }
}

- (CGVector)screenVectorFor:(CMAcceleration)g {
    UIInterfaceOrientation o = UIInterfaceOrientationPortrait;
    UIWindowScene *scene = _overlay.window.windowScene;
    if (scene) o = scene.interfaceOrientation;
    switch (o) {
        case UIInterfaceOrientationPortraitUpsideDown: return CGVectorMake(-g.x, g.y);
        case UIInterfaceOrientationLandscapeLeft:      return CGVectorMake(g.y, g.x);
        case UIInterfaceOrientationLandscapeRight:     return CGVectorMake(-g.y, -g.x);
        default:                                       return CGVectorMake(g.x, -g.y);
    }
}

- (void)startMotion {
    if (!gTilt && !gShake) return;
    _motion = [CMMotionManager new];
    if (!_motion.deviceMotionAvailable) {
        // older/odd hardware: plain accelerometer still gives us "down"
        if (!_motion.accelerometerAvailable) { _motion = nil; return; }
        _motion.accelerometerUpdateInterval = 1.0 / 60;
        __weak FFWorld *ws = self;
        [_motion startAccelerometerUpdatesToQueue:[NSOperationQueue mainQueue] withHandler:^(CMAccelerometerData *d, NSError *e) {
            FFWorld *s = ws; if (!s || !d || s.stopping) return;
            if (gTilt) [s applyGravity:[s screenVectorFor:d.acceleration]];
        }];
        return;
    }
    _motion.deviceMotionUpdateInterval = 1.0 / 60;
    __weak FFWorld *ws = self;
    [_motion startDeviceMotionUpdatesToQueue:[NSOperationQueue mainQueue] withHandler:^(CMDeviceMotion *m, NSError *e) {
        FFWorld *s = ws; if (!s || !m || s.stopping) return;
        if (gTilt) [s applyGravity:[s screenVectorFor:m.gravity]];
        if (gShake) {
            CMAcceleration a = m.userAcceleration;
            double mag = sqrt(a.x * a.x + a.y * a.y + a.z * a.z);
            CFTimeInterval now = CACurrentMediaTime();
            if (mag > 1.6 && now - s.lastShake > 0.35) {
                s.lastShake = now;
                CGVector v = [s screenVectorFor:a];
                [s scatterAlong:v strength:mag];
            }
        }
    }];
}

- (void)applyGravity:(CGVector)v {
    // lying flat: x/y gravity is ~0, so icons drift and settle like on a tabletop
    _gravity.gravityDirection = CGVectorMake(v.dx * gGravity, v.dy * gGravity);
}

- (void)scatterAlong:(CGVector)v strength:(double)mag {
    CGFloat k = 900 * MIN(mag, 4.0);
    for (FFBody *b in _bodies) {
        if (b.drag) continue;
        CGPoint jitter = CGPointMake(((CGFloat)arc4random_uniform(200) - 100) * 3, ((CGFloat)arc4random_uniform(200) - 100) * 3);
        // userAcceleration is the push of the hand; icons get flung the opposite way, like loose objects
        [_material addLinearVelocity:CGPointMake(-v.dx * k + jitter.x, -v.dy * k + jitter.y) forItem:b.view];
        if (gRotate) [_material addAngularVelocity:((CGFloat)arc4random_uniform(400) - 200) / 40.0 forItem:b.view];
    }
    if (gHaptics) [[[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium] impactOccurred];
}

- (FFBody *)bodyFor:(UIView *)v {
    for (FFBody *b in _bodies) if (b.view == v) return b;
    return nil;
}

- (void)dragged:(UIPanGestureRecognizer *)pan {
    FFBody *b = [self bodyFor:pan.view];
    if (!b || _stopping) return;
    CGPoint p = [pan locationInView:_overlay];
    switch (pan.state) {
        case UIGestureRecognizerStateBegan: {
            CGPoint local = [pan locationInView:b.view];
            UIOffset off = UIOffsetMake(local.x - b.view.bounds.size.width / 2, local.y - b.view.bounds.size.height / 2);
            b.drag = [[UIAttachmentBehavior alloc] initWithItem:b.view offsetFromCenter:off attachedToAnchor:p];
            b.drag.length = 0;
            b.drag.damping = 1;
            b.drag.frequency = 0; // rigid
            [_animator addBehavior:b.drag];
            [_overlay bringSubviewToFront:b.view];
            if (gHaptics) [[UISelectionFeedbackGenerator new] selectionChanged];
            break;
        }
        case UIGestureRecognizerStateChanged:
            b.drag.anchorPoint = p;
            break;
        default: {
            if (b.drag) { [_animator removeBehavior:b.drag]; b.drag = nil; }
            CGPoint v = [pan velocityInView:_overlay];
            CGPoint cur = [_material linearVelocityForItem:b.view];
            [_material addLinearVelocity:CGPointMake(v.x - cur.x, v.y - cur.y) forItem:b.view];
            break;
        }
    }
}

- (void)tappedIcon:(UITapGestureRecognizer *)tap {
    if (tap.state != UIGestureRecognizerStateEnded || _stopping) return;
    FFBody *b = [self bodyFor:tap.view];
    if (!b) return;
    if (!b.bundleID) {
        // folders, widgets, web clips: give it a little hop instead
        [_material addLinearVelocity:CGPointMake(0, -600) forItem:b.view];
        return;
    }
    if (gHaptics) [[[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium] impactOccurred];
    NSString *bid = b.bundleID;
    // put the Home Screen back the instant the app opens, so it's normal when you come back
    FFStop(NO);
    FFLaunch(bid);
}

- (void)tappedEmpty:(UITapGestureRecognizer *)tap {
    if (tap.state == UIGestureRecognizerStateEnded) FFStop(YES);
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gr shouldReceiveTouch:(UITouch *)touch {
    return touch.view == _overlay; // only empty space
}

- (void)collisionBehavior:(UICollisionBehavior *)behavior beganContactForItem:(id<UIDynamicItem>)item
   withBoundaryIdentifier:(id<NSCopying>)identifier atPoint:(CGPoint)p {
    if (!_thud) return;
    CGPoint v = [_material linearVelocityForItem:item];
    if (sqrt(v.x * v.x + v.y * v.y) < 450) return;
    CFTimeInterval now = CACurrentMediaTime();
    if (now - _lastThud < 0.06) return;
    _lastThud = now;
    [_thud impactOccurred];
    [_thud prepare];
}

- (void)teardown:(BOOL)animated {
    if (_stopping) return;
    _stopping = YES;
    [_watchdog invalidate]; _watchdog = nil;
    [_motion stopDeviceMotionUpdates];
    [_motion stopAccelerometerUpdates];
    _motion = nil;
    [_animator removeAllBehaviors];
    _overlay.onLayout = nil;
    _overlay.userInteractionEnabled = NO;
    NSArray *bodies = [_bodies copy];
    FFOverlay *overlay = _overlay;
    void (^finish)(void) = ^{
        for (FFBody *b in bodies) { UIView *o = b.original; if (o) o.alpha = b.originalAlpha ?: 1; }
        [overlay removeFromSuperview];
    };
    if (!animated || !overlay.window) { finish(); return; }
    [UIView animateWithDuration:0.55 delay:0 usingSpringWithDamping:0.78 initialSpringVelocity:0.4
                        options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionAllowUserInteraction
                     animations:^{
        for (FFBody *b in bodies) { b.view.transform = CGAffineTransformIdentity; b.view.center = b.homeCenter; }
    } completion:^(BOOL f) { finish(); }];
    if (gHaptics) [[[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleSoft] impactOccurred];
}
@end

// ---- start / stop ----------------------------------------------------------
static CFTimeInterval gLastStop;
static void FFStop(BOOL animated) {
    FFWorld *w = gWorld;
    gWorld = nil;
    if (w) gLastStop = CACurrentMediaTime();
    @try { [w teardown:animated]; } @catch (__unused NSException *e) {}
}

static void FFStart(UIWindow *win) {
    if (gWorld || !gEnabled || !win || !FFHomeScreenIsUp()) return;
    @try {
        NSMutableArray *views = [NSMutableArray array];
        FFCollectIconViews(win, win, objc_getClass("SBIconView"), views);
        if (!views.count) return;
        gWorld = [[FFWorld alloc] initInWindow:win iconViews:views];
        if (!gWorld.bodies.count) FFStop(NO);
    } @catch (__unused NSException *e) {
        FFStop(NO);
    }
}

// ---- trigger gesture on the Home Screen window ------------------------------
@interface FFTrigger : NSObject <UIGestureRecognizerDelegate>
@end
@implementation FFTrigger
+ (instancetype)shared { static FFTrigger *t; static dispatch_once_t o; dispatch_once(&o, ^{ t = [FFTrigger new]; }); return t; }
- (void)fired:(UITapGestureRecognizer *)gr {
    if (gr.state != UIGestureRecognizerStateEnded) return;
    if (gWorld) FFStop(YES);
    else FFStart(gr.view.window ?: (UIWindow *)gr.view);
}
- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)gr {
    if (!gEnabled) return NO;
    if (!gWorld && gTrigger == 0) return NO; // shake-only: the tap never starts it
    ((UITapGestureRecognizer *)gr).numberOfTouchesRequired = gFingers;
    return gWorld != nil || FFHomeScreenIsUp();
}
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)a shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)b { return YES; }
@end

static char kTriggerKey;
static BOOL gTaggedHome;
static __weak UIWindow *gHomeWindow;

static void FFTagWindow(UIWindow *win) {
    if (!win) return;
    gHomeWindow = win;
    if (objc_getAssociatedObject(win, &kTriggerKey)) return;
    UITapGestureRecognizer *t = [[UITapGestureRecognizer alloc] initWithTarget:[FFTrigger shared] action:@selector(fired:)];
    t.numberOfTapsRequired = 2;
    t.numberOfTouchesRequired = gFingers;
    t.cancelsTouchesInView = NO;
    t.delaysTouchesBegan = NO;
    t.delaysTouchesEnded = NO;
    t.delegate = [FFTrigger shared];
    [win addGestureRecognizer:t];
    objc_setAssociatedObject(win, &kTriggerKey, t, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void FFInstall(void) {
    static BOOL done; if (done) return;
    Class cls = objc_getClass("SBIconView");
    SEL sel = @selector(didMoveToWindow);
    if (!cls) return;
    done = YES;
    __block IMP orig = NULL;
    orig = CBHook(cls, sel, ^(UIView *self) {
        if (orig) ((void (*)(id, SEL))orig)(self, sel);
        @try {
            UIWindow *w = self.window;
            if (!w) return;
            NSString *n = NSStringFromClass([w class]);
            if ([n containsString:@"HomeScreen"]) { gTaggedHome = YES; FFTagWindow(w); }
        } @catch (__unused NSException *e) {}
    });
    // fallback for builds without a dedicated Home Screen window class
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        if (gTaggedHome) return;
        for (UIScene *sc in [UIApplication sharedApplication].connectedScenes) {
            if (![sc isKindOfClass:[UIWindowScene class]]) continue;
            for (UIWindow *w in ((UIWindowScene *)sc).windows) {
                NSMutableArray *found = [NSMutableArray array];
                FFCollectIconViews(w, w, cls, found);
                if (found.count >= 4) { FFTagWindow(w); gTaggedHome = YES; return; }
            }
        }
    });
}

// ---- shake watcher --------------------------------------------------------
// Runs only while the Home Screen is showing and Freefall isn't already active, at a
// low rate, so it costs next to nothing the rest of the time.
static CMMotionManager *gWatch;
static NSTimer *gWatchTimer;
static NSMutableArray<NSNumber *> *gPeaks;

static UIWindow *FFFindHomeWindow(void) {
    UIWindow *w = gHomeWindow;
    if (w) return w;
    Class cls = objc_getClass("SBIconView");
    for (UIScene *sc in [UIApplication sharedApplication].connectedScenes) {
        if (![sc isKindOfClass:[UIWindowScene class]]) continue;
        for (UIWindow *win in ((UIWindowScene *)sc).windows) {
            if ([NSStringFromClass([win class]) containsString:@"HomeScreen"]) { gHomeWindow = win; return win; }
        }
        for (UIWindow *win in ((UIWindowScene *)sc).windows) {
            NSMutableArray *found = [NSMutableArray array];
            FFCollectIconViews(win, win, cls, found);
            if (found.count >= 4) { gHomeWindow = win; return win; }
        }
    }
    return nil;
}

static void FFShakeSeen(double mag) {
    // a shake is two or more hard jolts within 0.7s (back-and-forth), not one bump
    CFTimeInterval now = CACurrentMediaTime();
    if (!gPeaks) gPeaks = [NSMutableArray array];
    if (gPeaks.count && now - gPeaks.lastObject.doubleValue < 0.09) return; // same jolt
    [gPeaks addObject:@(now)];
    while (gPeaks.count && now - gPeaks.firstObject.doubleValue > 0.7) [gPeaks removeObjectAtIndex:0];
    if (gPeaks.count >= 2) {
        [gPeaks removeAllObjects];
        if (now - gLastStop < 1.2) return; // don't instantly restart right after putting icons back
        FFStart(FFFindHomeWindow());
        FFWatchTick();
    }
}

static void FFWatchStart(void) {
    if (gWatch) return;
    gWatch = [CMMotionManager new];
    // sensitivity 0..1 -> jolt threshold 2.0g (firm shake) .. 0.8g (gentle)
    double threshold = 2.0 - 1.2 * gSensitivity;
    if (gWatch.deviceMotionAvailable) {
        gWatch.deviceMotionUpdateInterval = 1.0 / 30;
        [gWatch startDeviceMotionUpdatesToQueue:[NSOperationQueue mainQueue] withHandler:^(CMDeviceMotion *m, NSError *e) {
            if (!m) return;
            CMAcceleration a = m.userAcceleration;
            double mag = sqrt(a.x * a.x + a.y * a.y + a.z * a.z);
            if (mag > threshold) FFShakeSeen(mag);
        }];
    } else if (gWatch.accelerometerAvailable) {
        gWatch.accelerometerUpdateInterval = 1.0 / 30;
        [gWatch startAccelerometerUpdatesToQueue:[NSOperationQueue mainQueue] withHandler:^(CMAccelerometerData *d, NSError *e) {
            if (!d) return;
            CMAcceleration a = d.acceleration;
            double mag = fabs(sqrt(a.x * a.x + a.y * a.y + a.z * a.z) - 1.0); // remove gravity
            if (mag > threshold) FFShakeSeen(mag);
        }];
    } else gWatch = nil;
}

static void FFWatchStop(void) {
    [gWatch stopDeviceMotionUpdates];
    [gWatch stopAccelerometerUpdates];
    gWatch = nil;
    [gPeaks removeAllObjects];
}

static void FFWatchTick(void) {
    BOOL want = NO;
    @try { want = gEnabled && gTrigger != 1 && !gWorld && FFHomeScreenIsUp(); } @catch (__unused NSException *e) {}
    if (want) FFWatchStart(); else FFWatchStop();
}

// ---- Home button puts the icons back ---------------------------------------
static void FFHookHomeButton(void) {
    const char *classes[] = {"SBHomeHardwareButton", "SBHomeHardwareButtonActions", "SpringBoard"};
    const char *sels[]    = {"singlePressUp:", "performSinglePressUpActions", "_handleMenuButtonEvent"};
    for (int i = 0; i < 3; i++) {
        Class c = objc_getClass(classes[i]);
        SEL sel = sel_registerName(sels[i]);
        if (!c || !class_getInstanceMethod(c, sel)) continue;
        __block IMP orig = NULL;
        if (strchr(sels[i], ':')) {
            orig = CBHook(c, sel, ^(id self, id arg) {
                if (gWorld) { dispatch_async(dispatch_get_main_queue(), ^{ FFStop(YES); }); return; }
                ((void (*)(id, SEL, id))orig)(self, sel, arg);
            });
        } else {
            orig = CBHook(c, sel, ^(id self) {
                if (gWorld) { dispatch_async(dispatch_get_main_queue(), ^{ FFStop(YES); }); return; }
                ((void (*)(id, SEL))orig)(self, sel);
            });
        }
        return; // hook only the first one this iOS version has
    }
}

static void FFPrefsChanged(CFNotificationCenterRef c, void *o, CFStringRef n, const void *obj, CFDictionaryRef i) {
    dispatch_async(dispatch_get_main_queue(), ^{ FFWatchStop(); FFLoadPrefs(); FFWatchTick(); });
}
static void FFLocked(CFNotificationCenterRef c, void *o, CFStringRef n, const void *obj, CFDictionaryRef i) {
    dispatch_async(dispatch_get_main_queue(), ^{ FFStop(NO); FFWatchStop(); });
}

__attribute__((constructor)) static void FFInit(void) {
    @autoreleasepool {
        if (!CBIsSpringBoard()) return;
        FFLoadPrefs();
        CFNotificationCenterRef dc = CFNotificationCenterGetDarwinNotifyCenter();
        CFNotificationCenterAddObserver(dc, NULL, FFPrefsChanged, CFSTR("com.mymculture.freefall/prefs"), NULL,
                                        CFNotificationSuspensionBehaviorDeliverImmediately);
        CFNotificationCenterAddObserver(dc, NULL, FFLocked, CFSTR("com.apple.springboard.lockcomplete"), NULL,
                                        CFNotificationSuspensionBehaviorDeliverImmediately);
        FFInstall();
        [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidFinishLaunchingNotification object:nil
                                                           queue:[NSOperationQueue mainQueue]
                                                      usingBlock:^(NSNotification *n) {
            FFInstall();
            FFHookHomeButton();
            // cheap check twice a second: is the Home Screen up? only then listen for shakes
            gWatchTimer = [NSTimer scheduledTimerWithTimeInterval:0.5 repeats:YES block:^(NSTimer *t) { FFWatchTick(); }];
        }];
    }
}
