// DoubleDose 1.0 - lets a duplicated Dopamine run its jailbreak while the phone is already jailbroken.
//
// How Dopamine locks the button (Application/Dopamine/UI/DOMainViewController.m):
//   jailbreakBtn.enabled = !(isJailbroken || isJailbrokenWithOtherJailbreak) && isSupported
// A duplicate has a different bundle ID from the copy that did the jailbreak, so Dopamine's
// own "is jailbroken" call is refused and returns NO, but isJailbrokenWithOtherJailbreak then
// sees /usr/lib/systemhook.dylib and returns YES. We make both answer NO.
//
// Dopamine never injects tweaks into the copy that performed the jailbreak, so that one is
// left alone no matter what. Trollamine is skipped on purpose.
#import "../common/cb.h"

#define DD_DOMAIN CFSTR("com.mymculture.doubledose")

static BOOL DDEnabled(void) {
    for (NSString *p in @[@"/var/jb/var/mobile/Library/Preferences/com.mymculture.doubledose.plist",
                          @"/var/mobile/Library/Preferences/com.mymculture.doubledose.plist"]) {
        NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:p];
        id v = d[@"Enabled"];
        if ([v respondsToSelector:@selector(boolValue)]) return [v boolValue];
    }
    CFPreferencesAppSynchronize(DD_DOMAIN);
    return CBPrefBool(DD_DOMAIN, CFSTR("Enabled"), YES);
}

static BOOL DDInstall(void) {
    static BOOL done;
    if (done) return YES;
    Class c = objc_getClass("DOEnvironmentManager");
    if (!c) return NO;
    CBHook(c, sel_registerName("isJailbroken"), ^BOOL(id self) { return NO; });
    CBHook(c, sel_registerName("isJailbrokenWithOtherJailbreak"), ^BOOL(id self) { return NO; });
    done = YES;
    NSLog(@"[DoubleDose] jailbroken checks bypassed in %@", [[NSBundle mainBundle] bundleIdentifier]);
    return YES;
}

__attribute__((constructor)) static void DDInit(void) {
    @autoreleasepool {
        NSString *bid = [[NSBundle mainBundle] bundleIdentifier];
        if ([bid isEqualToString:@"com.mymculture.trollamine"]) return;
        if (!DDEnabled()) return;
        if (DDInstall()) return;
        // Class not registered yet: try again once the app has launched.
        [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidFinishLaunchingNotification
            object:nil queue:nil usingBlock:^(NSNotification *n) { DDInstall(); }];
    }
}
