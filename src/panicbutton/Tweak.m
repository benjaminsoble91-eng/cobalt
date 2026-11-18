// PanicButton 1.0 — adds a "Trigger Kernel Panic" button to Settings.
// Presents a confirmation alert, then spawns the suid helper which
// acquires kernel R/W via libjailbreak and writes to an unmapped address.
#import "../common/cb.h"
#import <spawn.h>
#import <sys/wait.h>

#define PB_DOMAIN  CFSTR("com.mymculture.panicbutton")
#define PB_HELPER  "/var/jb/usr/libexec/panicbutton-helper"

extern char **environ;
static BOOL gEnabled = YES;

static void PBLoadPrefs(void) {
    CFPreferencesAppSynchronize(PB_DOMAIN);
    gEnabled = CBPrefBool(PB_DOMAIN, CFSTR("Enabled"), YES);
}

static void PBAlert(UIView *from, NSString *title, NSString *msg) {
    UIViewController *vc = from.window.rootViewController;
    while (vc.presentedViewController) vc = vc.presentedViewController;
    if (!vc) return;
    UIAlertController *a = [UIAlertController alertControllerWithTitle:title message:msg preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
    [vc presentViewController:a animated:YES completion:nil];
}

static void PBFirePanic(UIView *from) {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        int status = -1;
        if (access(PB_HELPER, X_OK) == 0) {
            pid_t pid = 0;
            char *argv[] = { (char *)PB_HELPER, (char *)"panic", NULL };
            if (posix_spawn(&pid, PB_HELPER, NULL, NULL, argv, environ) == 0)
                waitpid(pid, &status, 0);
        }
        // If we reach here, the panic didn't happen
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            int code = WIFEXITED(status) ? WEXITSTATUS(status) : -1;
            NSString *msg;
            switch (code) {
                case 3:  msg = @"Helper is not running as root. Reinstall PanicButton."; break;
                case 4:  msg = @"Could not load libjailbreak. Are you jailbroken?"; break;
                case 7:  msg = @"Could not acquire kernel R/W. The jailbreak may not support it from this process."; break;
                case 8:  msg = @"kwritebuf not available after init."; break;
                case 9:  msg = @"kwrite returned without panicking. Unexpected."; break;
                default: msg = [NSString stringWithFormat:@"Helper failed with status %d.", code]; break;
            }
            PBAlert(from, @"Panic Failed", msg);
        });
    });
}

static void PBConfirmAndFire(UIView *from) {
    UIViewController *vc = from.window.rootViewController;
    while (vc.presentedViewController) vc = vc.presentedViewController;
    if (!vc) return;
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"Kernel Panic"
        message:@"This will immediately crash the kernel and reboot the phone. You will need to re-jailbreak afterwards.\n\nContinue?"
        preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [a addAction:[UIAlertAction actionWithTitle:@"Panic Now" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *act) {
        PBFirePanic(from);
    }]];
    [vc presentViewController:a animated:YES completion:nil];
}

// Hook into SpringBoard to listen for the trigger notification
static void PBPrefsChanged(CFNotificationCenterRef c, void *o, CFStringRef n, const void *obj, CFDictionaryRef i) {
    dispatch_async(dispatch_get_main_queue(), ^{ PBLoadPrefs(); });
}

static void PBTriggerNotif(CFNotificationCenterRef c, void *o, CFStringRef n, const void *obj, CFDictionaryRef i) {
    if (!gEnabled) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *win = nil;
        for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
            if ([scene isKindOfClass:objc_getClass("UIWindowScene")]) {
                NSArray *windows = [scene valueForKey:@"windows"];
                for (UIWindow *w in windows) {
                    if (w.isKeyWindow) { win = w; break; }
                }
                if (win) break;
            }
        }
        if (!win) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
            for (UIWindow *w in [UIApplication sharedApplication].windows) {
                if (w.isKeyWindow) { win = w; break; }
            }
#pragma clang diagnostic pop
        }
        if (win) PBConfirmAndFire(win);
    });
}

__attribute__((constructor)) static void PBInit(void) {
    @autoreleasepool {
        if (!CBIsSpringBoard()) return;
        PBLoadPrefs();
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, PBPrefsChanged,
            CFSTR("com.mymculture.panicbutton/prefs"), NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, PBTriggerNotif,
            CFSTR("com.mymculture.panicbutton/trigger"), NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
    }
}
