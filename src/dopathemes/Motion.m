// DopaThemes Motion - animated backgrounds for the DopaThemes themes.
//
// The themes themselves are built into the Dopamine app (see patch.m), each with a still
// background, so they work without a jailbreak. When the jailbreak is active this small add-on
// loads into Dopamine and plays the theme's "motion" on top of that still image: the same soft
// colour blobs the image was drawn from, slowly drifting and breathing, plus a faint light sweep.
//
// Where it hooks: -[DONavigationController setupBackground] builds Dopamine's background image
// view. We add our animated view inside it, so Dopamine's own dimming (when a menu is open) and
// layout apply to it unchanged. Themes without a "motion" entry (the stock ones) are left alone.
// Respects Settings > Accessibility > Motion > Reduce Motion.
#import "../common/cb.h"

static UIColor *DTColor(NSString *hex, CGFloat alpha) {
    unsigned int v = 0;
    [[NSScanner scannerWithString:hex ?: @"000000"] scanHexInt:&v];
    return [UIColor colorWithRed:((v >> 16) & 0xFF) / 255.0 green:((v >> 8) & 0xFF) / 255.0 blue:(v & 0xFF) / 255.0 alpha:alpha];
}

// The enabled theme's "motion" entry, read from the app's own Themes.plist (where patch.m put it).
static NSDictionary *DTMotionForEnabledTheme(void) {
    id mgr = CBSendID(objc_getClass("DOThemeManager"), "sharedInstance");
    NSString *key = CBSendID(CBSendID(mgr, "enabledTheme"), "key");
    if (![key isKindOfClass:[NSString class]]) return nil;
    NSArray *themes = [NSArray arrayWithContentsOfFile:[[NSBundle mainBundle] pathForResource:@"Themes" ofType:@"plist"]];
    for (NSDictionary *t in themes) {
        if (![t isKindOfClass:[NSDictionary class]] || ![t[@"key"] isEqual:key]) continue;
        NSDictionary *m = t[@"motion"];
        return ([m isKindOfClass:[NSDictionary class]] && [m[@"blobs"] isKindOfClass:[NSArray class]]) ? m : nil;
    }
    return nil;
}

@interface DTMotionView : UIView
@property (nonatomic, copy) NSArray<NSDictionary *> *blobs;
@property (nonatomic, strong) NSMutableArray<CAGradientLayer *> *blobLayers;
@property (nonatomic, strong) CAGradientLayer *sweep;
@property (nonatomic) CGSize laidOutFor;
@end

@implementation DTMotionView

- (instancetype)initWithMotion:(NSDictionary *)motion {
    if (!(self = [super initWithFrame:CGRectZero])) return nil;
    self.userInteractionEnabled = NO;
    self.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.backgroundColor = DTColor(motion[@"base"], 1);
    self.blobs = motion[@"blobs"];
    self.blobLayers = [NSMutableArray array];

    // Each blob is a radial gradient shaped like the Gaussian the still image was drawn with:
    // alpha = strength * exp(-d^2 / 2sigma^2), out to 3 sigma. Painted in order, like the image.
    for (NSDictionary *b in self.blobs) {
        if (![b isKindOfClass:[NSDictionary class]]) continue;
        CGFloat strength = [b[@"strength"] doubleValue];
        CAGradientLayer *g = [CAGradientLayer layer];
        g.type = kCAGradientLayerRadial;
        g.startPoint = CGPointMake(0.5, 0.5);
        g.endPoint = CGPointMake(1, 1);
        NSMutableArray *colors = [NSMutableArray array], *locs = [NSMutableArray array];
        for (int i = 0; i <= 8; i++) {
            CGFloat t = i / 8.0, d = t * 3.0;   // distance in sigmas
            [colors addObject:(id)DTColor(b[@"color"], strength * exp(-d * d / 2)).CGColor];
            [locs addObject:@(t)];
        }
        g.colors = colors;
        g.locations = locs;
        g.shouldRasterize = YES;            // draw the gradient once, then just move it around
        g.rasterizationScale = 0.5;          // it's a soft blur; half resolution is invisible
        [self.layer addSublayer:g];
        [self.blobLayers addObject:g];
    }

    // The faint diagonal light band from the still image, drifting slowly back and forth.
    CAGradientLayer *s = [CAGradientLayer layer];
    UIColor *clear = [UIColor colorWithWhite:1 alpha:0], *lit = [UIColor colorWithWhite:1 alpha:0.05];
    s.colors = @[(id)clear.CGColor, (id)lit.CGColor, (id)clear.CGColor];
    s.locations = @[@0.3, @0.5, @0.7];
    s.startPoint = CGPointMake(0, 0.3);
    s.endPoint = CGPointMake(1, 0.7);
    [self.layer addSublayer:s];
    self.sweep = s;
    return self;
}

// Same mapping as Dopamine's aspect-fill of the 3:2 still image: height fills the view,
// width is 1.5x the height, centred. Image units: y in [0,1], x in [0,1] across the width.
- (CGPoint)pointForX:(CGFloat)x y:(CGFloat)y size:(CGSize)sz {
    CGFloat h = MAX(sz.height, sz.width / 1.5), w = h * 1.5;
    return CGPointMake(sz.width / 2 + (x - 0.5) * w, sz.height / 2 + (y - 0.5) * h);
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGSize sz = self.bounds.size;
    if (sz.width < 1 || CGSizeEqualToSize(sz, self.laidOutFor)) return;
    self.laidOutFor = sz;
    CGFloat h = MAX(sz.height, sz.width / 1.5);

    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    NSUInteger i = 0;
    for (NSDictionary *b in self.blobs) {
        if (![b isKindOfClass:[NSDictionary class]] || i >= self.blobLayers.count) continue;
        CAGradientLayer *g = self.blobLayers[i];
        CGFloat sigma = [b[@"r"] doubleValue] * 0.55 * h, side = sigma * 6;
        g.bounds = CGRectMake(0, 0, side, side);
        g.position = [self pointForX:[b[@"x"] doubleValue] y:[b[@"y"] doubleValue] size:sz];
        [self animateBlob:g index:i height:h];
        i++;
    }
    CGFloat big = MAX(sz.width, sz.height) * 2;
    self.sweep.bounds = CGRectMake(0, 0, big, big);
    self.sweep.position = CGPointMake(sz.width / 2, sz.height / 2);
    [self animateSweep:h];
    [CATransaction commit];
}

// A slow, uneven loop per blob (each with its own speed and direction), plus a gentle
// breathing scale. Additive, so the layout above stays the resting position.
- (void)animateBlob:(CALayer *)g index:(NSUInteger)i height:(CGFloat)h {
    [g removeAllAnimations];
    CGFloat amp = h * 0.07, dir = (i % 2) ? -1 : 1;
    // A wobbly closed loop; offsets are relative to where it starts, so frame 0 is the resting spot.
    CGPoint (^loop)(CGFloat) = ^CGPoint(CGFloat a) {
        return CGPointMake(amp * cos(a) + amp * 0.35 * cos(2 * a + i), amp * 0.8 * sin(a) + amp * 0.25 * sin(3 * a));
    };
    CGPoint p0 = loop(i * 1.7);
    NSMutableArray *pts = [NSMutableArray array];
    for (int k = 0; k <= 24; k++) {
        CGPoint p = loop(dir * k / 24.0 * 2 * M_PI + i * 1.7);
        [pts addObject:[NSValue valueWithCGPoint:CGPointMake(p.x - p0.x, p.y - p0.y)]];
    }
    CAKeyframeAnimation *drift = [CAKeyframeAnimation animationWithKeyPath:@"position"];
    drift.values = pts;
    drift.additive = YES;
    drift.calculationMode = kCAAnimationCubicPaced;
    drift.duration = 18 + 5 * (i % 3) + 1.3 * i;
    drift.repeatCount = HUGE_VALF;
    drift.removedOnCompletion = NO;
    [g addAnimation:drift forKey:@"dt.drift"];

    CABasicAnimation *breathe = [CABasicAnimation animationWithKeyPath:@"transform.scale"];
    breathe.fromValue = @0.9;
    breathe.toValue = @1.12;
    breathe.duration = 7 + 2.5 * (i % 3);
    breathe.autoreverses = YES;
    breathe.repeatCount = HUGE_VALF;
    breathe.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
    breathe.timeOffset = i * 2.1;
    breathe.removedOnCompletion = NO;
    [g addAnimation:breathe forKey:@"dt.breathe"];
}

- (void)animateSweep:(CGFloat)h {
    [self.sweep removeAllAnimations];
    CABasicAnimation *a = [CABasicAnimation animationWithKeyPath:@"position.x"];
    a.byValue = @(h * 0.35);
    a.duration = 16;
    a.autoreverses = YES;
    a.repeatCount = HUGE_VALF;
    a.additive = YES;
    a.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
    a.removedOnCompletion = NO;
    [self.sweep addAnimation:a forKey:@"dt.sweep"];
}

@end

static void DTInstall(void) {
    Class nav = objc_getClass("DONavigationController");
    if (!nav) return;   // not Dopamine 2.x
    SEL setup = sel_registerName("setupBackground");
    __block IMP orig = CBHook(nav, setup, ^(UIViewController *self) {
        ((void (*)(id, SEL))orig)(self, setup);
        if (UIAccessibilityIsReduceMotionEnabled()) return;
        NSDictionary *motion = DTMotionForEnabledTheme();
        UIImageView *bg = CBSendID(self, "backgroundImageView");
        if (!motion || ![bg isKindOfClass:[UIImageView class]]) return;
        DTMotionView *mv = [[DTMotionView alloc] initWithMotion:motion];
        mv.frame = bg.bounds;
        [bg addSubview:mv];
        bg.clipsToBounds = YES;
    });
}

__attribute__((constructor)) static void DTMotionInit(void) {
    @autoreleasepool { DTInstall(); }
}
