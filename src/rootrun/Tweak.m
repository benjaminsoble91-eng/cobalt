// RootRun 1.0 — make a chosen app launch as root (uid 0) on your own jailbroken device.
//
// How it works:
//   * The dylib is injected into every app (Filter: Classes = UIApplication) and also into
//     the Settings app (Filter: Executables = Preferences) for the picker pane.
//   * In Settings, RootRun adds a sub-page listing your installed apps, each with a switch.
//     Toggling an app writes its bundle id into the "Apps" dict in com.mymculture.rootrun.
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
#define RR_PREFS  "com.mymculture.rootrun/prefs"

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
//  Settings — app picker
// ===========================================================================
@interface PSSpecifier : NSObject
+ (id)preferenceSpecifierNamed:(NSString *)name target:(id)target set:(SEL)set get:(SEL)get
                        detail:(Class)detail cell:(NSInteger)cell edit:(Class)edit;
- (void)setProperty:(id)value forKey:(NSString *)key;
- (id)propertyForKey:(NSString *)key;
@property (nonatomic, retain) id identifier;
@property (nonatomic, retain) NSString *name;
@end

@interface PSListController : NSObject
- (id)specifiers;
- (void)reloadSpecifiers;
@end

@interface RRAppsController : PSListController @end
@implementation RRAppsController

// Build one group header + one PSSwitchCell per installed user app.
- (id)specifiers {
    static const NSInteger PSGroupCell = 0, PSSwitchCell = 6;
    NSMutableArray *specs = [NSMutableArray array];

    PSSpecifier *grp = [PSSpecifier preferenceSpecifierNamed:@""
        target:self set:NULL get:NULL detail:Nil cell:PSGroupCell edit:Nil];
    [grp setProperty:@"Switch an app on to make it launch as root. The change takes effect the "
                     @"next time that app is opened (force-quit it first if it's running)."
              forKey:@"footerText"];
    [specs addObject:grp];

    // LSApplicationWorkspace.allApplications -> each has bundleIdentifier + localizedName.
    Class ws = objc_getClass("LSApplicationWorkspace");
    id workspace = ws ? [ws performSelector:@selector(defaultWorkspace)] : nil;
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
        PSSpecifier *s = [PSSpecifier preferenceSpecifierNamed:row[0]
            target:self set:@selector(setValue:forApp:) get:@selector(valueForApp:)
            detail:Nil cell:PSSwitchCell edit:Nil];
        s.identifier = row[1];
        [s setProperty:row[1] forKey:@"appBundleID"];
        [s setProperty:@NO forKey:@"default"];
        [specs addObject:s];
    }
    if (rows.count == 0) {
        PSSpecifier *empty = [PSSpecifier preferenceSpecifierNamed:@""
            target:self set:NULL get:NULL detail:Nil cell:PSGroupCell edit:Nil];
        [empty setProperty:@"No user apps found." forKey:@"footerText"];
        [specs addObject:empty];
    }
    return specs;
}

- (id)valueForApp:(PSSpecifier *)spec {
    return @(RRWantsRoot([spec propertyForKey:@"appBundleID"]));
}
- (void)setValue:(id)value forApp:(PSSpecifier *)spec {
    NSString *bid = [spec propertyForKey:@"appBundleID"];
    if (!bid) return;
    NSMutableDictionary *apps = [RRAppsDict() mutableCopy];
    if ([value boolValue]) apps[bid] = @YES; else [apps removeObjectForKey:bid];
    CFPreferencesSetAppValue(CFSTR("Apps"), (__bridge CFPropertyListRef)apps, RR_DOMAIN);
    CFPreferencesAppSynchronize(RR_DOMAIN);
}
@end

// ===========================================================================
//  Load
// ===========================================================================
__attribute__((constructor)) static void RRInit(void) {
    @autoreleasepool {
        NSString *bid = [[NSBundle mainBundle] bundleIdentifier];

        // Settings app: the RRAppsController class above is all we need; PreferenceLoader
        // finds it by name from Prefs.plist. Don't elevate Settings itself.
        if ([bid isEqualToString:@"com.apple.Preferences"]) return;

        // SpringBoard and other Apple processes are left alone.
        if (!bid || [bid hasPrefix:@"com.apple."]) return;

        if (!RRMasterEnabled()) return;
        if (!RRWantsRoot(bid)) return;

        RRElevate();   // best effort; the app keeps running either way
    }
}
