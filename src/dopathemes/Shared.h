// DopaThemes - shared between the Dopamine side (Tweak.m) and the SpringBoard side (SpringBoard.m).
#import "../common/cb.h"
#include <sys/stat.h>

#define DT_DOMAIN CFSTR("com.mymculture.dopathemes")
#define DT_DIR @JBROOT "/Library/DopaThemes"
// Which DopaThemes icon each Dopamine copy is using: { bundleID : themeKey }.
// Written by Dopamine (runs as mobile, unsandboxed), read by SpringBoard.
#define DT_ICON_MAP @"/var/mobile/Library/Preferences/com.mymculture.dopathemes.icons.plist"
#define DT_ICON_NOTIFY "com.mymculture.dopathemes/icon"

// All theme dictionaries from DT_DIR: Themes.plist first, then any extra .plist the user drops in.
// Keys are Dopamine's (key, name, image, actionMenuColor, windowColor, blur, titleShadow)
// plus our own optional "appIcon" (a square PNG in DT_DIR).
static NSArray<NSDictionary *> *DTLoadThemeDicts(void) {
    NSMutableArray *out = [NSMutableArray array];
    NSArray *files = [[[NSFileManager defaultManager] contentsOfDirectoryAtPath:DT_DIR error:nil]
                      sortedArrayUsingSelector:@selector(localizedStandardCompare:)];
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

static NSDictionary *DTReadIconMap(void) {
    NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:DT_ICON_MAP];
    return [d isKindOfClass:[NSDictionary class]] ? d : @{};
}
