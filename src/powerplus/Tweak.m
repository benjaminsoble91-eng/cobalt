// PowerPlus - adds slide-to-respring and slide-to-reboot-userspace sliders to the power-off screen.
#import "../common/cb.h"
#import <spawn.h>
#import <sys/wait.h>

#define PP_DOMAIN CFSTR("com.mymculture.powerplus")
#define PP_HELPER "/var/jb/usr/libexec/powerplus-helper"
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

static void PPLayout(UIView *pdv) {
    UIView *box = objc_getAssociatedObject(pdv, &kBarKey);
    if (!gEnabled) { box.hidden = YES; return; }
    if (!box) {
        box = [UIView new];
        PPSlider *respring = [[PPSlider alloc] initWithTitle:@"slide to respring"
                                                       color:[UIColor colorWithRed:0.10 green:0.45 blue:1.0 alpha:1]
                                                      symbol:@"arrow.clockwise"];
        respring.tag = 1;
        respring.fired = ^(PPSlider *s) { PPRespring(); };
        PPSlider *userspace = [[PPSlider alloc] initWithTitle:@"slide to reboot userspace"
                                                        color:[UIColor colorWithRed:0.13 green:0.72 blue:0.42 alpha:1]
                                                       symbol:@"arrow.triangle.2.circlepath"];
        userspace.tag = 2;
        userspace.fired = ^(PPSlider *s) {
            PPUserspace(s);
            // if we're still here in a few seconds the reboot didn't happen; let them try again
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ [s reset]; });
        };
        [box addSubview:respring];
        [box addSubview:userspace];
        objc_setAssociatedObject(pdv, &kBarKey, box, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    box.hidden = NO;
    if (box.superview != pdv) [pdv addSubview:box];
    if (pdv.subviews.lastObject != box) [pdv bringSubviewToFront:box];

    CGRect b = pdv.bounds;
    // match the stock slider's size and sit right under it when we can find it
    CGFloat w = MIN(b.size.width - 60, 330), h = 72, gap = 18;
    CGFloat x = (b.size.width - w) * 0.5, y = b.size.height * 0.30;
    UIView *stock = CBIvar(pdv, "_actionSlider");
    if ([stock isKindOfClass:[UIView class]] && stock.superview) {
        CGRect sf = [stock convertRect:stock.bounds toView:pdv];
        if (sf.size.width > 120 && sf.size.height > 40 && sf.size.height < 120 && CGRectGetMaxY(sf) < b.size.height * 0.6) {
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
    CGRect f1 = CGRectMake(0, 0, w, h), f2 = CGRectMake(0, h + gap, w, h);
    UIView *s1 = [box viewWithTag:1], *s2 = [box viewWithTag:2];
    if (!CGRectEqualToRect(s1.frame, f1)) s1.frame = f1;
    if (!CGRectEqualToRect(s2.frame, f2)) s2.frame = f2;
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
