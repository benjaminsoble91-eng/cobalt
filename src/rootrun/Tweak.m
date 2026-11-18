// RootRun 1.0 — make a chosen app launch as root (uid 0) on your own jailbroken device.
//
// How it works:
//   * The dylib is injected into every app (Filter: Classes = UIApplication) and also into
//     the Settings app (Filter: Executables = Preferences) for the picker pane.
//   * In Settings, RootRun registers a PSListController subclass (built at runtime, so it
//     needs no private-framework stubs to link) that lists your installed apps, each with a
//     switch. Toggling an app writes its bundle id into the "Apps" dict in com.mymculture.rootrun.
//   * In any other app, the constructor checks that dict. If this app is switched on (and the
//     master Enabled switch is on), it raises the process to root before the app's own code
//     runs by calling setgid(0)/setuid(0). On Dopamine, if the plain POSIX call is refused it
//     falls back to libjailbreak's root-steal (looked up with dlsym, so nothing breaks if it
//     isn't there).
//
// This only elevates apps on the phone it's installed on — it's the jailbreak equivalent of
// launching something with sudo. Nothing leaves the device and no other app is touched.

#import "../common/cb.h"
#import <dlfcn.h>
#import <unistd.h>

#define RR_DOMAIN CFSTR("com.mymculture.rootrun")

// PSCellType values we use.
enum { RR_PSGroupCell = 0, RR_PSSwitchCell = 6 };

// ---- shared pref helpers --------------------------------------------------
static BOOL RRMasterEnabled(void) {
    CFPreferencesAppSynchronize(RR_DOMAIN);
    return CBPrefBool(RR_DOMAIN, CFSTR("Enabled"), YES);
}
// The set of bundle ids the user switched on, stored as a dict { bundleid = <bool> }.
static NSDictionary *RRAppsDict(void) {
    CFPreferencesAppSynchronize(RR_DOMAIN);
    CFPropertyListRef v = CFPreferencesCopyAppValue(CFSTR("Apps"), RR_DOMAIN);
    NSDictionary *d = nil;
    if (v) {
        if (CFGetTypeID(v) == CFDictionaryGetTypeID()) d = [(__bridge NSDictionary *)v copy];
        CFRelease(v);
    }
    return d ?: @{};
}
static BOOL RRWantsRoot(NSString *bundleID) {
    if (!bundleID) return NO;
    id on = RRAppsDict()[bundleID];
    return [on respondsToSelector:@selector(boolValue)] && [on boolValue];
}
static void RRSetWantsRoot(NSString *bundleID, BOOL want) {
    if (!bundleID) return;
    NSMutableDictionary *apps = [RRAppsDict() mutableCopy];
    if (want) apps[bundleID] = @YES; else [apps removeObjectForKey:bundleID];
    CFPreferencesSetAppValue(CFSTR("Apps"), (__bridge CFPropertyListRef)apps, RR_DOMAIN);
    CFPreferencesAppSynchronize(RR_DOMAIN);
}

// ---- elevation (runs inside the target app, before its own code) ----------
static BOOL RRElevate(void) {
    if (geteuid() == 0) return YES;           // already root, nothing to do
    setgid(0); setuid(0);
    if (geteuid() == 0) return YES;           // plain POSIX path worked (rootful / platformised)

    // Dopamine path: libjailbreak can hand a process root. Look it up at runtime so RootRun
    // still loads cleanly on jailbreaks that don't ship these symbols.
    int (*root_steal)(void)   = (int(*)(void))  dlsym(RTLD_DEFAULT, "jbclient_root_steal");
    if (root_steal) { root_steal(); if (geteuid() == 0) return YES; }

    // Older libjailbreak spelling.
    int (*proc_root)(pid_t)   = (int(*)(pid_t)) dlsym(RTLD_DEFAULT, "jbdswProcSetRoot");
    if (proc_root) { proc_root(getpid()); setuid(0); if (geteuid() == 0) return YES; }

    return geteuid() == 0;
}

// ===========================================================================
//  Settings — app picker, built entirely through the runtime so it links
//  against nothing private.
// ===========================================================================
static id RRMsgCls(const char *cls, const char *sel) {
    Class c = objc_getClass(cls);
    if (!c) return nil;
    return ((id (*)(id, SEL))objc_msgSend)((id)c, sel_registerName(sel));
}

// [PSSpecifier preferenceSpecifierNamed:name target:t set:s get:g detail:Nil cell:cell edit:Nil]
static id RRSpec(NSString *name, id target, SEL set, SEL get, NSInteger cell) {
    Class PSSpecifier = objc_getClass("PSSpecifier");
    if (!PSSpecifier) return nil;
    SEL mk = sel_registerName("preferenceSpecifierNamed:target:set:get:detail:cell:edit:");
    return ((id (*)(id, SEL, NSString *, id, SEL, SEL, Class, NSInteger, Class))objc_msgSend)(
        (id)PSSpecifier, mk, name, target, set, get, Nil, cell, Nil);
}
static void RRSpecSet(id spec, id value, NSString *key) {
    if (!spec) return;
    ((void (*)(id, SEL, id, NSString *))objc_msgSend)(spec, sel_registerName("setProperty:forKey:"), value, key);
}
static id RRSpecGet(id spec, NSString *key) {
    if (!spec) return nil;
    return ((id (*)(id, SEL, NSString *))objc_msgSend)(spec, sel_registerName("propertyForKey:"), key);
}

// -- method implementations for the runtime PSListController subclass --------
static id RRController_specifiers(id self, SEL _cmd) {
    NSMutableArray *specs = [NSMutableArray array];

    id grp = RRSpec(@"", self, NULL, NULL, RR_PSGroupCell);
    RRSpecSet(grp, @"Switch an app on to make it launch as root. The change takes effect the "
                   @"next time that app is opened (force-quit it first if it's running).", @"footerText");
    if (grp) [specs addObject:grp];

    // LSApplicationWorkspace.defaultWorkspace.allApplications -> each app: bundleIdentifier,
    // localizedName, applicationType.
    id workspace = RRMsgCls("LSApplicationWorkspace", "defaultWorkspace");
    NSArray *apps = workspace ? CBSendID(workspace, "allApplications") : nil;

    NSMutableArray *rows = [NSMutableArray array];
    for (id app in apps) {
        NSString *bid  = CBSendID(app, "bundleIdentifier");
        NSString *name = CBSendID(app, "localizedName");
        NSString *type = CBSendID(app, "applicationType");
        if (!bid || !name) continue;
        if (type && ![type isEqualToString:@"User"]) continue;   // skip system apps/daemons
        if ([bid hasPrefix:@"com.apple."]) continue;
        [rows addObject:@[name, bid]];
    }
    [rows sortUsingComparator:^NSComparisonResult(NSArray *a, NSArray *b) {
        return [a[0] caseInsensitiveCompare:b[0]];
    }];

    for (NSArray *row in rows) {
        id s = RRSpec(row[0], self, sel_registerName("setValue:forApp:"),
                      sel_registerName("valueForApp:"), RR_PSSwitchCell);
        RRSpecSet(s, row[1], @"appBundleID");
        RRSpecSet(s, @NO, @"default");
        if (s) [specs addObject:s];
    }
    if (rows.count == 0) {
        id empty = RRSpec(@"", self, NULL, NULL, RR_PSGroupCell);
        RRSpecSet(empty, @"No user apps found.", @"footerText");
        if (empty) [specs addObject:empty];
    }
    return specs;
}
static id RRController_valueForApp(id self, SEL _cmd, id spec) {
    return @(RRWantsRoot(RRSpecGet(spec, @"appBundleID")));
}
static void RRController_setValueForApp(id self, SEL _cmd, id value, id spec) {
    RRSetWantsRoot(RRSpecGet(spec, @"appBundleID"), [value boolValue]);
}

// Build RRAppsController : PSListController at runtime (no compile-time link to Preferences).
// PSListController lives in Preferences.framework, which Settings loads lazily — so if it
// isn't up yet, force-load it first. Returns YES once the class exists.
static BOOL RRRegisterController(void) {
    if (objc_getClass("RRAppsController")) return YES;
    Class super = objc_getClass("PSListController");
    if (!super) {
        // Apple frameworks stay under /System even on rootless jailbreaks.
        dlopen("/System/Library/PrivateFrameworks/Preferences.framework/Preferences", RTLD_LAZY);
        super = objc_getClass("PSListController");
    }
    if (!super) return NO;
    Class c = objc_allocateClassPair(super, "RRAppsController", 0);
    if (!c) return objc_getClass("RRAppsController") != nil;   // someone else won the race
    class_addMethod(c, sel_registerName("specifiers"),       (IMP)RRController_specifiers,   "@@:");
    class_addMethod(c, sel_registerName("valueForApp:"),     (IMP)RRController_valueForApp,  "@@:@");
    class_addMethod(c, sel_registerName("setValue:forApp:"), (IMP)RRController_setValueForApp, "v@:@@");
    objc_registerClassPair(c);
    return YES;
}

// ===========================================================================
//  Load
// ===========================================================================
__attribute__((constructor)) static void RRInit(void) {
    @autoreleasepool {
        NSString *bid = [[NSBundle mainBundle] bundleIdentifier];

        // Settings app: register the picker controller so PreferenceLoader can push it.
        if ([bid isEqualToString:@"com.apple.Preferences"]) {
            if (!RRRegisterController()) {
                // Framework still not up — try again once the app has finished launching.
                [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidFinishLaunchingNotification
                    object:nil queue:nil usingBlock:^(NSNotification *n) { RRRegisterController(); }];
            }
            return;
        }

        // SpringBoard and other Apple processes are left alone.
        if (!bid || [bid hasPrefix:@"com.apple."]) return;

        if (!RRMasterEnabled()) return;
        if (!RRWantsRoot(bid)) return;

        RRElevate();   // best effort; the app keeps running either way
    }
}
