// dopathemes-patch - bakes DopaThemes' themes and icons into every installed Dopamine app
// (Dopamine, Trollamine, duplicated copies: any app whose executable is "Dopamine").
//
//   dopathemes-patch apply  <resdir>   add / update our themes and icons
//   dopathemes-patch remove <resdir>   take them back out
//
// What it changes inside each Dopamine.app (nothing else is touched):
//   Themes.plist  - Dopamine's own theme list; our entries (key "dopathemes.*") go after the stock ones.
//   Info.plist    - our icons are added as alternate icons, the same way Dopamine's own
//                   AppIcon_Blue / _Red / ... are, so Dopamine's normal icon switching uses them.
//   dopathemes_*.jpg, AppIcon_DopaThemes_*.png - the backgrounds and icon images.
// Because it all lives in the app itself, the themes stay when you're not jailbroken.
// Run as root (Sileo's postinst / prerm); afterwards TrollStore re-registers the apps.
#import <Foundation/Foundation.h>
#include <sys/stat.h>
#include <unistd.h>
#include <string.h>
#include <stdlib.h>

// Builds with ARC (iOS) and without (the Linux/GNUstep test build).
#if __has_feature(objc_arc)
#  define autorelease_if_mrc self
#  define NSAutoreleasePool_or_block_begin @autoreleasepool {
#  define NSAutoreleasePool_or_block_end }
#else
#  define autorelease_if_mrc autorelease
#  define NSAutoreleasePool_or_block_begin NSAutoreleasePool *pool_ = [NSAutoreleasePool new]; {
#  define NSAutoreleasePool_or_block_end } [pool_ drain];
#endif

#define KEY_PREFIX  @"dopathemes."
#define FILE_PREFIX @"dopathemes_"
#define ICON_PREFIX @"AppIcon_DopaThemes_"

static NSString *IconName(NSString *themeKey) {   // dopathemes.gold -> AppIcon_DopaThemes_gold
    return [ICON_PREFIX stringByAppendingString:[themeKey substringFromIndex:[KEY_PREFIX length]]];
}

static id ReadPlist(NSString *path, NSPropertyListFormat *fmt) {
    NSData *d = [NSData dataWithContentsOfFile:path];
    if (!d) return nil;
    return [NSPropertyListSerialization propertyListWithData:d options:NSPropertyListMutableContainersAndLeaves
                                                      format:fmt error:NULL];
}

// Write keeping the original format and the original file's owner/permissions.
static BOOL WritePlist(id obj, NSString *path, NSPropertyListFormat fmt, struct stat *like) {
    NSData *d = [NSPropertyListSerialization dataWithPropertyList:obj format:fmt options:0 error:NULL];
    if (!d || ![d writeToFile:path atomically:YES]) return NO;
    chown([path fileSystemRepresentation], like->st_uid, like->st_gid);
    chmod([path fileSystemRepresentation], 0644);
    return YES;
}

static BOOL CopyFile(NSString *src, NSString *dst, struct stat *like) {
    NSFileManager *fm = [NSFileManager defaultManager];
    [fm removeItemAtPath:dst error:NULL];
    if (![fm copyItemAtPath:src toPath:dst error:NULL]) return NO;
    chown([dst fileSystemRepresentation], like->st_uid, like->st_gid);
    chmod([dst fileSystemRepresentation], 0644);
    return YES;
}

static BOOL IsDict(id o) { return [o isKindOfClass:[NSDictionary class]]; }
static BOOL IsString(id o) { return [o isKindOfClass:[NSString class]]; }

static BOOL PatchApp(NSString *app, NSString *res, BOOL apply, NSArray *ours) {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *infoPath = [app stringByAppendingPathComponent:@"Info.plist"];
    NSString *themesPath = [app stringByAppendingPathComponent:@"Themes.plist"];
    NSString *iconDir = [res stringByAppendingPathComponent:@"icons"];
    struct stat like;
    NSUInteger i;
    if (stat([infoPath fileSystemRepresentation], &like) != 0) return NO;

    // 1. Old files from an earlier run.
    NSArray *existing = [fm contentsOfDirectoryAtPath:app error:NULL];
    for (i = 0; i < [existing count]; i++) {
        NSString *f = [existing objectAtIndex:i];
        if ([f hasPrefix:FILE_PREFIX] || [f hasPrefix:ICON_PREFIX])
            [fm removeItemAtPath:[app stringByAppendingPathComponent:f] error:NULL];
    }

    // 2. Themes.plist: drop our old entries, append the current ones.
    NSPropertyListFormat tfmt = NSPropertyListXMLFormat_v1_0;
    NSMutableArray *themes = ReadPlist(themesPath, &tfmt);
    if (![themes isKindOfClass:[NSMutableArray class]]) { fprintf(stderr, "  can't read %s\n", [themesPath UTF8String]); return NO; }
    NSMutableSet *stockKeys = [NSMutableSet set];
    for (i = [themes count]; i-- > 0;) {
        id t = [themes objectAtIndex:i];
        if (!IsDict(t)) continue;
        id k = [t objectForKey:@"key"];
        if (IsString(k) && [k hasPrefix:KEY_PREFIX]) [themes removeObjectAtIndex:i];
        else if (k) [stockKeys addObject:k];
    }

    NSMutableArray *added = [NSMutableArray array];   // icon names we install
    NSArray *iconFiles = [fm contentsOfDirectoryAtPath:iconDir error:NULL];
    if (apply) {
        for (i = 0; i < [ours count]; i++) {
            NSDictionary *d = [ours objectAtIndex:i];
            NSString *key = [d objectForKey:@"key"];
            if ([stockKeys containsObject:key]) continue;
            NSString *img = [d objectForKey:@"image"];
            if (!CopyFile([res stringByAppendingPathComponent:img], [app stringByAppendingPathComponent:img], &like)) {
                fprintf(stderr, "  missing %s\n", [img UTF8String]); continue;
            }
            NSMutableDictionary *t = [[d mutableCopy] autorelease_if_mrc];
            [t removeObjectForKey:@"appIcon"];
            NSString *icon = IconName(key);
            BOOL haveIcon = NO;
            NSUInteger j;
            for (j = 0; j < [iconFiles count]; j++) {
                NSString *f = [iconFiles objectAtIndex:j];
                NSString *rest = [f hasPrefix:icon] ? [f substringFromIndex:[icon length]] : nil;
                // e.g. "60x60@2x.png", "83.5x83.5@2x~ipad.png" - a size must follow the name directly
                if (rest && [rest length] && [[NSCharacterSet decimalDigitCharacterSet] characterIsMember:[rest characterAtIndex:0]])
                    haveIcon |= CopyFile([iconDir stringByAppendingPathComponent:f], [app stringByAppendingPathComponent:f], &like);
            }
            if (haveIcon) { [t setObject:icon forKey:@"icon"]; [added addObject:icon]; }
            else [t removeObjectForKey:@"icon"];
            [themes addObject:t];
        }
    }
    if (!WritePlist(themes, themesPath, tfmt, &like)) { fprintf(stderr, "  can't write Themes.plist\n"); return NO; }

    // 3. Info.plist: our alternate icons, next to Dopamine's own.
    NSPropertyListFormat ifmt = NSPropertyListBinaryFormat_v1_0;
    NSMutableDictionary *info = ReadPlist(infoPath, &ifmt);
    if (![info isKindOfClass:[NSMutableDictionary class]]) { fprintf(stderr, "  can't read Info.plist\n"); return NO; }
    NSArray *iconsKeys = [NSArray arrayWithObjects:@"CFBundleIcons", @"CFBundleIcons~ipad", nil];
    for (i = 0; i < [iconsKeys count]; i++) {
        NSString *iconsKey = [iconsKeys objectAtIndex:i];
        BOOL ipad = [iconsKey hasSuffix:@"~ipad"];
        NSMutableDictionary *icons = [info objectForKey:iconsKey];
        if (![icons isKindOfClass:[NSMutableDictionary class]]) {
            if (!apply || ![added count] || ipad) continue;   // the iPhone key is the fallback for iPad too
            icons = [NSMutableDictionary dictionary];
            [info setObject:icons forKey:iconsKey];
        }
        NSMutableDictionary *alts = [icons objectForKey:@"CFBundleAlternateIcons"];
        if (![alts isKindOfClass:[NSMutableDictionary class]]) {
            alts = [NSMutableDictionary dictionary];
            [icons setObject:alts forKey:@"CFBundleAlternateIcons"];
        }
        NSArray *altKeys = [alts allKeys];
        NSUInteger j;
        for (j = 0; j < [altKeys count]; j++)
            if ([[altKeys objectAtIndex:j] hasPrefix:ICON_PREFIX]) [alts removeObjectForKey:[altKeys objectAtIndex:j]];
        for (j = 0; j < [added count]; j++) {
            NSString *icon = [added objectAtIndex:j];
            NSArray *files = ipad
                ? [NSArray arrayWithObjects:[icon stringByAppendingString:@"60x60"], [icon stringByAppendingString:@"76x76"],
                                            [icon stringByAppendingString:@"83.5x83.5"], nil]
                : [NSArray arrayWithObject:[icon stringByAppendingString:@"60x60"]];
            NSMutableDictionary *entry = [NSMutableDictionary dictionary];
            [entry setObject:files forKey:@"CFBundleIconFiles"];
            [entry setObject:[NSNumber numberWithBool:NO] forKey:@"UIPrerenderedIcon"];
            [alts setObject:entry forKey:icon];
        }
        if (![alts count]) [icons removeObjectForKey:@"CFBundleAlternateIcons"];
    }
    if (!WritePlist(info, infoPath, ifmt, &like)) { fprintf(stderr, "  can't write Info.plist\n"); return NO; }
    return YES;
}

int main(int argc, char **argv) {
    NSAutoreleasePool_or_block_begin
    if (argc < 3 || (strcmp(argv[1], "apply") && strcmp(argv[1], "remove"))) {
        fprintf(stderr, "usage: %s apply|remove <resdir>\n", argv[0]); return 64;
    }
    BOOL apply = !strcmp(argv[1], "apply");
    NSString *res = [NSString stringWithUTF8String:argv[2]];
    NSArray *ours = [NSArray arrayWithContentsOfFile:[res stringByAppendingPathComponent:@"Themes.plist"]];
    if (apply && ![ours isKindOfClass:[NSArray class]]) { fprintf(stderr, "no Themes.plist in %s\n", argv[2]); return 66; }
    NSMutableArray *valid = [NSMutableArray array];
    NSUInteger i;
    for (i = 0; i < [ours count]; i++) {
        NSDictionary *d = [ours objectAtIndex:i];
        if (IsDict(d) && IsString([d objectForKey:@"key"]) && [[d objectForKey:@"key"] hasPrefix:KEY_PREFIX]
            && IsString([d objectForKey:@"image"]))
            [valid addObject:d];
    }

    NSFileManager *fm = [NSFileManager defaultManager];
    const char *rootEnv = getenv("DOPATHEMES_APPS_ROOT");   // testing only
    NSString *root = rootEnv ? [NSString stringWithUTF8String:rootEnv] : @"/var/containers/Bundle/Application";
    int found = 0, ok = 0;
    NSArray *uuids = [fm contentsOfDirectoryAtPath:root error:NULL];
    for (i = 0; i < [uuids count]; i++) {
        NSString *dir = [root stringByAppendingPathComponent:[uuids objectAtIndex:i]];
        NSArray *items = [fm contentsOfDirectoryAtPath:dir error:NULL];
        NSUInteger j;
        for (j = 0; j < [items count]; j++) {
            NSString *item = [items objectAtIndex:j];
            if (![[item pathExtension] isEqualToString:@"app"]) continue;
            NSString *app = [dir stringByAppendingPathComponent:item];
            NSPropertyListFormat f;
            NSDictionary *info = ReadPlist([app stringByAppendingPathComponent:@"Info.plist"], &f);
            if (!IsDict(info)) continue;
            if (![[info objectForKey:@"CFBundleExecutable"] isEqual:@"Dopamine"]) continue;
            if (![fm fileExistsAtPath:[app stringByAppendingPathComponent:@"Themes.plist"]]) continue;   // not Dopamine 2.x
            found++;
            NSString *name = [info objectForKey:@"CFBundleDisplayName"];
            if (!name) name = [info objectForKey:@"CFBundleName"];
            if (!name) name = item;
            BOOL r = PatchApp(app, res, apply, valid);
            printf("%s %s (%s)\n", r ? (apply ? "Added themes to" : "Removed themes from") : "Couldn't update",
                   [name UTF8String], [[info objectForKey:@"CFBundleIdentifier"] UTF8String]);
            if (r) ok++;
        }
    }
    if (!found) { printf("No Dopamine 2.x app found.\n"); return 2; }
    return ok == found ? 0 : 1;
    NSAutoreleasePool_or_block_end
}
