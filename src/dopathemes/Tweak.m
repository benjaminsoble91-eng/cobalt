// DopaThemes 1.1 (Dopamine side) - adds new themes to Dopamine's Settings -> Theme list, next to
// the stock ones (Dopamine, ElleKit, Deep Blue Sky, Blood Sky, Desert Dusk), each with its own icon.
//
// Themes: Dopamine 2.x builds its theme list once, in -[DOThemeManager init], from the Themes.plist
// in its app bundle. We let it build the stock list, then append ours from JBROOT/Library/DopaThemes.
// Backgrounds live in that folder too, so -[DOTheme image] is taught to load them from there.
//
// Icons: iOS only switches to icons built into the app, so when one of our themes is picked we
// record "this Dopamine uses theme X's icon" for SpringBoard (see SpringBoard.m, which draws it),
// then make SpringBoard redraw the icon by briefly switching to one of Dopamine's own alternate
// icons and back - through the quiet private call, so no "You have changed the icon" popup.
//
// Works in Dopamine, Trollamine and duplicated copies (anything whose executable is "Dopamine").
#import "Shared.h"

static const void *kDTImagePathKey = &kDTImagePathKey;
static IMP gOrigSetIcon;

// UIImage+Blur lives in Dopamine's binary; declared here so we can call it.
@interface UIImage (DopamineBlur)
- (instancetype)imageWithBlur:(float)radius;
@end

// The enabled theme's key if it's one of ours, else nil.
static NSString *DTOurEnabledThemeKey(void) {
    id mgr = CBSendID(objc_getClass("DOThemeManager"), "sharedInstance");
    id theme = CBSendID(mgr, "enabledTheme");
    if (!theme || !objc_getAssociatedObject(theme, kDTImagePathKey)) return nil;
    return CBSendID(theme, "key");
}

// Record (or clear) which DopaThemes icon this Dopamine copy uses. Returns YES if it changed.
static BOOL DTWriteIconMap(NSString *themeKey) {
    NSString *bid = [NSBundle mainBundle].bundleIdentifier;
    if (!bid) return NO;
    NSMutableDictionary *m = [DTReadIconMap() mutableCopy];
    if ((themeKey == m[bid]) || [themeKey isEqual:m[bid]]) return NO;
    if (themeKey) m[bid] = themeKey; else [m removeObjectForKey:bid];
    [m writeToFile:DT_ICON_MAP atomically:YES];
    notify_post(DT_ICON_NOTIFY);
    return YES;
}

// Change the real app icon, quietly if iOS lets us (private call, no popup), else the normal way.
static void DTSetIcon(NSString *name, void (^done)(NSError *)) {
    UIApplication *app = [UIApplication sharedApplication];
    SEL quiet = sel_registerName("_setAlternateIconName:completionHandler:");
    if ([app respondsToSelector:quiet])
        ((void (*)(id, SEL, id, id))objc_msgSend)(app, quiet, name, done);
    else if (gOrigSetIcon)
        ((void (*)(id, SEL, id, id))gOrigSetIcon)(app, @selector(setAlternateIconName:completionHandler:), name, done);
    else if (done) done(nil);
}

// One of the app's own alternate icon names (e.g. AppIcon_Blue), used to nudge SpringBoard.
static NSString *DTAnyBuiltInAlternateIcon(void) {
    NSDictionary *info = [NSBundle mainBundle].infoDictionary;
    for (NSString *k in @[@"CFBundleIcons", @"CFBundleIcons~ipad"]) {
        NSDictionary *alts = info[k][@"CFBundleAlternateIcons"];
        if ([alts isKindOfClass:[NSDictionary class]] && alts.count)
            return [[alts.allKeys sortedArrayUsingSelector:@selector(compare:)] firstObject];
    }
    return nil;
}

static void DTInstall(void) {
    Class mgr = objc_getClass("DOThemeManager");
    Class themeCls = objc_getClass("DOTheme");
    if (!mgr || !themeCls) return;   // not Dopamine 2.x

    // -[DOThemeManager init]: stock themes first, then ours.
    __block IMP origInit = CBHook(mgr, @selector(init), ^id(id self) {
        self = ((id (*)(id, SEL))origInit)(self, @selector(init));
        if (!self) return self;
        CFPreferencesAppSynchronize(DT_DOMAIN);
        if (!CBPrefBool(DT_DOMAIN, CFSTR("Enabled"), YES)) return self;

        NSArray *stock = CBSendID(self, "themes") ?: @[];
        NSMutableArray *all = [stock mutableCopy];
        NSMutableSet *keys = [NSMutableSet set];
        for (id t in stock) { id k = CBSendID(t, "key"); if (k) [keys addObject:k]; }

        for (NSDictionary *d in DTLoadThemeDicts()) {
            if ([keys containsObject:d[@"key"]]) continue;   // never shadow a stock theme
            NSMutableDictionary *dd = [d mutableCopy];
            [dd removeObjectForKey:@"icon"];                  // icons are drawn by SpringBoard, not iOS
            id theme = ((id (*)(id, SEL, id))objc_msgSend)([themeCls alloc], sel_registerName("initWithDictionary:"), dd);
            if (!theme) continue;
            NSString *img = [DT_DIR stringByAppendingPathComponent:d[@"image"]];
            objc_setAssociatedObject(theme, kDTImagePathKey, img, OBJC_ASSOCIATION_COPY_NONATOMIC);
            [all addObject:theme];
            [keys addObject:d[@"key"]];
        }
        SEL setThemes = sel_registerName("setThemes:");
        if ([self respondsToSelector:setThemes])
            ((void (*)(id, SEL, id))objc_msgSend)(self, setThemes, all);
        return self;
    });

    // -[DOTheme image]: our themes load their background from DT_DIR instead of the asset catalog.
    __block IMP origImage = CBHook(themeCls, sel_registerName("image"), ^UIImage *(id self) {
        NSString *path = objc_getAssociatedObject(self, kDTImagePathKey);
        if (!path) return ((UIImage *(*)(id, SEL))origImage)(self, sel_registerName("image"));
        UIImage *cached = CBIvar(self, "_image");
        if (cached) return cached;
        UIImage *img = [UIImage imageWithContentsOfFile:path];
        if (!img) return ((UIImage *(*)(id, SEL))origImage)(self, sel_registerName("image"));
        float blur = 0;
        SEL getBlur = sel_registerName("blur");
        if ([self respondsToSelector:getBlur]) blur = ((float (*)(id, SEL))objc_msgSend)(self, getBlur);
        if (blur > 0 && [img respondsToSelector:@selector(imageWithBlur:)])
            img = [img imageWithBlur:blur] ?: img;
        SEL setImage = sel_registerName("setImage:");
        if ([self respondsToSelector:setImage]) ((void (*)(id, SEL, id))objc_msgSend)(self, setImage, img);
        return img;
    });

    // Dopamine calls this right after you pick a theme (with the theme's built-in icon name, or nil).
    gOrigSetIcon = CBHook([UIApplication class], @selector(setAlternateIconName:completionHandler:),
                          ^(UIApplication *self, NSString *name, void (^done)(NSError *)) {
        NSString *ours = DTOurEnabledThemeKey();
        DTWriteIconMap(ours);
        if (!ours) {   // a stock theme: let iOS switch to Dopamine's own icon as usual
            ((void (*)(id, SEL, id, id))gOrigSetIcon)(self, @selector(setAlternateIconName:completionHandler:), name, done);
            return;
        }
        // One of ours: the real icon goes back to the default, and SpringBoard draws ours on top.
        // If it's already the default, bounce through a built-in alternate so SpringBoard redraws.
        NSString *bounce = self.alternateIconName ? nil : DTAnyBuiltInAlternateIcon();
        if (!bounce) { DTSetIcon(nil, done); return; }
        DTSetIcon(bounce, ^(NSError *e) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                DTSetIcon(nil, done);
            });
        });
    });

    // Keep SpringBoard's record in step with whatever theme is active when Dopamine opens
    // (covers installing DopaThemes, turning it off, or uninstalling a custom theme).
    [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidFinishLaunchingNotification object:nil
                                                       queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *n) {
        DTWriteIconMap(DTOurEnabledThemeKey());
    }];
}

__attribute__((constructor)) static void DTInit(void) {
    @autoreleasepool {
        DTInstall();
    }
}
