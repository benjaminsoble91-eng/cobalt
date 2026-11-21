// PowerPlus - adds slide-to-respring and slide-to-reboot-userspace sliders to the power-off screen.
#import "../common/cb.h"
#import <spawn.h>
#import <sys/wait.h>

#define PP_DOMAIN CFSTR("com.mymculture.powerplus")
#ifndef JBROOT
#define JBROOT "/var/jb"   /* "" for rootful builds (set by build.sh) */
#endif
#define PP_HELPER JBROOT "/usr/libexec/powerplus-helper"
extern char **environ;
static char kBarKey;
static BOOL gEnabled = YES;

static void PPLoadPrefs(void) {
    CFPreferencesAppSynchronize(PP_DOMAIN);
    gEnabled = CBPrefBool(PP_DOMAIN, CFSTR("Enabled"), YES);
}

static void PPRespring(void) {
    @try {
        Class actCls = objc_getClass("SBSRelaunchAction"), svcCls = objc_getClass("FBSSystemService");
        SEL mk = sel_registerName("actionWithReason:options:targetURL:");
        SEL send = sel_registerName("sendActions:withResult:");
        id svc = CBSendID(svcCls, "sharedService");
        if (actCls && [actCls respondsToSelector:mk] && svc && [svc respondsToSelector:send]) {
            // options 4 = fade to black
            id act = ((id (*)(id, SEL, id, NSUInteger, id))objc_msgSend)(actCls, mk, @"RestartRenderServer", 4, nil);
            if (act) ((void (*)(id, SEL, id, id))objc_msgSend)(svc, send, [NSSet setWithObject:act], nil);
        }
    } @catch (__unused NSException *e) {}
    // if the relaunch request didn't take, quitting SpringBoard resprings too
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ exit(0); });
}

static void PPAlert(UIView *from, NSString *title, NSString *msg) {
    UIViewController *vc = from.window.rootViewController;
    while (vc.presentedViewController) vc = vc.presentedViewController;
    if (!vc) return;
    UIAlertController *a = [UIAlertController alertControllerWithTitle:title message:msg preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
    [vc presentViewController:a animated:YES completion:nil];
}

static void PPUserspace(UIView *from) {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        int status = -1;
        if (access(PP_HELPER, X_OK) == 0) {
            pid_t pid = 0;
            char *argv[] = { (char *)PP_HELPER, (char *)"userspace", NULL };
            if (posix_spawn(&pid, PP_HELPER, NULL, NULL, argv, environ) == 0) waitpid(pid, &status, 0);
        }
        // still here a moment later means the reboot didn't happen
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            PPAlert(from, @"Userspace Reboot", @"This jailbreak didn't allow a userspace reboot from here. Respring still works.");
        });
    });
}

// ---- slide-to-act control, styled after the stock power-off slider ----------
@interface PPSlider : UIView
@property (nonatomic, copy) void (^fired)(PPSlider *slider);
- (instancetype)initWithTitle:(NSString *)title color:(UIColor *)color symbol:(NSString *)symbol;
- (void)reset;
@end

@implementation PPSlider {
    UIView *_track, *_knob;
    UIImageView *_glyph;
    UILabel *_label;
    CAGradientLayer *_shine;
    BOOL _dragging, _done;
    CGFloat _grabOffset;
}
- (instancetype)initWithTitle:(NSString *)title color:(UIColor *)color symbol:(NSString *)symbol {
    if ((self = [super initWithFrame:CGRectZero])) {
        _track = [UIView new];
        _track.backgroundColor = [color colorWithAlphaComponent:0.62];
        _track.layer.masksToBounds = YES;
        _track.userInteractionEnabled = NO;
        [self addSubview:_track];

        _label = [UILabel new];
        _label.text = title;
        _label.textColor = [UIColor whiteColor];
        _label.font = [UIFont systemFontOfSize:21 weight:UIFontWeightRegular];
        _label.textAlignment = NSTextAlignmentCenter;
        _label.adjustsFontSizeToFitWidth = YES;
        _label.minimumScaleFactor = 0.6;
        _label.userInteractionEnabled = NO;
        [self addSubview:_label];

        // moving highlight across the text, like "slide to power off"
        _shine = [CAGradientLayer layer];
        _shine.colors = @[ (id)[UIColor colorWithWhite:1 alpha:0.45].CGColor, (id)[UIColor whiteColor].CGColor,
                           (id)[UIColor colorWithWhite:1 alpha:0.45].CGColor ];
        _shine.startPoint = CGPointMake(0, 0.5);
        _shine.endPoint = CGPointMake(1, 0.5);
        _shine.locations = @[ @0.0, @0.5, @1.0 ];
        _label.layer.mask = _shine;

        _knob = [UIView new];
        _knob.backgroundColor = [UIColor whiteColor];
        _knob.layer.shadowColor = [UIColor blackColor].CGColor;
        _knob.layer.shadowOpacity = 0.18;
        _knob.layer.shadowRadius = 4;
        _knob.layer.shadowOffset = CGSizeMake(0, 1);
        [self addSubview:_knob];

        UIImage *img = nil;
        if (@available(iOS 13.0, *)) {
            UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:25 weight:UIImageSymbolWeightSemibold];
            img = [UIImage systemImageNamed:symbol withConfiguration:cfg];
        }
        _glyph = [[UIImageView alloc] initWithImage:img];
        _glyph.tintColor = color;
        _glyph.contentMode = UIViewContentModeCenter;
        [_knob addSubview:_glyph];

        [self addGestureRecognizer:[[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(pan:)]];
    }
    return self;
}
- (CGFloat)knobSize { return self.bounds.size.height - 8; }
- (CGFloat)maxX { return self.bounds.size.width - [self knobSize] - 4; }
- (void)startShine {
    if ([_shine animationForKey:@"shine"]) return;
    CABasicAnimation *a = [CABasicAnimation animationWithKeyPath:@"locations"];
    a.fromValue = @[ @-1.0, @-0.5, @0.0 ];
    a.toValue = @[ @1.0, @1.5, @2.0 ];
    a.duration = 2.4;
    a.repeatCount = HUGE_VALF;
    a.removedOnCompletion = NO;
    [_shine addAnimation:a forKey:@"shine"];
}
- (void)didMoveToWindow { [super didMoveToWindow]; if (self.window) [self startShine]; }
- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat w = self.bounds.size.width, h = self.bounds.size.height, k = [self knobSize];
    _track.frame = self.bounds;
    _track.layer.cornerRadius = h / 2;
    _knob.layer.cornerRadius = k / 2;
    if (!_dragging && !_done) _knob.frame = CGRectMake(4, 4, k, k);
    else _knob.bounds = CGRectMake(0, 0, k, k);
    _glyph.frame = _knob.bounds;
    _label.frame = CGRectMake(k + 14, 0, MAX(0, w - k - 14 - 22), h);
    _shine.frame = _label.bounds;
    [self startShine];
}
- (void)setProgress:(CGFloat)p {
    _label.alpha = MAX(0, 1 - p * 2.5);
}
- (void)reset {
    _done = NO; _dragging = NO;
    [UIView animateWithDuration:0.3 delay:0 usingSpringWithDamping:0.8 initialSpringVelocity:0 options:0 animations:^{
        CGFloat k = [self knobSize];
        self->_knob.frame = CGRectMake(4, 4, k, k);
        [self setProgress:0];
    } completion:nil];
}
- (void)pan:(UIPanGestureRecognizer *)g {
    if (_done) return;
    CGFloat x = [g locationInView:self].x, maxX = [self maxX];
    if (maxX <= 4) return;
    switch (g.state) {
        case UIGestureRecognizerStateBegan:
            _dragging = YES;
            _grabOffset = x - _knob.frame.origin.x;
            if (_grabOffset < 0 || _grabOffset > [self knobSize]) _grabOffset = [self knobSize] / 2;
            break;
        case UIGestureRecognizerStateChanged: {
            CGRect f = _knob.frame;
            f.origin.x = MIN(MAX(4, x - _grabOffset), maxX);
            _knob.frame = f;
            [self setProgress:(f.origin.x - 4) / (maxX - 4)];
            break;
        }
        case UIGestureRecognizerStateEnded: {
            CGFloat p = (_knob.frame.origin.x - 4) / (maxX - 4);
            if (p > 0.85) {
                _done = YES; _dragging = NO;
                [UIView animateWithDuration:0.12 animations:^{
                    CGRect f = self->_knob.frame; f.origin.x = maxX; self->_knob.frame = f;
                    [self setProgress:1];
                } completion:^(BOOL fin) {
                    [[[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium] impactOccurred];
                    if (self.fired) self.fired(self);
                }];
            } else {
                [self reset];
            }
            break;
        }
        case UIGestureRecognizerStateCancelled:
        case UIGestureRecognizerStateFailed:
            [self reset];
            break;
        default: break;
    }
}
@end

// ---- the real thing: iOS's own slider (_UIActionSlider), configured from the stock one ----
static void PPFire(UIView *slider) {
    if (slider.tag == 1) { PPRespring(); return; }
    if (slider.tag == 2) {
        PPUserspace(slider);
        // still here in a few seconds means the reboot didn't happen; put the knob back
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            @try { [slider setValue:@0.0 forKey:@"knobPosition"]; } @catch (__unused NSException *e) {}
        });
    }
}

@interface PPSliderDelegate : NSObject
@end
@implementation PPSliderDelegate
+ (instancetype)shared { static PPSliderDelegate *d; static dispatch_once_t o; dispatch_once(&o, ^{ d = [PPSliderDelegate new]; }); return d; }
- (void)actionSliderDidCompleteSlide:(UIView *)slider { PPFire(slider); }
- (void)actionSliderDidBeginSlide:(UIView *)slider {}
- (void)actionSliderDidCancelSlide:(UIView *)slider {}
- (void)actionSlider:(UIView *)slider didUpdateSlideWithValue:(double)value {}
// Swallow any other delegate call the slider makes, so an unexpected one can't crash SpringBoard.
- (BOOL)respondsToSelector:(SEL)sel {
    if ([super respondsToSelector:sel]) return YES;
    return [NSStringFromSelector(sel) hasPrefix:@"actionSlider"];
}
- (NSMethodSignature *)methodSignatureForSelector:(SEL)sel {
    NSMethodSignature *sig = [super methodSignatureForSelector:sel];
    if (sig) return sig;
    NSString *name = NSStringFromSelector(sel);
    if (![name hasPrefix:@"actionSlider"]) return nil;
    NSMutableString *types = [NSMutableString stringWithString:@"v@:"];
    for (NSUInteger i = 0; i < name.length; i++) if ([name characterAtIndex:i] == ':') [types appendString:@"@"];
    return [NSMethodSignature signatureWithObjCTypes:types.UTF8String];
}
- (void)forwardInvocation:(NSInvocation *)inv {
    NSString *name = NSStringFromSelector(inv.selector);
    if ([name containsString:@"Complete"] && inv.methodSignature.numberOfArguments > 2) {
        __unsafe_unretained id slider = nil;
        [inv getArgument:&slider atIndex:2];
        if ([slider isKindOfClass:[UIView class]]) PPFire(slider);
    }
}
@end

static UIImage *PPGlyph(NSString *symbol, UIColor *color, CGFloat pointSize) {
    if (@available(iOS 13.0, *)) {
        UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:pointSize weight:UIImageSymbolWeightRegular];
        UIImage *img = [UIImage systemImageNamed:symbol withConfiguration:cfg];
        return [img imageWithTintColor:color renderingMode:UIImageRenderingModeAlwaysOriginal];
    }
    return nil;
}

// Build a second copy of the stock slider. Returns nil if anything about it isn't as expected.
static UIView *PPSystemSlider(UIView *stock, UIView *pdv, NSString *text, UIColor *color, NSString *symbol, NSInteger tag) {
    Class cls = objc_getClass("_UIActionSlider");
    if (!cls || ![stock isKindOfClass:cls]) return nil;
    @try {
        id vibrant = nil;
        @try { vibrant = [stock valueForKey:@"vibrantSettings"]; } @catch (__unused NSException *e) {}
        if (!vibrant) vibrant = CBIvar(pdv, "_vibrantSettings");
        SEL initSel = sel_registerName("initWithFrame:vibrantSettings:");
        UIView *sl = nil;
        if ([cls instancesRespondToSelector:initSel])
            sl = ((id (*)(id, SEL, CGRect, id))objc_msgSend)([cls alloc], initSel, stock.bounds, vibrant);
        else
            sl = [[cls alloc] initWithFrame:stock.bounds];
        if (![sl isKindOfClass:[UIView class]]) return nil;
        // same look as the one above it
        for (NSString *key in @[ @"style", @"textStyle", @"trackFont", @"trackSize", @"trackWidthProportion",
                                 @"knobWidth", @"knobInsets", @"knobImageOffset", @"knobColor" ]) {
            @try { id v = [stock valueForKey:key]; if (v) [sl setValue:v forKey:key]; } @catch (__unused NSException *e) {}
        }
        // shrink the font until the label fits beside the knob, the way "slide to power off" does
        @try {
            UIFont *font = [sl valueForKey:@"trackFont"];
            if (![font isKindOfClass:[UIFont class]]) font = [stock valueForKey:@"trackFont"];
            if ([font isKindOfClass:[UIFont class]]) {
                CGSize ts = stock.bounds.size;
                @try { CGSize t = [[stock valueForKey:@"trackSize"] CGSizeValue]; if (t.width > 60 && t.height > 30) ts = t; } @catch (__unused NSException *e) {}
                CGFloat knob = ts.height;
                @try { CGFloat k = [[stock valueForKey:@"knobWidth"] doubleValue]; if (k > 20 && k < ts.width / 2) knob = k; } @catch (__unused NSException *e) {}
                CGFloat avail = ts.width - knob - 44;
                CGFloat size = font.pointSize;
                while (size > 11 && [text sizeWithAttributes:@{ NSFontAttributeName: [font fontWithSize:size] }].width > avail) size -= 0.5;
                if (size < font.pointSize) [sl setValue:[font fontWithSize:size] forKey:@"trackFont"];
            }
        } @catch (__unused NSException *e) {}
        [sl setValue:text forKey:@"trackText"];
        CGFloat ps = 30;
        @try { UIImage *si = [stock valueForKey:@"knobImage"]; if ([si isKindOfClass:[UIImage class]] && si.size.height > 8) ps = si.size.height * 0.92; } @catch (__unused NSException *e) {}
        UIImage *glyph = PPGlyph(symbol, color, ps);
        if (glyph) [sl setValue:glyph forKey:@"knobImage"];
        [sl setValue:[PPSliderDelegate shared] forKey:@"delegate"];
        sl.tag = tag;
        return sl;
    } @catch (__unused NSException *e) { return nil; }
}

static UIColor *PPBlue(void)  { return [UIColor colorWithRed:0.10 green:0.45 blue:1.0 alpha:1]; }
static UIColor *PPGreen(void) { return [UIColor colorWithRed:0.13 green:0.72 blue:0.42 alpha:1]; }

static void PPLayout(UIView *pdv) {
    UIView *box = objc_getAssociatedObject(pdv, &kBarKey);
    if (!gEnabled) { box.hidden = YES; return; }
    UIView *stock = CBIvar(pdv, "_actionSlider");
    if (![stock isKindOfClass:[UIView class]] || !stock.superview) stock = nil;
    if (!box) {
        if (stock && (stock.bounds.size.width < 100 || stock.bounds.size.height < 30)) return;   // not laid out yet; try next pass
        box = [UIView new];
        NSArray *specs = @[ @[ @"slide to respring", PPBlue(), @"arrow.clockwise", @1 ],
                            @[ @"slide to reboot userspace", PPGreen(), @"arrow.triangle.2.circlepath", @2 ] ];
        for (NSArray *sp in specs) {
            NSInteger tag = [sp[3] integerValue];
            UIView *sl = stock ? PPSystemSlider(stock, pdv, sp[0], sp[1], sp[2], tag) : nil;
            if (!sl) {
                PPSlider *mine = [[PPSlider alloc] initWithTitle:sp[0] color:sp[1] symbol:sp[2]];
                mine.tag = tag;
                mine.fired = ^(PPSlider *s) {
                    if (s.tag == 1) PPRespring();
                    else {
                        PPUserspace(s);
                        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ [s reset]; });
                    }
                };
                sl = mine;
            }
            [box addSubview:sl];
        }
        objc_setAssociatedObject(pdv, &kBarKey, box, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    box.hidden = NO;
    if (box.superview != pdv) [pdv addSubview:box];
    if (pdv.subviews.lastObject != box) [pdv bringSubviewToFront:box];
    if (stock) box.alpha = stock.alpha;

    CGRect b = pdv.bounds;
    // same size as the stock slider, directly under it
    CGFloat w = MIN(b.size.width - 60, 330), h = 72, gap = 18;
    CGFloat x = (b.size.width - w) * 0.5, y = b.size.height * 0.30;
    if (stock) {
        CGRect sf = [stock convertRect:stock.bounds toView:pdv];
        if (sf.size.width > 120 && sf.size.height > 40 && sf.size.height < 140 && CGRectGetMaxY(sf) < b.size.height * 0.6) {
            w = sf.size.width; h = sf.size.height; x = sf.origin.x;
            y = CGRectGetMaxY(sf) + gap;
        }
    }
    CGFloat total = h * 2 + gap;
    UIView *cancel = CBIvar(pdv, "_cancelButton");
    if ([cancel isKindOfClass:[UIView class]] && cancel.superview) {
        CGRect cf = [cancel convertRect:cancel.bounds toView:pdv];
        if (cf.origin.y > b.size.height * 0.4 && y + total > cf.origin.y - 20) y = cf.origin.y - 20 - total;   // keep clear of Cancel
    }
    CGRect f = CGRectMake(x, y, w, total);
    if (!CGRectEqualToRect(box.frame, f)) box.frame = f;
    for (NSInteger tag = 1; tag <= 2; tag++) {
        UIView *sl = [box viewWithTag:tag], *wash = [box viewWithTag:tag + 10];
        CGRect sf = CGRectMake(0, (tag - 1) * (h + gap), w, h);
        if (!CGRectEqualToRect(sl.frame, sf)) sl.frame = sf;
        if (wash) {
            CGSize ts = CGSizeZero;
            @try { ts = [[sl valueForKey:@"trackSize"] CGSizeValue]; } @catch (__unused NSException *e) {}
            if (ts.width < 60 || ts.height < 30 || ts.width > w || ts.height > h) ts = CGSizeMake(w, h);
            CGRect wf = CGRectMake(sf.origin.x + (w - ts.width) / 2, sf.origin.y + (h - ts.height) / 2, ts.width, ts.height);
            if (!CGRectEqualToRect(wash.frame, wf)) wash.frame = wf;
            wash.layer.cornerRadius = ts.height / 2;
        }
    }
}

static void PPPrefsChanged(CFNotificationCenterRef c, void *o, CFStringRef n, const void *obj, CFDictionaryRef i) {
    dispatch_async(dispatch_get_main_queue(), ^{ PPLoadPrefs(); });
}

__attribute__((constructor)) static void PPInit(void) {
    @autoreleasepool {
        if (!CBIsSpringBoard()) return;
        PPLoadPrefs();
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, PPPrefsChanged,
                                        CFSTR("com.mymculture.powerplus/prefs"), NULL,
                                        CFNotificationSuspensionBehaviorDeliverImmediately);
        Class cls = objc_getClass("SBUIPowerDownView");
        SEL sel = @selector(layoutSubviews);
        __block IMP orig = NULL;
        orig = CBHook(cls, sel, ^(UIView *self) {
            ((void (*)(id, SEL))orig)(self, sel);
            @try { PPLayout(self); } @catch (__unused NSException *e) {}
        });
    }
}
