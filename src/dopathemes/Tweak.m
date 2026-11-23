// DopaThemes 1.0 - adds new themes to Dopamine's Settings -> Theme list, next to the stock ones
// (Dopamine, ElleKit, Deep Blue Sky, Blood Sky, Desert Dusk).
//
// How it works: Dopamine 2.x builds its theme list once, in -[DOThemeManager init], from the
// Themes.plist in its app bundle. We let it build the stock list, then append our own themes,
// read from JBROOT/Library/DopaThemes/*.plist (same keys as Dopamine's Themes.plist). Theme
// backgrounds live in that folder too, so -[DOTheme image] is taught to load them from there
// (Dopamine itself only looks in its asset catalog). Everything else - the menu tint, window
// tint, blur, title shadow and the boot logo - is handled by Dopamine as for any stock theme.
//
// Works in Dopamine, Trollamine and duplicated copies (anything whose executable is "Dopamine").
#import "../common/cb.h"

#define DT_DOMAIN CFSTR("com.mymculture.dopathemes")
#define DT_DIR @JBROOT "/Library/DopaThemes"

static const void *kDTImagePathKey = &kDTImagePathKey;

// UIImage+Blur lives in Dopamine's binary; declared here so we can call it.
@interface UIImage (DopamineBlur)
- (instancetype)imageWithBlur:(float)radius;
@end

static NSArray<NSDictionary *> *DTLoadThemeDicts(void) {
    NSMutableArray *out = [NSMutableArray array];
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray *files = [[fm contentsOfDirectoryAtPath:DT_DIR error:nil]
                      sortedArrayUsingSelector:@selector(localizedStandardCompare:)];
    // Themes.plist (the bundled set) first, then any extra .plist files the user drops in.
    NSMutableArray *ordered = [NSMutableArray array];
    if ([files containsObject:@"Themes.plist"]) [ordered addObject:@"Themes.plist"];
    for (NSString *f in files)
        if ([f.pathExtension.lowercaseString isEqualToString:@"plist"] && ![f isEqualToString:@"Themes.plist"])
            [ordered addObject:f];

    for (NSString *f in ordered) {
        NSString *path = [DT_DIR stringByAppendingPathComponent:f];
        id plist = [NSArray arrayWithContentsOfFile:path] ?: [NSDictionary dictionaryWithContentsOfFile:path];
        NSArray *list = [plist isKindOfClass:[NSArray class]] ? plist : (plist ? @[plist] : @[]);
        for (id d in list) {
            if (![d isKindOfClass:[NSDictionary class]]) continue;
            if (![d[@"key"] isKindOfClass:[NSString class]] || ![d[@"name"] isKindOfClass:[NSString class]]) continue;
            if (![d[@"image"] isKindOfClass:[NSString class]]) continue;
            NSMutableDictionary *m = [d mutableCopy];
            // Dopamine parses these with NSScanner; give missing colours a sane default.
            if (![m[@"actionMenuColor"] isKindOfClass:[NSString class]]) m[@"actionMenuColor"] = @"5F3F3F3F";
            if (![m[@"windowColor"] isKindOfClass:[NSString class]]) m[@"windowColor"] = @"994C4C4C";
            [out addObject:m];
        }
    }
    return out;
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
            id theme = ((id (*)(id, SEL, id))objc_msgSend)([themeCls alloc], sel_registerName("initWithDictionary:"), d);
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
}

__attribute__((constructor)) static void DTInit(void) {
    @autoreleasepool {
        DTInstall();
    }
}
