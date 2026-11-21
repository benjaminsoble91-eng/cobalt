// PanicButton 1.0.1 — a "Trigger Kernel Panic" button in Settings.
//
// Settings (Preferences app): the button calls -triggerPanic: on the list controller, which
// this tweak adds, and it just posts a Darwin notification to SpringBoard.
//
// SpringBoard: shows a system alert (drawn over whatever app is open) and only spawns the
// suid helper if "Panic Now" is tapped. Because SpringBoard asks for itself, another app
// posting the same notification can't panic the phone without the user agreeing.
#import "../common/cb.h"
#import <dlfcn.h>
#import <spawn.h>
#import <sys/wait.h>

#define PB_DOMAIN  CFSTR("com.mymculture.panicbutton")
#ifndef JBROOT
#define JBROOT "/var/jb"   /* "" for rootful builds (set by build.sh) */
#endif
#define PB_HELPER  JBROOT "/usr/libexec/panicbutton-helper"
#define PB_TRIGGER "com.mymculture.panicbutton/trigger"

extern char **environ;
static BOOL gEnabled = YES;
static volatile BOOL gBusy;

static void PBLoadPrefs(void) {
    CFPreferencesAppSynchronize(PB_DOMAIN);
    gEnabled = CBPrefBool(PB_DOMAIN, CFSTR("Enabled"), YES);
}

// CFUserNotification is in CoreFoundation on iOS but hidden from the SDK headers.
typedef SInt32 (*PBAlertFn)(CFTimeInterval, CFOptionFlags, CFURLRef, CFURLRef, CFURLRef,
                            CFStringRef, CFStringRef, CFStringRef, CFStringRef, CFStringRef, CFOptionFlags *);
static PBAlertFn PBAlertFunc(void) {
    static PBAlertFn fn; static dispatch_once_t once;
    dispatch_once(&once, ^{ fn = (PBAlertFn)dlsym(RTLD_DEFAULT, "CFUserNotificationDisplayAlert"); });
    return fn;
}
// Blocks until a button is tapped, so it must never run on SpringBoard's main thread.
// Returns 0 for the first button, 1 for the second, -1 if the alert couldn't be shown.
static int PBAsk(NSString *title, NSString *msg, NSString *first, NSString *second) {
    PBAlertFn fn = PBAlertFunc();
    if (!fn) return -1;
    CFOptionFlags resp = 0;
    SInt32 err = fn(0, 0 /* plain alert */, NULL, NULL, NULL,
                    (__bridge CFStringRef)title, (__bridge CFStringRef)msg,
                    (__bridge CFStringRef)first, (__bridge CFStringRef)second, NULL, &resp);
    if (err != 0) return -1;
    return (int)(resp & 0x3);   // 0 = default (first), 1 = alternate (second)
}

static NSString *PBReason(int status) {
    int code = WIFEXITED(status) ? WEXITSTATUS(status) : -1;
    switch (code) {
        case 2:  return @"The helper was called the wrong way. Reinstall PanicButton.";
        case 3:  return @"The helper isn't running as root (setuid didn't take). Reinstall PanicButton.";
        case 10: return @"The kernel refused the panic request (permission denied).";
        case 11: return @"The kernel refused the panic request.";
        case -1: return @"The helper couldn't be started. Is PanicButton fully installed?";
        default: return [NSString stringWithFormat:@"The helper stopped with status %d.", code];
    }
}

// Runs on a background queue.
static void PBRun(void) {
    if (!gEnabled || gBusy) return;
    gBusy = YES;
    int choice = PBAsk(@"Kernel Panic",
                       @"This will immediately crash the kernel and reboot the phone. Anything unsaved is lost and you will need to re-jailbreak.\n\nA panic log will be saved in Settings → Privacy → Analytics.",
                       @"Cancel", @"Panic Now");
    if (choice == 1) {
        int status = -1;
        pid_t pid = 0;
        char *argv[] = { (char *)PB_HELPER, (char *)"panic", NULL };
        if (access(PB_HELPER, X_OK) == 0 && posix_spawn(&pid, PB_HELPER, NULL, NULL, argv, environ) == 0)
            waitpid(pid, &status, 0);
        // Still here: the panic didn't happen.
        sleep(1);
        PBAsk(@"Panic Failed", PBReason(status), @"OK", nil);
    }
    gBusy = NO;
}

static void PBTrigger(CFNotificationCenterRef c, void *o, CFStringRef n, const void *obj, CFDictionaryRef i) {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{ PBRun(); });
}
static void PBPrefsChanged(CFNotificationCenterRef c, void *o, CFStringRef n, const void *obj, CFDictionaryRef i) {
    dispatch_async(dispatch_get_main_queue(), ^{ PBLoadPrefs(); });
}

// ---- Settings side --------------------------------------------------------
static void PBAddButtonAction(void) {
    Class cls = objc_getClass("PSListController");
    if (!cls) return;
    void (^post)(id, id) = ^(id self, id specifier) { notify_post(PB_TRIGGER); };
    // the plist names the action "triggerPanic"; accept both spellings, never replace an existing method
    for (NSString *name in @[ @"triggerPanic", @"triggerPanic:" ]) {
        SEL s = NSSelectorFromString(name);
        if (!class_getInstanceMethod(cls, s))
            class_addMethod(cls, s, imp_implementationWithBlock(post), "v@:@");
    }
}

__attribute__((constructor)) static void PBInit(void) {
    @autoreleasepool {
        NSString *bid = [[NSBundle mainBundle] bundleIdentifier];
        if ([bid isEqualToString:@"com.apple.Preferences"]) {
            PBAddButtonAction();
            if (!objc_getClass("PSListController"))
                [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidFinishLaunchingNotification
                    object:nil queue:nil usingBlock:^(NSNotification *n) { PBAddButtonAction(); }];
            return;
        }
        if (!CBIsSpringBoard()) return;
        PBLoadPrefs();
        CFNotificationCenterRef dc = CFNotificationCenterGetDarwinNotifyCenter();
        CFNotificationCenterAddObserver(dc, NULL, PBPrefsChanged, CFSTR("com.mymculture.panicbutton/prefs"), NULL,
                                        CFNotificationSuspensionBehaviorDeliverImmediately);
        CFNotificationCenterAddObserver(dc, NULL, PBTrigger, CFSTR(PB_TRIGGER), NULL,
                                        CFNotificationSuspensionBehaviorDeliverImmediately);
    }
}
