// PowerPlus - adds Respring, Userspace Reboot and Safe Mode to the power-off screen.
#import "../common/cb.h"
#import <spawn.h>
#import <signal.h>
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

static void PPSafeMode(void) {
    // a SpringBoard crash is what sends the tweak loader into Safe Mode
    signal(SIGSEGV, SIG_DFL);
    raise(SIGSEGV);
    volatile int *p = NULL; *p = 1;
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
            PPAlert(from, @"Userspace Reboot", @"This jailbreak didn't allow a userspace reboot from here. Respring and Safe Mode still work.");
        });
    });
}

@interface PPTarget : NSObject
@end
@implementation PPTarget
+ (instancetype)shared { static PPTarget *t; static dispatch_once_t o; dispatch_once(&o, ^{ t = [PPTarget new]; }); return t; }
- (void)tap:(UIButton *)b {
    switch (b.tag) {
        case 1: PPRespring(); break;
        case 2: PPUserspace(b); break;
        case 3: PPSafeMode(); break;
    }
}
@end

static UIButton *PPButton(NSString *title, NSInteger tag) {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    b.tag = tag;
    [b setTitle:title forState:UIControlStateNormal];
    [b setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    b.titleLabel.adjustsFontSizeToFitWidth = YES;
    b.titleLabel.minimumScaleFactor = 0.7;
    b.backgroundColor = [UIColor colorWithWhite:1 alpha:0.22];
    b.layer.cornerRadius = 23;
    b.layer.masksToBounds = YES;
    b.contentEdgeInsets = UIEdgeInsetsMake(0, 10, 0, 10);
    [b addTarget:[PPTarget shared] action:@selector(tap:) forControlEvents:UIControlEventTouchUpInside];
    return b;
}

static void PPLayout(UIView *pdv) {
    UIStackView *bar = objc_getAssociatedObject(pdv, &kBarKey);
    if (!gEnabled) { bar.hidden = YES; return; }
    if (!bar) {
        bar = [[UIStackView alloc] initWithArrangedSubviews:@[
            PPButton(@"Respring", 1), PPButton(@"Userspace", 2), PPButton(@"Safe Mode", 3)]];
        bar.axis = UILayoutConstraintAxisHorizontal;
        bar.distribution = UIStackViewDistributionFillEqually;
        bar.spacing = 10;
        objc_setAssociatedObject(pdv, &kBarKey, bar, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    bar.hidden = NO;
    if (bar.superview != pdv) [pdv addSubview:bar];
    if (pdv.subviews.lastObject != bar) [pdv bringSubviewToFront:bar];
    CGRect b = pdv.bounds;
    CGFloat w = MIN(b.size.width - 40, 420), h = 46;
    CGFloat y = b.size.height * 0.66;
    UIView *cancel = CBIvar(pdv, "_cancelButton");
    if ([cancel isKindOfClass:[UIView class]] && cancel.superview) {
        CGRect cf = [cancel convertRect:cancel.bounds toView:pdv];
        if (cf.origin.y > b.size.height * 0.4) y = cf.origin.y - h - 34;
    }
    CGRect f = CGRectMake((b.size.width - w) * 0.5, y, w, h);
    if (!CGRectEqualToRect(bar.frame, f)) bar.frame = f;
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
