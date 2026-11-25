// Freefall 2.0 - a faithful recreation of the classic GraviBoard for modern jailbreaks.
// Turn it on (shake, multi-finger double-tap, an Activator event, or automatically) and
// every Home Screen icon falls with gravity, follows the tilt of the device, bounces off
// the edges and each other, and can be grabbed and flung. Gravity stays on - through app
// launches and page swipes - until you turn it off the same way.
// Options mirror the original: activation method, automatic enable, launching apps, page
// swiping, dock icons, finger mode (drag / gravity well / anti-gravity well), finger
// impact, Earth / Moon / Zero gravity, bounciness and friction.
#import "../common/cb.h"
#import <CoreMotion/CoreMotion.h>
#import <dlfcn.h>
#ifndef JBROOT
#define JBROOT ""
#endif

#define FF_DOMAIN CFSTR("com.mymculture.freefall")

static BOOL gEnabled = YES, gTilt = YES, gDock = YES, gLabels = NO, gHaptics = YES, gShake = YES, gRotate = YES;
static BOOL gAlways = NO, gLaunch = YES, gPaging = NO, gHomeOff = YES;
static BOOL gActive = NO; // gravity is switched on (the world itself only exists while the Home Screen shows)
static NSInteger gFingers = 2, gTrigger = 0; // trigger: 0 shake, 1 double-tap, 2 both, 3 Activator only
static NSInteger gFingerMode = 0;            // 0 drag & fling, 1 gravity well, 2 anti-gravity well, 3 off
static NSInteger gGravityMode = 0;           // 0 Earth, 1 Moon, 2 Zero
static CGFloat gImpact = 0.5;
static NSHashTable *gClaimed;                // real icon views currently hidden behind a falling copy
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
static void FFTurnOff(BOOL animated);
static void FFToggle(void);

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
    if (gTrigger < 0 || gTrigger > 3) gTrigger = 0;
    BOOL wasAlways = gAlways;
    gAlways   = CBPrefBool(FF_DOMAIN, CFSTR("AlwaysOn"), NO);
    gLaunch   = CBPrefBool(FF_DOMAIN, CFSTR("Launch"), YES);
    gPaging   = CBPrefBool(FF_DOMAIN, CFSTR("Paging"), NO);
    gHomeOff  = CBPrefBool(FF_DOMAIN, CFSTR("HomeOff"), YES);
    gFingerMode = (NSInteger)FFPrefFloat(CFSTR("FingerMode"), 0);
    if (gFingerMode < 0 || gFingerMode > 3) gFingerMode = 0;
    gGravityMode = (NSInteger)FFPrefFloat(CFSTR("GravityMode"), 0);
    if (gGravityMode < 0 || gGravityMode > 2) gGravityMode = 0;
    gImpact   = MAX(0.0, MIN(1.0, FFPrefFloat(CFSTR("Impact"), 0.5)));
    if (gAlways && !wasAlways) gActive = YES;
    if (!gAlways && wasAlways) gActive = NO;
    gSensitivity = MAX(0.0, MIN(1.0, FFPrefFloat(CFSTR("Sensitivity"), 0.5)));
    gGravity  = gGravityMode == 2 ? 0.0 : (gGravityMode == 1 ? 0.165 : 1.0);
    gBounce   = MAX(0.0, MIN(1.0, FFPrefFloat(CFSTR("Bounce"), 0.55)));
    gFriction = MAX(0.0, MIN(1.0, FFPrefFloat(CFSTR("Friction"), 0.3)));
    if (!gEnabled) gActive = NO;
    // settings changed: put the icons back; if gravity is on it restarts with the new settings
    FFStop(NO);
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
        if (!(p == v && [gClaimed containsObject:p])) alpha *= p.alpha;
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
    if (root.hidden || (root.alpha < 0.05 && ![gClaimed containsObject:root])) return;
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
@property (nonatomic, assign) BOOL passThrough; // empty space lets touches reach the Home Screen (page swiping)
@end
@implementation FFOverlay
- (UIView *)hitTest:(CGPoint)p withEvent:(UIEvent *)e {
    UIView *v = [super hitTest:p withEvent:e];
    return (v == self && self.passThrough) ? nil : v;
}
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
@property (nonatomic, assign) CFTimeInterval lastThud, startTime;
@property (nonatomic, strong) NSMutableArray<NSNumber *> *jolts;
@property (nonatomic, assign) CGSize lastSize;
@property (nonatomic, assign) BOOL stopping;
@property (nonatomic, weak) UIWindow *window;
@property (nonatomic, strong) UILongPressGestureRecognizer *wellTouch;
@property (nonatomic, strong) UITapGestureRecognizer *emptyTap;
@property (nonatomic, strong) UIDynamicBehavior *well;
@property (nonatomic, assign) CGPoint wellPoint;
@property (nonatomic, assign) CFTimeInterval wellLast;
@property (nonatomic, copy) NSArray *lastVisible;
@end

@implementation FFWorld

- (instancetype)initInWindow:(UIWindow *)win iconViews:(NSArray<UIView *> *)views {
    if (!(self = [super init])) return nil;
    _bodies = [NSMutableArray array];
    _jolts = [NSMutableArray array];
    _startTime = CACurrentMediaTime();
    _window = win;
    _overlay = [[FFOverlay alloc] initWithFrame:win.bounds];
    _overlay.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _overlay.backgroundColor = [UIColor clearColor];
    _overlay.userInteractionEnabled = YES;
    _overlay.passThrough = gPaging;
    [win addSubview:_overlay];

    _animator = [[UIDynamicAnimator alloc] initWithReferenceView:_overlay];
    _gravity = [[UIGravityBehavior alloc] initWithItems:@[]];
    _gravity.gravityDirection = CGVectorMake(0, gGravity);
    _collision = [[UICollisionBehavior alloc] initWithItems:@[]];
    _collision.collisionDelegate = self;
    _collision.collisionMode = UICollisionBehaviorModeEverything;
    _material = [[UIDynamicItemBehavior alloc] initWithItems:@[]];
    _material.elasticity = gBounce;
    _material.friction = gFriction;
    _material.resistance = gGravity > 0 ? 0.05 : 0.0; // nothing slows you down in zero gravity
    _material.angularResistance = gGravity > 0 ? 0.6 : 0.1;
    _material.allowsRotation = gRotate;

    for (UIView *iv in views) [self addBodyFor:iv];
    [self rebuildBounds];
    [_animator addBehavior:_gravity];
    [_animator addBehavior:_collision];
    [_animator addBehavior:_material];

    // double-tap empty space puts everything back (only when empty space isn't used for
    // page swiping or a gravity well)
    if (!gPaging && (gFingerMode == 0 || gFingerMode == 3)) {
        _emptyTap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(tappedEmpty:)];
        _emptyTap.numberOfTapsRequired = 2;
        _emptyTap.delegate = self;
        [_overlay addGestureRecognizer:_emptyTap];
    }
    // gravity well / anti-gravity well: a finger anywhere on the screen pulls or pushes the icons
    if (gFingerMode == 1 || gFingerMode == 2) {
        _wellTouch = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(wellTouched:)];
        _wellTouch.minimumPressDuration = 0;
        _wellTouch.allowableMovement = CGFLOAT_MAX;
        _wellTouch.cancelsTouchesInView = NO;
        _wellTouch.delaysTouchesBegan = NO;
        _wellTouch.delaysTouchesEnded = NO;
        _wellTouch.delegate = self;
        [win addGestureRecognizer:_wellTouch];
    }

    __weak FFWorld *ws = self;
    _lastSize = _overlay.bounds.size;
    _overlay.onLayout = ^{
        FFWorld *s = ws; if (!s) return;
        if (!CGSizeEqualToSize(s.lastSize, s.overlay.bounds.size)) { s.lastSize = s.overlay.bounds.size; [s rebuildBounds]; }
    };

    if (gHaptics) { _thud = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight]; [_thud prepare]; }
    [self startMotion];

    _watchdog = [NSTimer scheduledTimerWithTimeInterval:0.3 repeats:YES block:^(NSTimer *t) {
        FFWorld *s = ws;
        if (!s) { [t invalidate]; return; }
        if (!s.overlay.window || !FFHomeScreenIsUp()) { FFStop(NO); return; }
        @try { [s resync]; } @catch (__unused NSException *e) {}
    }];
    return self;
}

// Turn one real icon into a falling body: a snapshot that moves, with the real icon hidden.
- (void)addBodyFor:(UIView *)iv {
    UIView *src = FFImageViewOf(iv);
    UIView *snap = [src snapshotViewAfterScreenUpdates:NO];
    if (!snap) return;
    CGRect r = [src convertRect:src.bounds toView:_overlay];
    if (r.size.width < 8 || r.size.height < 8) return;
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
    if (!gClaimed) gClaimed = [NSHashTable weakObjectsHashTable];
    [gClaimed addObject:iv];
    iv.alpha = 0;

    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(tappedIcon:)];
    if (gFingerMode == 0) {
        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(dragged:)];
        pan.maximumNumberOfTouches = 1;
        [snap addGestureRecognizer:pan];
        [tap requireGestureRecognizerToFail:pan];
    }
    [snap addGestureRecognizer:tap];

    [_gravity addItem:snap];
    [_collision addItem:snap];
    [_material addItem:snap];
    // a small random nudge so a perfect grid doesn't just drop like a block; in zero
    // gravity it's what sets the icons drifting
    CGFloat kick = gGravity > 0 ? 40.0 : 90.0;
    [_material addLinearVelocity:CGPointMake(((CGFloat)arc4random_uniform(201) - 100.0) / 100.0 * kick,
                                             gGravity > 0 ? -(CGFloat)arc4random_uniform(60)
                                                          : ((CGFloat)arc4random_uniform(201) - 100.0) / 100.0 * kick)
                         forItem:snap];
    if (gRotate) [_material addAngularVelocity:((CGFloat)arc4random_uniform(200) - 100.0) / 100.0 forItem:snap];
}

- (void)removeBody:(FFBody *)b {
    if (b.drag) { [_animator removeBehavior:b.drag]; b.drag = nil; }
    [_gravity removeItem:b.view];
    [_collision removeItem:b.view];
    [_material removeItem:b.view];
    [b.view removeFromSuperview];
    UIView *o = b.original;
    if (o) { o.alpha = b.originalAlpha ?: 1; [gClaimed removeObject:o]; }
    [_bodies removeObject:b];
}

// Keep the world matched to what's on screen: after a page swipe the icons of the old page
// go home and the icons of the new page start falling.
- (void)resync {
    UIWindow *win = _window;
    if (!win || _stopping) return;
    NSMutableArray *visible = [NSMutableArray array];
    FFCollectIconViews(win, win, objc_getClass("SBIconView"), visible);
    BOOL settled = _lastVisible && [_lastVisible isEqualToArray:visible];
    _lastVisible = visible;
    if (!settled) return; // still scrolling
    for (FFBody *b in [_bodies copy]) {
        UIView *o = b.original;
        if (!o || ![visible containsObject:o]) [self removeBody:b];
    }
    for (UIView *iv in visible) {
        if (![gClaimed containsObject:iv]) [self addBodyFor:iv];
    }
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
    BOOL tilt = gTilt && gGravity > 0;
    if (!tilt && !gShake) return;
    _motion = [CMMotionManager new];
    if (!_motion.deviceMotionAvailable) {
        // older/odd hardware: plain accelerometer still gives us "down"
        if (!_motion.accelerometerAvailable) { _motion = nil; return; }
        _motion.accelerometerUpdateInterval = 1.0 / 60;
        __weak FFWorld *ws = self;
        [_motion startAccelerometerUpdatesToQueue:[NSOperationQueue mainQueue] withHandler:^(CMAccelerometerData *d, NSError *e) {
            FFWorld *s = ws; if (!s || !d || s.stopping) return;
            if (tilt) [s applyGravity:[s screenVectorFor:d.acceleration]];
            if (gShake) {
                CMAcceleration a = d.acceleration;
                [s jolt:fabs(sqrt(a.x * a.x + a.y * a.y + a.z * a.z) - 1.0)];
            }
        }];
        return;
    }
    _motion.deviceMotionUpdateInterval = 1.0 / 60;
    __weak FFWorld *ws = self;
    [_motion startDeviceMotionUpdatesToQueue:[NSOperationQueue mainQueue] withHandler:^(CMDeviceMotion *m, NSError *e) {
        FFWorld *s = ws; if (!s || !m || s.stopping) return;
        if (tilt) [s applyGravity:[s screenVectorFor:m.gravity]];
        if (gShake) {
            CMAcceleration a = m.userAcceleration;
            [s jolt:sqrt(a.x * a.x + a.y * a.y + a.z * a.z)];
        }
    }];
}

- (void)applyGravity:(CGVector)v {
    // lying flat: x/y gravity is ~0, so icons drift and settle like on a tabletop
    _gravity.gravityDirection = CGVectorMake(v.dx * gGravity, v.dy * gGravity);
}

// Shake again to turn gravity off: same detector as the one that starts Freefall
// (two hard jolts within 0.7s). Ignores the first second so the tail of the shake that
// dropped the icons doesn't immediately put them back.
- (void)jolt:(double)mag {
    if (mag <= 2.0 - 1.2 * gSensitivity) return;
    CFTimeInterval now = CACurrentMediaTime();
    if (now - _startTime < 1.0) return;
    if (_jolts.count && now - _jolts.lastObject.doubleValue < 0.09) return;
    [_jolts addObject:@(now)];
    while (_jolts.count && now - _jolts.firstObject.doubleValue > 0.7) [_jolts removeObjectAtIndex:0];
    if (_jolts.count >= 2) {
        [_jolts removeAllObjects];
        dispatch_async(dispatch_get_main_queue(), ^{ FFTurnOff(YES); });
    }
}

- (FFBody *)bodyFor:(UIView *)v {
    for (FFBody *b in _bodies) if (b.view == v) return b;
    return nil;
}

// ---- finger mode: drag & fling ----
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
            // finger impact: how hard a fling throws the icon (0.5x .. 1.5x of the real flick)
            CGFloat k = 0.5 + gImpact;
            CGPoint v = [pan velocityInView:_overlay];
            CGPoint cur = [_material linearVelocityForItem:b.view];
            [_material addLinearVelocity:CGPointMake(v.x * k - cur.x, v.y * k - cur.y) forItem:b.view];
            break;
        }
    }
}

// ---- finger mode: gravity well / anti-gravity well ----
- (void)wellTouched:(UILongPressGestureRecognizer *)gr {
    if (_stopping) return;
    switch (gr.state) {
        case UIGestureRecognizerStateBegan: {
            _wellPoint = [gr locationInView:_overlay];
            _wellLast = CACurrentMediaTime();
            if (_well) [_animator removeBehavior:_well];
            _well = [UIDynamicBehavior new];
            __weak FFWorld *ws = self;
            _well.action = ^{ [ws wellStep]; };
            [_animator addBehavior:_well]; // also wakes the animator if everything had come to rest
            break;
        }
        case UIGestureRecognizerStateChanged:
            _wellPoint = [gr locationInView:_overlay];
            break;
        default:
            if (_well) { [_animator removeBehavior:_well]; _well = nil; }
            break;
    }
}

- (void)wellStep {
    if (!_well || _stopping) return;
    CFTimeInterval now = CACurrentMediaTime();
    CGFloat dt = MAX(0.0, MIN(1.0 / 30, now - _wellLast));
    _wellLast = now;
    // finger impact: pull of the well. UIKit's Earth gravity is 1000 pt/s^2; the well runs
    // from 1.5x to 6.5x that close to the finger and fades with distance beyond 120pt.
    CGFloat accel = (1500.0 + 5000.0 * gImpact) * (gFingerMode == 2 ? -1.0 : 1.0);
    const CGFloat core = 120.0;
    for (FFBody *b in _bodies) {
        CGPoint c = b.view.center;
        CGFloat dx = _wellPoint.x - c.x, dy = _wellPoint.y - c.y;
        CGFloat r = sqrt(dx * dx + dy * dy);
        if (r < 1) continue;
        CGFloat a = accel * (core / MAX(r, core)) * dt;
        [_material addLinearVelocity:CGPointMake(dx / r * a, dy / r * a) forItem:b.view];
    }
}

- (void)tappedIcon:(UITapGestureRecognizer *)tap {
    if (tap.state != UIGestureRecognizerStateEnded || _stopping) return;
    FFBody *b = [self bodyFor:tap.view];
    if (!b) return;
    if (!gLaunch || !b.bundleID) {
        // launching switched off, or a folder / widget / web clip: give it a little hop instead
        [_material addLinearVelocity:CGPointMake(0, -600) forItem:b.view];
        return;
    }
    if (gHaptics) [[[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium] impactOccurred];
    NSString *bid = b.bundleID;
    // the Home Screen goes back to normal under the app; gravity is still on, so the icons
    // fall again when you come back
    FFStop(NO);
    FFLaunch(bid);
}

- (void)tappedEmpty:(UITapGestureRecognizer *)tap {
    if (tap.state == UIGestureRecognizerStateEnded) FFTurnOff(YES);
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gr shouldReceiveTouch:(UITouch *)touch {
    if (gr == _wellTouch) return YES;
    return touch.view == _overlay; // only empty space
}
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)a shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)b {
    return a == _wellTouch || b == _wellTouch;
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
    _well = nil;
    [_animator removeAllBehaviors];
    if (_wellTouch) { [_wellTouch.view removeGestureRecognizer:_wellTouch]; _wellTouch = nil; }
    _overlay.onLayout = nil;
    _overlay.userInteractionEnabled = NO;
    NSArray *bodies = [_bodies copy];
    FFOverlay *overlay = _overlay;
    void (^finish)(void) = ^{
        for (FFBody *b in bodies) {
            UIView *o = b.original;
            if (o) { o.alpha = b.originalAlpha ?: 1; [gClaimed removeObject:o]; }
        }
        [overlay removeFromSuperview];
    };
    if (!animated || !overlay.window) { finish(); return; }
    [UIView animateWithDuration:0.55 delay:0 usingSpringWithDamping:0.78 initialSpringVelocity:0.4
                        options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionAllowUserInteraction
                     animations:^{
        for (FFBody *b in bodies) {
            b.view.transform = CGAffineTransformIdentity;
            // if the page moved since the icon fell, fly to where the real icon is now
            UIView *o = b.original;
            CGPoint home = b.homeCenter;
            if (o && o.window) {
                UIView *src = FFImageViewOf(o);
                CGRect r = [src convertRect:src.bounds toView:overlay];
                home = CGPointMake(CGRectGetMidX(r), CGRectGetMidY(r));
            }
            b.view.center = home;
        }
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

// Switch gravity off for good (until the next activation), as opposed to FFStop, which only
// clears the falling icons off the screen (app launched, device locked, settings changed).
static void FFTurnOff(BOOL animated) {
    gActive = NO;
    FFStop(animated);
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
    FFToggle();
}
- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)gr {
    if (!gEnabled) return NO;
    if (gTrigger != 1 && gTrigger != 2) return NO; // the tap only works when it's the chosen method
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
        if (!gActive) FFToggle();
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
    BOOL up = NO;
    @try { up = gEnabled && !gWorld && FFHomeScreenIsUp(); } @catch (__unused NSException *e) {}
    // gravity is on but the icons aren't falling (back from an app, unlocked, left edit
    // mode, settings changed): drop them again
    if (up && gActive && CACurrentMediaTime() - gLastStop > 0.6) {
        FFStart(FFFindHomeWindow());
        up = NO;
    }
    want = up && !gActive && (gTrigger == 0 || gTrigger == 2);
    if (want) FFWatchStart(); else FFWatchStop();
}

// The one switch every activation method flips.
static void FFToggle(void) {
    if (!gEnabled) return;
    if (gActive || gWorld) { FFTurnOff(YES); return; }
    gActive = YES;
    @try { if (FFHomeScreenIsUp()) FFStart(FFFindHomeWindow()); } @catch (__unused NSException *e) {}
    FFWatchTick();
}

// ---- Activator (optional) --------------------------------------------------
// If Activator is installed, Freefall shows up there as an action, so any Activator event
// can switch gravity on and off - the way the original was activated. Nothing here links
// against Activator; without it this section does nothing.
@interface FFListener : NSObject
@end
@implementation FFListener
+ (instancetype)shared { static FFListener *l; static dispatch_once_t o; dispatch_once(&o, ^{ l = [FFListener new]; }); return l; }
- (void)activator:(id)activator receiveEvent:(id)event {
    FFToggle();
    SEL s = sel_registerName("setHandled:");
    if ([event respondsToSelector:s]) ((void (*)(id, SEL, BOOL))objc_msgSend)(event, s, YES);
}
- (void)activator:(id)activator abortEvent:(id)event {}
- (NSString *)activator:(id)activator requiresLocalizedTitleForListenerName:(NSString *)name { return @"Freefall"; }
- (NSString *)activator:(id)activator requiresLocalizedDescriptionForListenerName:(NSString *)name { return @"Turn Home Screen gravity on or off"; }
- (NSString *)activator:(id)activator requiresLocalizedGroupForListenerName:(NSString *)name { return @"Freefall"; }
- (NSArray *)activator:(id)activator requiresCompatibleEventModesForListenerWithName:(NSString *)name {
    return @[@"springboard", @"application", @"lockscreen"];
}
@end

static void FFRegisterActivator(void) {
    @try {
        if (!objc_getClass("LAActivator")) {
            const char *paths[] = {JBROOT "/usr/lib/libactivator.dylib", "/usr/lib/libactivator.dylib"};
            for (int i = 0; i < 2 && !objc_getClass("LAActivator"); i++) dlopen(paths[i], RTLD_LAZY);
        }
        id act = CBSendID(objc_getClass("LAActivator"), "sharedInstance");
        SEL reg = sel_registerName("registerListener:forName:");
        if (act && [act respondsToSelector:reg])
            ((void (*)(id, SEL, id, id))objc_msgSend)(act, reg, [FFListener shared], @"com.mymculture.freefall");
    } @catch (__unused NSException *e) {}
}

// ---- Home button turns gravity off (optional) ---------------------------------------
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
                if (gWorld && gHomeOff) { dispatch_async(dispatch_get_main_queue(), ^{ FFTurnOff(YES); }); return; }
                ((void (*)(id, SEL, id))orig)(self, sel, arg);
            });
        } else {
            orig = CBHook(c, sel, ^(id self) {
                if (gWorld && gHomeOff) { dispatch_async(dispatch_get_main_queue(), ^{ FFTurnOff(YES); }); return; }
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
        gActive = gEnabled && gAlways;
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
            FFRegisterActivator();
            // cheap check twice a second: is the Home Screen up? only then listen for shakes
            gWatchTimer = [NSTimer scheduledTimerWithTimeInterval:0.5 repeats:YES block:^(NSTimer *t) { FFWatchTick(); }];
        }];
    }
}
