// Cobalt — a normal (sideloadable) iOS app for the Cobalt source.
// Browse the catalog, read native depictions, hand packages to Sileo / Zebra / TrollStore,
// download .debs and .tipas, and get told when something you installed has an update.
// No jailbreak entitlements: it installs with AltStore, Sideloadly, Benstore, TrollStore, anything.
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#include <ctype.h>

#define TINT [UIColor colorWithRed:0x3c / 255.0 green:0x78 / 255.0 blue:1.0 alpha:1]
static NSString *const kDefaultSource = @"https://benjaminsoble91-eng.github.io/cobalt/";
static NSString *const CBStoreDidChange = @"CBStoreDidChange";

#pragma mark - dpkg version compare

static int cb_order(int c) {
    if (isdigit(c)) return 0;
    if (isalpha(c)) return c;
    if (c == '~') return -1;
    if (c) return c + 256;
    return 0;
}
static int cb_verrevcmp(const char *a, const char *b) {
    while (*a || *b) {
        int first_diff = 0;
        while ((*a && !isdigit(*a)) || (*b && !isdigit(*b))) {
            int ac = cb_order(*a), bc = cb_order(*b);
            if (ac != bc) return ac - bc;
            a++; b++;
        }
        while (*a == '0') a++;
        while (*b == '0') b++;
        while (isdigit(*a) && isdigit(*b)) {
            if (!first_diff) first_diff = *a - *b;
            a++; b++;
        }
        if (isdigit(*a)) return 1;
        if (isdigit(*b)) return -1;
        if (first_diff) return first_diff;
    }
    return 0;
}
static NSComparisonResult CBCompareVersions(NSString *a, NSString *b) {
    int r = cb_verrevcmp((a ?: @"").UTF8String, (b ?: @"").UTF8String);
    return r < 0 ? NSOrderedAscending : r > 0 ? NSOrderedDescending : NSOrderedSame;
}
static BOOL CBNewer(NSString *candidate, NSString *than) {
    return candidate.length && than.length && CBCompareVersions(candidate, than) == NSOrderedDescending;
}

static NSString *CBSize(long long b) {
    if (b <= 0) return @"";
    return [NSByteCountFormatter stringFromByteCount:b countStyle:NSByteCountFormatterCountStyleFile];
}
static NSString *CBArchName(NSString *arch) {
    if ([arch isEqualToString:@"iphoneos-arm64"]) return @"Rootless";
    if ([arch isEqualToString:@"iphoneos-arm"]) return @"Rootful";
    return arch ?: @"";
}

#pragma mark - Models

@interface CBBuild : NSObject
@property (copy) NSString *arch, *filename, *depends;
@property long long size;
@end
@implementation CBBuild
@end

@interface CBItem : NSObject
@property (copy) NSString *pid, *name, *desc, *section, *author, *iconURL, *depiction, *sileoDepiction, *latest;
@property (copy) NSString *appURL, *minOS; // TrollStore apps
@property long long appSize;
@property BOOL isApp;
@property (strong) NSArray<CBBuild *> *builds; // builds of the latest version
@property (strong) NSArray<NSString *> *allVersions;
@end
@implementation CBItem
@end

#pragma mark - Store

@interface CBStore : NSObject
+ (instancetype)shared;
@property (readonly, copy) NSString *base;
@property (readonly, strong) NSArray<CBItem *> *items;
@property (readonly, strong) NSArray<NSDictionary *> *banners;
@property (readonly, strong) NSDictionary *selfUpdate; // {version, url, notes}
@property (readonly) BOOL loading;
@property (readonly, copy) NSString *lastError;
@property (readonly, strong) NSDate *lastRefresh;
- (void)setSource:(NSString *)source;
- (void)refresh:(void (^)(NSString *error))done;
- (CBItem *)itemForID:(NSString *)pid;
- (NSURL *)abs:(NSString *)rel;
// update tracking
- (NSString *)trackedVersion:(CBItem *)item;
- (void)track:(CBItem *)item version:(NSString *)version;
- (void)untrack:(CBItem *)item;
- (void)untrackAll;
- (NSArray<CBItem *> *)trackedUpdates;
- (NSArray<CBItem *> *)newItems;
- (NSArray<CBItem *> *)updatedItems;
- (void)markAllSeen;
- (NSInteger)badgeCount;
- (BOOL)selfUpdateAvailable;
- (void)depictionFor:(CBItem *)item done:(void (^)(NSDictionary *))done;
@end

@implementation CBStore {
    NSMutableDictionary *_depictions;
}

+ (instancetype)shared {
    static CBStore *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [CBStore new]; });
    return s;
}

- (instancetype)init {
    if ((self = [super init])) {
        _depictions = [NSMutableDictionary new];
        NSString *src = [NSUserDefaults.standardUserDefaults stringForKey:@"source"];
        _base = src.length ? src : kDefaultSource;
        [self loadCache];
    }
    return self;
}

- (NSString *)cacheDir {
    NSString *d = [NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES).firstObject
        stringByAppendingPathComponent:@"source"];
    [NSFileManager.defaultManager createDirectoryAtPath:d withIntermediateDirectories:YES attributes:nil error:nil];
    return d;
}

- (NSURL *)abs:(NSString *)rel {
    if (!rel.length) return nil;
    NSURL *u = [NSURL URLWithString:rel relativeToURL:[NSURL URLWithString:_base]];
    if (!u) u = [NSURL URLWithString:[rel stringByAddingPercentEncodingWithAllowedCharacters:NSCharacterSet.URLQueryAllowedCharacterSet]
                        relativeToURL:[NSURL URLWithString:_base]];
    return u.absoluteURL;
}

- (void)setSource:(NSString *)source {
    source = [source stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!source.length) source = kDefaultSource;
    if (![source hasPrefix:@"http"]) source = [@"https://" stringByAppendingString:source];
    if (![source hasSuffix:@"/"]) source = [source stringByAppendingString:@"/"];
    _base = [source copy];
    [NSUserDefaults.standardUserDefaults setObject:_base forKey:@"source"];
    [NSUserDefaults.standardUserDefaults removeObjectForKey:@"known"];
    [_depictions removeAllObjects];
    _items = @[]; _banners = @[]; _selfUpdate = nil;
    for (NSString *f in @[@"Packages", @"apps.json", @"featured.json"])
        [NSFileManager.defaultManager removeItemAtPath:[self.cacheDir stringByAppendingPathComponent:f] error:nil];
    [NSNotificationCenter.defaultCenter postNotificationName:CBStoreDidChange object:nil];
}

#pragma mark parsing

- (NSArray<NSDictionary *> *)parsePackages:(NSString *)text {
    NSMutableArray *out = [NSMutableArray new];
    text = [text stringByReplacingOccurrencesOfString:@"\r\n" withString:@"\n"];
    for (NSString *stanza in [text componentsSeparatedByString:@"\n\n"]) {
        NSMutableDictionary *d = [NSMutableDictionary new];
        NSString *lastKey = nil;
        for (NSString *line in [stanza componentsSeparatedByString:@"\n"]) {
            if (!line.length) continue;
            if (([line hasPrefix:@" "] || [line hasPrefix:@"\t"]) && lastKey) {
                NSString *cont = [line substringFromIndex:1];
                if ([cont isEqualToString:@"."]) cont = @"";
                d[lastKey] = [NSString stringWithFormat:@"%@\n%@", d[lastKey], cont];
                continue;
            }
            NSRange r = [line rangeOfString:@":"];
            if (r.location == NSNotFound) continue;
            NSString *k = [line substringToIndex:r.location];
            NSString *v = [[line substringFromIndex:r.location + 1]
                stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
            d[k] = v;
            lastKey = k;
        }
        if (d[@"Package"]) [out addObject:d];
    }
    return out;
}

- (void)rebuildFromPackages:(NSString *)packages apps:(NSData *)appsJSON featured:(NSData *)featuredJSON {
    NSMutableDictionary<NSString *, NSMutableArray *> *byID = [NSMutableDictionary new];
    NSMutableArray *order = [NSMutableArray new];
    for (NSDictionary *d in [self parsePackages:packages ?: @""]) {
        NSString *pid = d[@"Package"];
        if (!byID[pid]) { byID[pid] = [NSMutableArray new]; [order addObject:pid]; }
        [byID[pid] addObject:d];
    }
    NSMutableArray *items = [NSMutableArray new];
    for (NSString *pid in order) {
        NSArray *stanzas = byID[pid];
        NSString *latest = nil;
        NSMutableSet *versions = [NSMutableSet new];
        for (NSDictionary *d in stanzas) {
            [versions addObject:d[@"Version"] ?: @""];
            if (!latest || CBNewer(d[@"Version"], latest)) latest = d[@"Version"];
        }
        CBItem *it = [CBItem new];
        it.pid = pid;
        it.latest = latest;
        it.allVersions = [versions.allObjects sortedArrayUsingComparator:^NSComparisonResult(id a, id b) {
            return CBCompareVersions(b, a);
        }];
        NSMutableArray *builds = [NSMutableArray new];
        NSMutableSet *seenArch = [NSMutableSet new];
        for (NSDictionary *d in stanzas.reverseObjectEnumerator) { // later stanzas win
            if (![d[@"Version"] isEqualToString:latest]) continue;
            if (!it.name) {
                it.name = d[@"Name"] ?: pid;
                it.desc = d[@"Description"];
                it.section = d[@"Section"] ?: @"Other";
                it.author = d[@"Author"] ?: d[@"Maintainer"];
                it.iconURL = d[@"Icon"];
                it.depiction = d[@"Depiction"];
                it.sileoDepiction = d[@"SileoDepiction"];
            }
            NSString *arch = d[@"Architecture"] ?: @"";
            if ([seenArch containsObject:arch]) continue;
            [seenArch addObject:arch];
            CBBuild *b = [CBBuild new];
            b.arch = arch;
            b.filename = d[@"Filename"];
            b.depends = d[@"Depends"];
            b.size = [d[@"Size"] longLongValue];
            [builds addObject:b];
        }
        [builds sortUsingComparator:^NSComparisonResult(CBBuild *a, CBBuild *b) { return [b.arch compare:a.arch]; }];
        it.builds = builds;
        [items addObject:it];
    }

    NSDictionary *apps = appsJSON ? [NSJSONSerialization JSONObjectWithData:appsJSON options:0 error:nil] : nil;
    if (![apps isKindOfClass:NSDictionary.class]) apps = nil;
    NSArray *appList = apps[@"apps"];
    if (![appList isKindOfClass:NSArray.class]) appList = @[];
    for (NSDictionary *a in appList) {
        if (![a isKindOfClass:NSDictionary.class] || !a[@"id"] || !a[@"url"]) continue;
        CBItem *it = [CBItem new];
        it.isApp = YES;
        it.pid = a[@"id"];
        it.name = a[@"name"] ?: a[@"id"];
        it.desc = a[@"description"];
        it.section = a[@"section"] ?: @"TrollStore Apps";
        it.author = a[@"author"] ?: @"MYM Culture";
        it.iconURL = [self abs:a[@"icon"]].absoluteString;
        it.latest = [a[@"version"] description];
        it.appURL = [self abs:a[@"url"]].absoluteString;
        it.appSize = [a[@"size"] longLongValue];
        it.minOS = a[@"minOS"];
        it.sileoDepiction = a[@"sileoDepiction"] ? [self abs:a[@"sileoDepiction"]].absoluteString : nil;
        it.allVersions = it.latest ? @[it.latest] : @[];
        it.builds = @[];
        [items addObject:it];
    }
    NSDictionary *me = apps[@"cobalt"];
    _selfUpdate = [me isKindOfClass:NSDictionary.class] ? me : nil;

    NSDictionary *featured = featuredJSON ? [NSJSONSerialization JSONObjectWithData:featuredJSON options:0 error:nil] : nil;
    NSArray *banners = [featured isKindOfClass:NSDictionary.class] ? featured[@"banners"] : nil;
    _banners = [banners isKindOfClass:NSArray.class] ? banners : @[];
    _items = items;

    // First run: everything currently on the source counts as already seen.
    if (![NSUserDefaults.standardUserDefaults dictionaryForKey:@"known"] && items.count) [self markAllSeen];
}

- (void)loadCache {
    NSString *d = self.cacheDir;
    NSString *pk = [NSString stringWithContentsOfFile:[d stringByAppendingPathComponent:@"Packages"] encoding:NSUTF8StringEncoding error:nil];
    if (!pk) return;
    [self rebuildFromPackages:pk
                         apps:[NSData dataWithContentsOfFile:[d stringByAppendingPathComponent:@"apps.json"]]
                     featured:[NSData dataWithContentsOfFile:[d stringByAppendingPathComponent:@"featured.json"]]];
}

- (void)fetch:(NSString *)rel done:(void (^)(NSData *, NSString *))done {
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[self abs:rel]];
    req.cachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
    req.timeoutInterval = 20;
    [req setValue:@"Cobalt-iOS/1.0" forHTTPHeaderField:@"User-Agent"];
    [[NSURLSession.sharedSession dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        NSInteger code = [resp isKindOfClass:NSHTTPURLResponse.class] ? ((NSHTTPURLResponse *)resp).statusCode : 0;
        if (err) done(nil, err.localizedDescription);
        else if (code != 200) done(nil, [NSString stringWithFormat:@"HTTP %ld for %@", (long)code, rel]);
        else done(data, nil);
    }] resume];
}

- (void)refresh:(void (^)(NSString *))done {
    if (_loading) { if (done) done(nil); return; }
    _loading = YES;
    __block NSData *pk = nil, *apps = nil, *feat = nil;
    __block NSString *pkErr = nil;
    dispatch_group_t g = dispatch_group_create();
    dispatch_group_enter(g);
    [self fetch:@"Packages" done:^(NSData *d, NSString *e) { pk = d; pkErr = e; dispatch_group_leave(g); }];
    dispatch_group_enter(g);
    [self fetch:@"apps.json" done:^(NSData *d, NSString *e) { apps = d; dispatch_group_leave(g); }];
    dispatch_group_enter(g);
    [self fetch:@"sileo-featured.json" done:^(NSData *d, NSString *e) { feat = d; dispatch_group_leave(g); }];
    dispatch_group_notify(g, dispatch_get_main_queue(), ^{
        self->_loading = NO;
        NSString *text = pk ? [[NSString alloc] initWithData:pk encoding:NSUTF8StringEncoding] : nil;
        if (!text.length || [text rangeOfString:@"Package:"].location == NSNotFound) {
            self->_lastError = pkErr ?: @"That URL doesn't look like an APT source (no Packages file).";
            [NSNotificationCenter.defaultCenter postNotificationName:CBStoreDidChange object:nil];
            if (done) done(self->_lastError);
            return;
        }
        self->_lastError = nil;
        self->_lastRefresh = [NSDate date];
        NSString *dir = self.cacheDir;
        [pk writeToFile:[dir stringByAppendingPathComponent:@"Packages"] atomically:YES];
        if (apps) [apps writeToFile:[dir stringByAppendingPathComponent:@"apps.json"] atomically:YES];
        if (feat) [feat writeToFile:[dir stringByAppendingPathComponent:@"featured.json"] atomically:YES];
        [self->_depictions removeAllObjects];
        [self rebuildFromPackages:text apps:apps featured:feat];
        [NSNotificationCenter.defaultCenter postNotificationName:CBStoreDidChange object:nil];
        if (done) done(nil);
    });
}

- (CBItem *)itemForID:(NSString *)pid {
    for (CBItem *i in _items) if ([i.pid isEqualToString:pid]) return i;
    return nil;
}

#pragma mark tracking

- (NSString *)trackedVersion:(CBItem *)item {
    return [NSUserDefaults.standardUserDefaults dictionaryForKey:@"tracked"][item.pid];
}
- (void)track:(CBItem *)item version:(NSString *)version {
    NSMutableDictionary *t = [[NSUserDefaults.standardUserDefaults dictionaryForKey:@"tracked"] mutableCopy] ?: [NSMutableDictionary new];
    t[item.pid] = version ?: item.latest;
    [NSUserDefaults.standardUserDefaults setObject:t forKey:@"tracked"];
    [NSNotificationCenter.defaultCenter postNotificationName:CBStoreDidChange object:nil];
}
- (void)untrack:(CBItem *)item {
    NSMutableDictionary *t = [[NSUserDefaults.standardUserDefaults dictionaryForKey:@"tracked"] mutableCopy];
    [t removeObjectForKey:item.pid];
    [NSUserDefaults.standardUserDefaults setObject:t ?: @{} forKey:@"tracked"];
    [NSNotificationCenter.defaultCenter postNotificationName:CBStoreDidChange object:nil];
}
- (void)untrackAll {
    [NSUserDefaults.standardUserDefaults setObject:@{} forKey:@"tracked"];
    [NSNotificationCenter.defaultCenter postNotificationName:CBStoreDidChange object:nil];
}
- (NSArray<CBItem *> *)trackedUpdates {
    NSMutableArray *a = [NSMutableArray new];
    for (CBItem *i in _items) if (CBNewer(i.latest, [self trackedVersion:i])) [a addObject:i];
    return a;
}
- (NSArray<CBItem *> *)newItems {
    NSDictionary *known = [NSUserDefaults.standardUserDefaults dictionaryForKey:@"known"];
    if (!known) return @[];
    NSMutableArray *a = [NSMutableArray new];
    for (CBItem *i in _items) if (!known[i.pid]) [a addObject:i];
    return a;
}
- (NSArray<CBItem *> *)updatedItems {
    NSDictionary *known = [NSUserDefaults.standardUserDefaults dictionaryForKey:@"known"];
    NSMutableArray *a = [NSMutableArray new];
    for (CBItem *i in _items)
        if (known[i.pid] && CBNewer(i.latest, known[i.pid]) && !CBNewer(i.latest, [self trackedVersion:i])) [a addObject:i];
    return a;
}
- (void)markAllSeen {
    NSMutableDictionary *k = [NSMutableDictionary new];
    for (CBItem *i in _items) if (i.latest) k[i.pid] = i.latest;
    [NSUserDefaults.standardUserDefaults setObject:k forKey:@"known"];
    [NSNotificationCenter.defaultCenter postNotificationName:CBStoreDidChange object:nil];
}
- (BOOL)selfUpdateAvailable {
    NSString *mine = NSBundle.mainBundle.infoDictionary[@"CFBundleShortVersionString"];
    return CBNewer([_selfUpdate[@"version"] description], mine) && _selfUpdate[@"url"];
}
- (NSInteger)badgeCount {
    return self.trackedUpdates.count + self.newItems.count + self.updatedItems.count + (self.selfUpdateAvailable ? 1 : 0);
}

- (void)depictionFor:(CBItem *)item done:(void (^)(NSDictionary *))done {
    NSString *url = item.sileoDepiction;
    if (!url.length) { done(nil); return; }
    if (_depictions[url]) { done(_depictions[url]); return; }
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[self abs:url]];
    req.cachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
    [[NSURLSession.sharedSession dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *r, NSError *e) {
        NSDictionary *j = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        if (![j isKindOfClass:NSDictionary.class]) j = nil;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (j) self->_depictions[url] = j;
            done(j);
        });
    }] resume];
}
@end

#pragma mark - Image loading

@interface CBImages : NSObject
+ (void)load:(NSString *)url into:(UIImageView *)iv placeholder:(UIImage *)ph;
+ (void)clear;
@end
@implementation CBImages
static NSCache *gImgCache;
static const void *kURLKey = &kURLKey;
+ (NSString *)dir {
    NSString *d = [NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES).firstObject
        stringByAppendingPathComponent:@"img"];
    [NSFileManager.defaultManager createDirectoryAtPath:d withIntermediateDirectories:YES attributes:nil error:nil];
    return d;
}
+ (NSString *)pathFor:(NSString *)url {
    NSMutableString *s = [NSMutableString new];
    for (NSUInteger i = 0; i < url.length; i++) {
        unichar c = [url characterAtIndex:i];
        [s appendFormat:@"%c", (isalnum(c) || c == '.' || c == '-' || c == '_') ? (char)c : '_'];
    }
    if (s.length > 200) s = [[s substringFromIndex:s.length - 200] mutableCopy];
    return [self.dir stringByAppendingPathComponent:s];
}
+ (void)clear {
    [gImgCache removeAllObjects];
    [NSFileManager.defaultManager removeItemAtPath:self.dir error:nil];
}
+ (void)load:(NSString *)url into:(UIImageView *)iv placeholder:(UIImage *)ph {
    if (!gImgCache) gImgCache = [NSCache new];
    objc_setAssociatedObject(iv, kURLKey, url, OBJC_ASSOCIATION_COPY_NONATOMIC);
    if (!url.length) { iv.image = ph; return; }
    UIImage *hit = [gImgCache objectForKey:url];
    if (hit) { iv.image = hit; return; }
    iv.image = ph;
    NSString *path = [self pathFor:url];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        UIImage *disk = [UIImage imageWithContentsOfFile:path];
        void (^apply)(UIImage *) = ^(UIImage *img) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (!img) return;
                [gImgCache setObject:img forKey:url];
                if ([objc_getAssociatedObject(iv, kURLKey) isEqualToString:url]) {
                    [UIView transitionWithView:iv duration:0.15 options:UIViewAnimationOptionTransitionCrossDissolve
                                    animations:^{ iv.image = img; } completion:nil];
                }
            });
        };
        if (disk) {
            apply(disk);
            NSDictionary *attr = [NSFileManager.defaultManager attributesOfItemAtPath:path error:nil];
            if (-[attr.fileModificationDate timeIntervalSinceNow] < 6 * 3600) return; // fresh enough
        }
        NSURL *u = [[CBStore shared] abs:url];
        if (!u) return;
        [[NSURLSession.sharedSession dataTaskWithURL:u completionHandler:^(NSData *data, NSURLResponse *r, NSError *e) {
            UIImage *img = data ? [UIImage imageWithData:data scale:UIScreen.mainScreen.scale] : nil;
            if (!img) return;
            [data writeToFile:path atomically:YES];
            apply(img);
        }] resume];
    });
}
@end

#pragma mark - Mini markdown

static NSAttributedString *CBInline(NSString *s, UIFont *font, UIColor *color) {
    NSMutableAttributedString *out = [NSMutableAttributedString new];
    static NSRegularExpression *re;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        re = [NSRegularExpression regularExpressionWithPattern:@"(\\*\\*[^*]+\\*\\*|__[^_]+__|`[^`]+`|\\[[^\\]]+\\]\\([^)]+\\)|\\*[^*\\s][^*]*\\*)"
                                                       options:0 error:nil];
    });
    NSDictionary *plain = @{NSFontAttributeName: font, NSForegroundColorAttributeName: color};
    __block NSUInteger pos = 0;
    [re enumerateMatchesInString:s options:0 range:NSMakeRange(0, s.length) usingBlock:^(NSTextCheckingResult *m, NSMatchingFlags f, BOOL *stop) {
        if (m.range.location > pos)
            [out appendAttributedString:[[NSAttributedString alloc] initWithString:[s substringWithRange:NSMakeRange(pos, m.range.location - pos)] attributes:plain]];
        NSString *tok = [s substringWithRange:m.range];
        NSString *text = tok;
        NSMutableDictionary *attrs = [plain mutableCopy];
        if ([tok hasPrefix:@"**"] || [tok hasPrefix:@"__"]) {
            text = [tok substringWithRange:NSMakeRange(2, tok.length - 4)];
            UIFontDescriptor *d = [font.fontDescriptor fontDescriptorWithSymbolicTraits:UIFontDescriptorTraitBold];
            attrs[NSFontAttributeName] = d ? [UIFont fontWithDescriptor:d size:font.pointSize] : font;
        } else if ([tok hasPrefix:@"`"]) {
            text = [tok substringWithRange:NSMakeRange(1, tok.length - 2)];
            attrs[NSFontAttributeName] = [UIFont monospacedSystemFontOfSize:font.pointSize - 1 weight:UIFontWeightRegular];
            attrs[NSBackgroundColorAttributeName] = UIColor.tertiarySystemFillColor;
        } else if ([tok hasPrefix:@"["]) {
            NSRange close = [tok rangeOfString:@"]("];
            text = [tok substringWithRange:NSMakeRange(1, close.location - 1)];
            attrs[NSForegroundColorAttributeName] = TINT;
        } else if ([tok hasPrefix:@"*"]) {
            text = [tok substringWithRange:NSMakeRange(1, tok.length - 2)];
            UIFontDescriptor *d = [font.fontDescriptor fontDescriptorWithSymbolicTraits:UIFontDescriptorTraitItalic];
            attrs[NSFontAttributeName] = d ? [UIFont fontWithDescriptor:d size:font.pointSize] : font;
        }
        [out appendAttributedString:[[NSAttributedString alloc] initWithString:text attributes:attrs]];
        pos = NSMaxRange(m.range);
    }];
    if (pos < s.length)
        [out appendAttributedString:[[NSAttributedString alloc] initWithString:[s substringFromIndex:pos] attributes:plain]];
    return out;
}

static NSAttributedString *CBMarkdown(NSString *md) {
    UIFont *body = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    NSMutableAttributedString *out = [NSMutableAttributedString new];
    NSArray *lines = [[md stringByReplacingOccurrencesOfString:@"\r" withString:@""] componentsSeparatedByString:@"\n"];
    static NSRegularExpression *numRe;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ numRe = [NSRegularExpression regularExpressionWithPattern:@"^(\\d+)[.)]\\s+" options:0 error:nil]; });
    BOOL first = YES;
    for (NSString *raw in lines) {
        NSString *line = [raw stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        if (!line.length) continue;
        if (!first) [out appendAttributedString:[[NSAttributedString alloc] initWithString:@"\n"]];
        first = NO;
        NSMutableParagraphStyle *ps = [NSMutableParagraphStyle new];
        ps.paragraphSpacing = 6;
        ps.lineSpacing = 2;
        UIFont *font = body;
        NSString *prefix = @"";
        if ([line hasPrefix:@"#"]) {
            NSUInteger n = 0;
            while (n < line.length && [line characterAtIndex:n] == '#') n++;
            line = [[line substringFromIndex:n] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
            font = [UIFont systemFontOfSize:body.pointSize + (n <= 1 ? 5 : n == 2 ? 3 : 1) weight:UIFontWeightBold];
            ps.paragraphSpacingBefore = 4;
        } else if ([line hasPrefix:@"- "] || [line hasPrefix:@"* "] || [line hasPrefix:@"+ "]) {
            line = [line substringFromIndex:2];
            prefix = @"•\t";
        } else {
            NSTextCheckingResult *m = [numRe firstMatchInString:line options:0 range:NSMakeRange(0, line.length)];
            if (m) {
                prefix = [NSString stringWithFormat:@"%@.\t", [line substringWithRange:[m rangeAtIndex:1]]];
                line = [line substringFromIndex:NSMaxRange(m.range)];
            }
        }
        if (prefix.length) {
            ps.tabStops = @[[[NSTextTab alloc] initWithTextAlignment:NSTextAlignmentLeft location:22 options:@{}]];
            ps.defaultTabInterval = 22;
            ps.headIndent = 22;
            ps.paragraphSpacing = 3;
        }
        NSMutableAttributedString *para = [NSMutableAttributedString new];
        if (prefix.length)
            [para appendAttributedString:[[NSAttributedString alloc] initWithString:prefix
                                                                         attributes:@{NSFontAttributeName: font, NSForegroundColorAttributeName: TINT}]];
        [para appendAttributedString:CBInline(line, font, UIColor.labelColor)];
        [para addAttribute:NSParagraphStyleAttributeName value:ps range:NSMakeRange(0, para.length)];
        [out appendAttributedString:para];
    }
    return out;
}

#pragma mark - Actions (Get / install / download)

static void CBAlert(UIViewController *vc, NSString *title, NSString *msg) {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:title message:msg preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
    [vc presentViewController:a animated:YES completion:nil];
}

static void CBOpen(UIViewController *vc, NSString *url, NSString *appName, void (^ok)(void)) {
    NSURL *u = [NSURL URLWithString:url];
    if (!u) { CBAlert(vc, @"Bad link", url); return; }
    [UIApplication.sharedApplication openURL:u options:@{} completionHandler:^(BOOL success) {
        if (success) { if (ok) ok(); }
        else if (appName) CBAlert(vc, [NSString stringWithFormat:@"Couldn't open %@", appName],
                                  [NSString stringWithFormat:@"%@ doesn't seem to be installed on this device.", appName]);
    }];
}

static NSString *CBEnc(NSString *s) {
    NSMutableCharacterSet *cs = [NSCharacterSet.alphanumericCharacterSet mutableCopy];
    [cs addCharactersInString:@"-._~"];
    return [s stringByAddingPercentEncodingWithAllowedCharacters:cs];
}

static void CBPresentFrom(UIViewController *vc, UIViewController *sheet, UIView *src) {
    UIPopoverPresentationController *pop = sheet.popoverPresentationController;
    if (pop) {
        pop.sourceView = src ?: vc.view;
        pop.sourceRect = src ? src.bounds : CGRectMake(CGRectGetMidX(vc.view.bounds), CGRectGetMidY(vc.view.bounds), 1, 1);
    }
    [vc presentViewController:sheet animated:YES completion:nil];
}

// Downloads a file with a progress alert, then offers the share sheet ("Open in Filza", "Save to Files", Benstore…).
static void CBDownload(UIViewController *vc, NSURL *url, UIView *src, void (^finished)(void)) {
    UIAlertController *hud = [UIAlertController alertControllerWithTitle:@"Downloading"
                                                                 message:url.lastPathComponent
                                                          preferredStyle:UIAlertControllerStyleAlert];
    __block NSURLSessionDownloadTask *task = nil;
    __block NSTimer *timer = nil;
    [hud addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:^(UIAlertAction *a) {
        [task cancel];
        [timer invalidate];
    }]];
    task = [NSURLSession.sharedSession downloadTaskWithURL:url completionHandler:^(NSURL *loc, NSURLResponse *resp, NSError *err) {
        NSInteger code = [resp isKindOfClass:NSHTTPURLResponse.class] ? ((NSHTTPURLResponse *)resp).statusCode : 0;
        NSURL *dest = nil;
        if (loc && !err && code == 200) {
            NSString *dir = [NSTemporaryDirectory() stringByAppendingPathComponent:@"downloads"];
            [NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
            NSString *name = url.lastPathComponent.stringByRemovingPercentEncoding ?: url.lastPathComponent;
            dest = [NSURL fileURLWithPath:[dir stringByAppendingPathComponent:name]];
            [NSFileManager.defaultManager removeItemAtURL:dest error:nil];
            if (![NSFileManager.defaultManager moveItemAtURL:loc toURL:dest error:nil]) dest = nil;
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            [timer invalidate];
            if (err.code == NSURLErrorCancelled) return;
            [hud dismissViewControllerAnimated:YES completion:^{
                if (!dest) {
                    CBAlert(vc, @"Download failed", err.localizedDescription ?: [NSString stringWithFormat:@"HTTP %ld", (long)code]);
                    return;
                }
                if (finished) finished();
                UIActivityViewController *share = [[UIActivityViewController alloc] initWithActivityItems:@[dest] applicationActivities:nil];
                CBPresentFrom(vc, share, src);
            }];
        });
    }];
    [vc presentViewController:hud animated:YES completion:^{
        [task resume];
        timer = [NSTimer scheduledTimerWithTimeInterval:0.2 repeats:YES block:^(NSTimer *t) {
            double f = task.progress.fractionCompleted;
            if (f > 0) hud.message = [NSString stringWithFormat:@"%@\n%d%%", url.lastPathComponent, (int)(f * 100)];
        }];
    }];
}

static void CBPresentGet(UIViewController *vc, CBItem *it, UIView *src) {
    CBStore *st = [CBStore shared];
    NSString *tracked = [st trackedVersion:it];
    NSString *msg;
    if (it.isApp) msg = [NSString stringWithFormat:@"%@ %@ · TrollStore app%@", it.name, it.latest,
                         it.appSize ? [@" · " stringByAppendingString:CBSize(it.appSize)] : @""];
    else msg = [NSString stringWithFormat:@"%@ %@ · Cobalt needs to be added as a source in your package manager first.", it.name, it.latest];
    UIAlertController *s = [UIAlertController alertControllerWithTitle:it.name message:msg preferredStyle:UIAlertControllerStyleActionSheet];
    void (^track)(void) = ^{ [st track:it version:it.latest]; };

    if (it.isApp) {
        [s addAction:[UIAlertAction actionWithTitle:@"Install with TrollStore" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
            CBOpen(vc, [@"apple-magnifier://install?url=" stringByAppendingString:CBEnc(it.appURL)], @"TrollStore", track);
        }]];
        [s addAction:[UIAlertAction actionWithTitle:@"Download .tipa" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
            CBDownload(vc, [NSURL URLWithString:it.appURL], src, track);
        }]];
    } else {
        [s addAction:[UIAlertAction actionWithTitle:@"Open in Sileo" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
            CBOpen(vc, [@"sileo://package/" stringByAppendingString:it.pid], @"Sileo", track);
        }]];
        [s addAction:[UIAlertAction actionWithTitle:@"Open in Zebra" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
            CBOpen(vc, [@"zbra://packages/" stringByAppendingString:it.pid], @"Zebra", track);
        }]];
        for (CBBuild *b in it.builds) {
            if (!b.filename.length) continue;
            NSString *t = [NSString stringWithFormat:@"Download .deb (%@%@)", CBArchName(b.arch),
                           b.size ? [@", " stringByAppendingString:CBSize(b.size)] : @""];
            [s addAction:[UIAlertAction actionWithTitle:t style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
                CBDownload(vc, [st abs:b.filename], src, track);
            }]];
        }
    }
    if (tracked) {
        [s addAction:[UIAlertAction actionWithTitle:[NSString stringWithFormat:@"Stop tracking (have %@)", tracked]
                                              style:UIAlertActionStyleDestructive handler:^(UIAlertAction *a) { [st untrack:it]; }]];
    } else {
        [s addAction:[UIAlertAction actionWithTitle:@"I already have this installed" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
            UIAlertController *v = [UIAlertController alertControllerWithTitle:@"Which version do you have?"
                                                                       message:@"Cobalt will tell you when a newer one comes out."
                                                                preferredStyle:UIAlertControllerStyleActionSheet];
            for (NSString *ver in it.allVersions)
                [v addAction:[UIAlertAction actionWithTitle:ver style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) { [st track:it version:ver]; }]];
            [v addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
            CBPresentFrom(vc, v, src);
        }]];
    }
    [s addAction:[UIAlertAction actionWithTitle:@"Copy Link" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        UIPasteboard.generalPasteboard.string = it.isApp ? it.appURL : (it.depiction ?: [st abs:@""].absoluteString);
    }]];
    [s addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    CBPresentFrom(vc, s, src);
}

static NSString *CBButtonTitle(CBItem *it) {
    return CBNewer(it.latest, [[CBStore shared] trackedVersion:it]) ? @"UPDATE" : @"GET";
}

#pragma mark - Cells

@interface CBItemCell : UITableViewCell
@property (strong) UIImageView *icon;
@property (strong) UILabel *title, *sub, *meta;
@property (strong) UIButton *get;
@property (strong) CBItem *item;
@property (copy) void (^onGet)(CBItem *, UIButton *);
- (void)configure:(CBItem *)it;
@end

@implementation CBItemCell
- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)rid {
    if ((self = [super initWithStyle:UITableViewCellStyleDefault reuseIdentifier:rid])) {
        _icon = [UIImageView new];
        _icon.layer.cornerRadius = 13;
        _icon.layer.cornerCurve = kCACornerCurveContinuous;
        _icon.layer.borderWidth = 0.5;
        _icon.layer.borderColor = [UIColor.separatorColor CGColor];
        _icon.clipsToBounds = YES;
        _icon.contentMode = UIViewContentModeScaleAspectFill;
        _title = [UILabel new];
        _title.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
        _sub = [UILabel new];
        _sub.font = [UIFont systemFontOfSize:13];
        _sub.textColor = UIColor.secondaryLabelColor;
        _sub.numberOfLines = 2;
        _meta = [UILabel new];
        _meta.font = [UIFont systemFontOfSize:11 weight:UIFontWeightMedium];
        _meta.textColor = UIColor.tertiaryLabelColor;
        _get = [UIButton buttonWithType:UIButtonTypeSystem];
        _get.titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightBold];
        _get.backgroundColor = UIColor.tertiarySystemFillColor;
        _get.tintColor = TINT;
        _get.layer.cornerRadius = 14;
        _get.contentEdgeInsets = UIEdgeInsetsMake(0, 14, 0, 14);
        [_get addTarget:self action:@selector(tapGet) forControlEvents:UIControlEventTouchUpInside];
        UIStackView *text = [[UIStackView alloc] initWithArrangedSubviews:@[_title, _sub, _meta]];
        text.axis = UILayoutConstraintAxisVertical;
        text.spacing = 1;
        for (UIView *v in @[_icon, text, _get]) {
            v.translatesAutoresizingMaskIntoConstraints = NO;
            [self.contentView addSubview:v];
        }
        UILayoutGuide *m = self.contentView.layoutMarginsGuide;
        [_get setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
        [_get setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
        [NSLayoutConstraint activateConstraints:@[
            [_icon.leadingAnchor constraintEqualToAnchor:m.leadingAnchor],
            [_icon.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor],
            [_icon.widthAnchor constraintEqualToConstant:58],
            [_icon.heightAnchor constraintEqualToConstant:58],
            [text.leadingAnchor constraintEqualToAnchor:_icon.trailingAnchor constant:12],
            [text.trailingAnchor constraintEqualToAnchor:_get.leadingAnchor constant:-10],
            [text.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor],
            [_get.trailingAnchor constraintEqualToAnchor:m.trailingAnchor],
            [_get.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor],
            [_get.heightAnchor constraintEqualToConstant:28],
            [_get.widthAnchor constraintGreaterThanOrEqualToConstant:72],
        ]];
        self.accessoryType = UITableViewCellAccessoryNone;
    }
    return self;
}
- (void)tapGet { if (self.onGet) self.onGet(self.item, self.get); }
- (void)configure:(CBItem *)it {
    self.item = it;
    _title.text = it.name;
    _sub.text = it.desc;
    NSString *tracked = [[CBStore shared] trackedVersion:it];
    NSMutableArray *bits = [NSMutableArray arrayWithObject:[@"v" stringByAppendingString:it.latest ?: @"?"]];
    if (it.isApp) [bits addObject:@"TrollStore"];
    else {
        NSMutableArray *archs = [NSMutableArray new];
        for (CBBuild *b in it.builds) [archs addObject:CBArchName(b.arch)];
        if (archs.count) [bits addObject:[archs componentsJoinedByString:@" + "]];
    }
    if (tracked) [bits addObject:[NSString stringWithFormat:@"you have %@", tracked]];
    _meta.text = [bits componentsJoinedByString:@" · "];
    [_get setTitle:CBButtonTitle(it) forState:UIControlStateNormal];
    UIImage *ph = [UIImage systemImageNamed:it.isApp ? @"app.fill" : @"cube.box.fill"];
    [CBImages load:it.iconURL into:_icon placeholder:ph];
}
@end

#pragma mark - Banner carousel

@interface CBBannerView : UIView <UIScrollViewDelegate>
@property (strong) UIScrollView *scroll;
@property (nonatomic, strong) NSArray<NSDictionary *> *banners;
@property (strong) NSMutableArray<UIView *> *cards;
@property (copy) void (^onTap)(NSString *pid);
+ (CGFloat)heightForWidth:(CGFloat)w;
@end

@implementation CBBannerView
+ (CGFloat)cardWidth:(CGFloat)w { return MIN(w - 48, 440); }
+ (CGFloat)heightForWidth:(CGFloat)w { return round([self cardWidth:w] * 148.0 / 263.0) + 44; }
- (instancetype)initWithFrame:(CGRect)f {
    if ((self = [super initWithFrame:f])) {
        _scroll = [[UIScrollView alloc] initWithFrame:self.bounds];
        _scroll.showsHorizontalScrollIndicator = NO;
        _scroll.decelerationRate = UIScrollViewDecelerationRateFast;
        _scroll.delegate = self;
        _scroll.clipsToBounds = NO;
        [self addSubview:_scroll];
        _cards = [NSMutableArray new];
    }
    return self;
}
- (void)setBanners:(NSArray<NSDictionary *> *)banners {
    _banners = banners;
    for (UIView *v in _cards) [v removeFromSuperview];
    [_cards removeAllObjects];
    NSInteger i = 0;
    for (NSDictionary *b in banners) {
        UIView *card = [UIView new];
        card.layer.cornerRadius = 14;
        card.layer.cornerCurve = kCACornerCurveContinuous;
        card.layer.shadowColor = UIColor.blackColor.CGColor;
        card.layer.shadowOpacity = 0.18;
        card.layer.shadowRadius = 8;
        card.layer.shadowOffset = CGSizeMake(0, 4);
        UIImageView *iv = [UIImageView new];
        iv.contentMode = UIViewContentModeScaleAspectFill;
        iv.clipsToBounds = YES;
        iv.layer.cornerRadius = 14;
        iv.layer.cornerCurve = kCACornerCurveContinuous;
        iv.backgroundColor = [TINT colorWithAlphaComponent:0.25];
        iv.tag = 1;
        [card addSubview:iv];
        [CBImages load:b[@"url"] into:iv placeholder:nil];
        card.tag = i++;
        [card addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(tap:)]];
        [_scroll addSubview:card];
        [_cards addObject:card];
    }
    [self setNeedsLayout];
}
- (void)tap:(UITapGestureRecognizer *)g {
    NSDictionary *b = _banners[g.view.tag];
    if (self.onTap && b[@"package"]) self.onTap(b[@"package"]);
}
- (CGFloat)step { return [CBBannerView cardWidth:self.bounds.size.width] + 12; }
- (void)layoutSubviews {
    [super layoutSubviews];
    _scroll.frame = self.bounds;
    CGFloat w = [CBBannerView cardWidth:self.bounds.size.width];
    CGFloat h = round(w * 148.0 / 263.0);
    CGFloat x = 20;
    for (UIView *c in _cards) {
        c.frame = CGRectMake(x, 14, w, h);
        c.layer.shadowPath = [UIBezierPath bezierPathWithRoundedRect:c.bounds cornerRadius:14].CGPath;
        [c viewWithTag:1].frame = c.bounds;
        x += w + 12;
    }
    _scroll.contentSize = CGSizeMake(x + 8, self.bounds.size.height);
}
- (void)scrollViewWillEndDragging:(UIScrollView *)sv withVelocity:(CGPoint)v targetContentOffset:(inout CGPoint *)target {
    CGFloat step = self.step;
    CGFloat page = round(target->x / step);
    if (v.x > 0.2) page = floor(sv.contentOffset.x / step) + 1;
    else if (v.x < -0.2) page = ceil(sv.contentOffset.x / step) - 1;
    page = MAX(0, MIN(page, (CGFloat)_cards.count - 1));
    CGFloat maxX = MAX(0, sv.contentSize.width - sv.bounds.size.width);
    target->x = MIN(page * step, maxX);
}
@end

#pragma mark - Detail

@interface CBDetailVC : UIViewController
- (instancetype)initWithItem:(CBItem *)item;
@end

@implementation CBDetailVC {
    CBItem *_item;
    UIScrollView *_scroll;
    UIStackView *_stack, *_content;
    UIImageView *_banner, *_icon;
    UIButton *_get;
    UILabel *_trackLabel;
    UISegmentedControl *_seg;
    NSArray *_tabs;
}
- (instancetype)initWithItem:(CBItem *)item {
    if ((self = [super init])) {
        _item = item;
        self.title = item.name;
        self.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeNever;
    }
    return self;
}
- (void)dealloc { [NSNotificationCenter.defaultCenter removeObserver:self]; }

- (UILabel *)label:(NSString *)t font:(UIFont *)f color:(UIColor *)c {
    UILabel *l = [UILabel new];
    l.text = t;
    l.font = f;
    l.textColor = c;
    l.numberOfLines = 0;
    return l;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    _scroll = [UIScrollView new];
    _scroll.alwaysBounceVertical = YES;
    _scroll.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:_scroll];
    _stack = [UIStackView new];
    _stack.axis = UILayoutConstraintAxisVertical;
    _stack.spacing = 14;
    _stack.translatesAutoresizingMaskIntoConstraints = NO;
    _stack.layoutMarginsRelativeArrangement = YES;
    _stack.directionalLayoutMargins = NSDirectionalEdgeInsetsMake(12, 20, 30, 20);
    [_scroll addSubview:_stack];
    [NSLayoutConstraint activateConstraints:@[
        [_scroll.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [_scroll.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [_scroll.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [_scroll.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [_stack.topAnchor constraintEqualToAnchor:_scroll.contentLayoutGuide.topAnchor],
        [_stack.bottomAnchor constraintEqualToAnchor:_scroll.contentLayoutGuide.bottomAnchor],
        [_stack.centerXAnchor constraintEqualToAnchor:_scroll.frameLayoutGuide.centerXAnchor],
        [_stack.widthAnchor constraintEqualToAnchor:_scroll.frameLayoutGuide.widthAnchor],
    ]];

    // banner
    _banner = [UIImageView new];
    _banner.contentMode = UIViewContentModeScaleAspectFill;
    _banner.clipsToBounds = YES;
    _banner.layer.cornerRadius = 16;
    _banner.layer.cornerCurve = kCACornerCurveContinuous;
    _banner.backgroundColor = [TINT colorWithAlphaComponent:0.2];
    [_banner.heightAnchor constraintEqualToAnchor:_banner.widthAnchor multiplier:148.0 / 263.0].active = YES;
    [_stack addArrangedSubview:_banner];
    NSString *bannerURL = _item.isApp ? nil : [[CBStore shared] abs:[NSString stringWithFormat:@"assets/banner_%@.png", _item.pid]].absoluteString;
    for (NSDictionary *b in [CBStore shared].banners)
        if ([b[@"package"] isEqualToString:_item.pid]) bannerURL = b[@"url"];
    if (bannerURL) [CBImages load:bannerURL into:_banner placeholder:nil];
    else _banner.hidden = YES;

    // header row
    _icon = [UIImageView new];
    _icon.layer.cornerRadius = 20;
    _icon.layer.cornerCurve = kCACornerCurveContinuous;
    _icon.layer.borderWidth = 0.5;
    _icon.layer.borderColor = UIColor.separatorColor.CGColor;
    _icon.clipsToBounds = YES;
    [_icon.widthAnchor constraintEqualToConstant:88].active = YES;
    [_icon.heightAnchor constraintEqualToConstant:88].active = YES;
    [CBImages load:_item.iconURL into:_icon placeholder:[UIImage systemImageNamed:_item.isApp ? @"app.fill" : @"cube.box.fill"]];

    UILabel *name = [self label:_item.name font:[UIFont systemFontOfSize:22 weight:UIFontWeightBold] color:UIColor.labelColor];
    UILabel *author = [self label:[NSString stringWithFormat:@"%@ · %@", _item.author ?: @"MYM Culture", _item.section ?: @""]
                             font:[UIFont systemFontOfSize:14] color:UIColor.secondaryLabelColor];
    _get = [UIButton buttonWithType:UIButtonTypeSystem];
    _get.backgroundColor = TINT;
    _get.tintColor = UIColor.whiteColor;
    _get.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightBold];
    _get.layer.cornerRadius = 15;
    _get.contentEdgeInsets = UIEdgeInsetsMake(0, 22, 0, 22);
    [_get.heightAnchor constraintEqualToConstant:30].active = YES;
    [_get addTarget:self action:@selector(getTapped) forControlEvents:UIControlEventTouchUpInside];
    UIStackView *getRow = [[UIStackView alloc] initWithArrangedSubviews:@[_get, [UIView new]]];
    UIStackView *nameCol = [[UIStackView alloc] initWithArrangedSubviews:@[name, author, getRow]];
    nameCol.axis = UILayoutConstraintAxisVertical;
    nameCol.spacing = 4;
    [nameCol setCustomSpacing:10 afterView:author];
    UIStackView *head = [[UIStackView alloc] initWithArrangedSubviews:@[_icon, nameCol]];
    head.spacing = 14;
    head.alignment = UIStackViewAlignmentCenter;
    [_stack addArrangedSubview:head];

    _trackLabel = [self label:nil font:[UIFont systemFontOfSize:13 weight:UIFontWeightMedium] color:TINT];
    [_stack addArrangedSubview:_trackLabel];

    _seg = [[UISegmentedControl alloc] initWithItems:@[@"Details"]];
    _seg.hidden = YES;
    [_seg addTarget:self action:@selector(segChanged) forControlEvents:UIControlEventValueChanged];
    [_stack addArrangedSubview:_seg];

    _content = [UIStackView new];
    _content.axis = UILayoutConstraintAxisVertical;
    _content.spacing = 10;
    [_stack addArrangedSubview:_content];

    [self showFallback];
    [self refreshHeader];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(refreshHeader) name:CBStoreDidChange object:nil];

    UIActivityIndicatorView *spin = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    [spin startAnimating];
    [_content addArrangedSubview:spin];
    __weak typeof(self) ws = self;
    [[CBStore shared] depictionFor:_item done:^(NSDictionary *dep) {
        [spin removeFromSuperview];
        [ws applyDepiction:dep];
    }];
}

- (void)refreshHeader {
    [_get setTitle:CBButtonTitle(_item) forState:UIControlStateNormal];
    NSString *tracked = [[CBStore shared] trackedVersion:_item];
    if (!tracked) _trackLabel.text = nil;
    else if (CBNewer(_item.latest, tracked))
        _trackLabel.text = [NSString stringWithFormat:@"⬆︎ Update available: you have %@, latest is %@", tracked, _item.latest];
    else _trackLabel.text = [NSString stringWithFormat:@"✓ You have %@ — Cobalt will tell you when it updates", tracked];
    _trackLabel.hidden = !tracked;
}

- (void)getTapped { CBPresentGet(self, _item, _get); }

- (void)showFallback {
    for (UIView *v in _content.arrangedSubviews) [v removeFromSuperview];
    if (_item.desc.length) [_content addArrangedSubview:[self markdownView:_item.desc]];
    [self addInfoTable];
}

- (void)addInfoTable {
    [_content addArrangedSubview:[self separator]];
    [_content addArrangedSubview:[self header:@"Information" sub:NO]];
    [_content addArrangedSubview:[self row:@"Version" value:_item.latest]];
    if (_item.isApp) {
        [_content addArrangedSubview:[self row:@"Installs with" value:@"TrollStore"]];
        if (_item.minOS) [_content addArrangedSubview:[self row:@"Requires" value:[@"iOS " stringByAppendingString:_item.minOS]]];
        if (_item.appSize) [_content addArrangedSubview:[self row:@"Size" value:CBSize(_item.appSize)]];
    } else {
        for (CBBuild *b in _item.builds)
            [_content addArrangedSubview:[self row:CBArchName(b.arch) value:CBSize(b.size).length ? CBSize(b.size) : @"available"]];
        CBBuild *b = _item.builds.firstObject;
        if (b.depends.length) [_content addArrangedSubview:[self row:@"Depends" value:b.depends]];
    }
    [_content addArrangedSubview:[self row:@"Identifier" value:_item.pid]];
}

- (void)applyDepiction:(NSDictionary *)dep {
    if (!dep) return;
    NSArray *tabs = nil;
    if ([dep[@"class"] isEqualToString:@"DepictionTabView"] && [dep[@"tabs"] isKindOfClass:NSArray.class]) tabs = dep[@"tabs"];
    else tabs = @[dep];
    _tabs = tabs;
    [_seg removeAllSegments];
    for (NSUInteger i = 0; i < tabs.count; i++)
        [_seg insertSegmentWithTitle:[tabs[i][@"tabname"] description] ?: @"Details" atIndex:i animated:NO];
    _seg.selectedSegmentIndex = 0;
    _seg.hidden = tabs.count < 2;
    [self segChanged];
}

- (void)segChanged {
    if (!_tabs.count) return;
    for (UIView *v in _content.arrangedSubviews) [v removeFromSuperview];
    [self render:_tabs[MAX(0, _seg.selectedSegmentIndex)] into:_content];
}

- (UIView *)separator {
    UIView *line = [UIView new];
    line.backgroundColor = UIColor.separatorColor;
    [line.heightAnchor constraintEqualToConstant:1.0 / UIScreen.mainScreen.scale].active = YES;
    UIStackView *wrap = [[UIStackView alloc] initWithArrangedSubviews:@[line]];
    wrap.layoutMarginsRelativeArrangement = YES;
    wrap.directionalLayoutMargins = NSDirectionalEdgeInsetsMake(4, 0, 4, 0);
    return wrap;
}
- (UIView *)header:(NSString *)t sub:(BOOL)sub {
    return [self label:t font:[UIFont systemFontOfSize:sub ? 17 : 20 weight:UIFontWeightBold] color:UIColor.labelColor];
}
- (UIView *)markdownView:(NSString *)md {
    UILabel *l = [UILabel new];
    l.numberOfLines = 0;
    l.attributedText = CBMarkdown(md);
    return l;
}
- (UIView *)row:(NSString *)title value:(NSString *)value {
    UILabel *a = [self label:title font:[UIFont systemFontOfSize:15] color:UIColor.secondaryLabelColor];
    UILabel *b = [self label:value font:[UIFont systemFontOfSize:15] color:UIColor.labelColor];
    b.textAlignment = NSTextAlignmentRight;
    [a setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [a setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    UIStackView *s = [[UIStackView alloc] initWithArrangedSubviews:@[a, b]];
    s.spacing = 12;
    s.alignment = UIStackViewAlignmentFirstBaseline;
    return s;
}

- (void)render:(NSDictionary *)v into:(UIStackView *)stack {
    if (![v isKindOfClass:NSDictionary.class]) return;
    NSString *cls = v[@"class"];
    if ([cls isEqualToString:@"DepictionStackView"] || [cls isEqualToString:@"DepictionAutoStackView"]) {
        for (NSDictionary *c in v[@"views"]) [self render:c into:stack];
    } else if ([cls isEqualToString:@"DepictionMarkdownView"]) {
        NSString *md = v[@"markdown"];
        if ([md isKindOfClass:NSString.class] && md.length) [stack addArrangedSubview:[self markdownView:md]];
    } else if ([cls isEqualToString:@"DepictionHeaderView"]) {
        [stack addArrangedSubview:[self header:v[@"title"] sub:NO]];
    } else if ([cls isEqualToString:@"DepictionSubheaderView"]) {
        [stack addArrangedSubview:[self header:v[@"title"] sub:YES]];
    } else if ([cls isEqualToString:@"DepictionSeparatorView"]) {
        [stack addArrangedSubview:[self separator]];
    } else if ([cls isEqualToString:@"DepictionTableTextView"]) {
        [stack addArrangedSubview:[self row:[v[@"title"] description] value:[v[@"text"] description]]];
    } else if ([cls isEqualToString:@"DepictionTableButtonView"] || [cls isEqualToString:@"DepictionButtonView"]) {
        NSString *action = v[@"action"];
        if (![action isKindOfClass:NSString.class]) return;
        UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
        [b setTitle:[NSString stringWithFormat:@"%@  ›", v[@"title"] ?: v[@"text"] ?: action] forState:UIControlStateNormal];
        b.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeading;
        b.titleLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightMedium];
        b.tintColor = TINT;
        b.accessibilityIdentifier = action;
        [b addTarget:self action:@selector(openButton:) forControlEvents:UIControlEventTouchUpInside];
        [stack addArrangedSubview:b];
    } else if ([cls isEqualToString:@"DepictionImageView"]) {
        UIImageView *iv = [UIImageView new];
        iv.contentMode = UIViewContentModeScaleAspectFit;
        iv.layer.cornerRadius = [v[@"cornerRadius"] doubleValue];
        iv.clipsToBounds = YES;
        double w = [v[@"width"] doubleValue], h = [v[@"height"] doubleValue];
        [iv.heightAnchor constraintEqualToConstant:h > 0 ? h : 200].active = YES;
        if (w > 0 && h > 0) iv.contentMode = UIViewContentModeScaleAspectFit;
        [CBImages load:v[@"URL"] into:iv placeholder:nil];
        [stack addArrangedSubview:iv];
    } else if ([cls isEqualToString:@"DepictionScreenshotsView"]) {
        // horizontal strip of screenshots
        UIScrollView *sv = [UIScrollView new];
        sv.showsHorizontalScrollIndicator = NO;
        double ih = 360;
        [sv.heightAnchor constraintEqualToConstant:ih].active = YES;
        UIStackView *row = [UIStackView new];
        row.spacing = 10;
        row.translatesAutoresizingMaskIntoConstraints = NO;
        [sv addSubview:row];
        [NSLayoutConstraint activateConstraints:@[
            [row.leadingAnchor constraintEqualToAnchor:sv.contentLayoutGuide.leadingAnchor],
            [row.trailingAnchor constraintEqualToAnchor:sv.contentLayoutGuide.trailingAnchor],
            [row.topAnchor constraintEqualToAnchor:sv.contentLayoutGuide.topAnchor],
            [row.heightAnchor constraintEqualToConstant:ih],
        ]];
        for (NSDictionary *s in v[@"screenshots"]) {
            UIImageView *iv = [UIImageView new];
            iv.contentMode = UIViewContentModeScaleAspectFill;
            iv.clipsToBounds = YES;
            iv.layer.cornerRadius = 12;
            [iv.widthAnchor constraintEqualToConstant:ih * 9 / 19.5].active = YES;
            [CBImages load:s[@"url"] into:iv placeholder:nil];
            [row addArrangedSubview:iv];
        }
        [stack addArrangedSubview:sv];
    } else if ([cls isEqualToString:@"DepictionSpacerView"]) {
        UIView *sp = [UIView new];
        [sp.heightAnchor constraintEqualToConstant:MAX(0, [v[@"spacing"] doubleValue])].active = YES;
        [stack addArrangedSubview:sp];
    } else if ([cls isEqualToString:@"DepictionLabelView"]) {
        UILabel *l = [self label:[v[@"text"] description] font:[UIFont systemFontOfSize:[v[@"fontSize"] doubleValue] ?: 15]
                           color:UIColor.secondaryLabelColor];
        NSString *al = [v[@"alignment"] description];
        l.textAlignment = [al isEqualToString:@"1"] ? NSTextAlignmentCenter : [al isEqualToString:@"2"] ? NSTextAlignmentRight : NSTextAlignmentLeft;
        [stack addArrangedSubview:l];
    }
}

- (void)openButton:(UIButton *)b {
    NSString *action = b.accessibilityIdentifier;
    if ([action hasPrefix:@"depiction-"]) action = [action substringFromIndex:10];
    NSURL *u = [[CBStore shared] abs:action];
    if (u) [UIApplication.sharedApplication openURL:u options:@{} completionHandler:nil];
}
@end

#pragma mark - Lists

@interface CBListVC : UITableViewController
@property (strong) NSArray<NSDictionary *> *sections; // {title, items, footer}
- (void)reload;
- (void)openItem:(CBItem *)it;
@end

@implementation CBListVC
- (instancetype)init { return [super initWithStyle:UITableViewStyleInsetGrouped]; }
- (void)viewDidLoad {
    [super viewDidLoad];
    self.navigationController.navigationBar.prefersLargeTitles = YES;
    [self.tableView registerClass:CBItemCell.class forCellReuseIdentifier:@"item"];
    self.tableView.rowHeight = 86;
    self.refreshControl = [UIRefreshControl new];
    [self.refreshControl addTarget:self action:@selector(pull) forControlEvents:UIControlEventValueChanged];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(reload) name:CBStoreDidChange object:nil];
    [self reload];
}
- (void)dealloc { [NSNotificationCenter.defaultCenter removeObserver:self]; }
- (void)pull {
    [[CBStore shared] refresh:^(NSString *err) {
        [self.refreshControl endRefreshing];
        if (err) CBAlert(self, @"Couldn't refresh", err);
    }];
}
- (void)reload { [self.tableView reloadData]; }
- (void)openItem:(CBItem *)it {
    [self.navigationController pushViewController:[[CBDetailVC alloc] initWithItem:it] animated:YES];
}
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv { return self.sections.count; }
- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s { return [self.sections[s][@"items"] count]; }
- (NSString *)tableView:(UITableView *)tv titleForHeaderInSection:(NSInteger)s { return self.sections[s][@"title"]; }
- (NSString *)tableView:(UITableView *)tv titleForFooterInSection:(NSInteger)s { return self.sections[s][@"footer"]; }
- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    CBItemCell *c = [tv dequeueReusableCellWithIdentifier:@"item" forIndexPath:ip];
    [c configure:self.sections[ip.section][@"items"][ip.row]];
    __weak typeof(self) ws = self;
    c.onGet = ^(CBItem *it, UIButton *b) { CBPresentGet(ws, it, b); };
    return c;
}
- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    [self openItem:self.sections[ip.section][@"items"][ip.row]];
}
@end

static NSArray<NSDictionary *> *CBGroupBySection(NSArray<CBItem *> *items) {
    NSMutableDictionary<NSString *, NSMutableArray *> *g = [NSMutableDictionary new];
    for (CBItem *i in items) {
        NSString *s = i.section ?: @"Other";
        if (!g[s]) g[s] = [NSMutableArray new];
        [g[s] addObject:i];
    }
    NSArray *keys = [g.allKeys sortedArrayUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
        NSInteger (^rank)(NSString *) = ^NSInteger(NSString *s) {
            if ([s isEqualToString:@"Tweaks"]) return 0;
            if ([s isEqualToString:@"TrollStore Apps"]) return 2;
            return 1;
        };
        NSInteger ra = rank(a), rb = rank(b);
        if (ra != rb) return ra < rb ? NSOrderedAscending : NSOrderedDescending;
        return [a localizedCaseInsensitiveCompare:b];
    }];
    NSMutableArray *out = [NSMutableArray new];
    for (NSString *k in keys) {
        NSArray *sorted = [g[k] sortedArrayUsingComparator:^NSComparisonResult(CBItem *a, CBItem *b) {
            return [a.name localizedCaseInsensitiveCompare:b.name];
        }];
        [out addObject:@{@"title": k, @"items": sorted}];
    }
    return out;
}

#pragma mark Home

@interface CBHomeVC : CBListVC
@end
@implementation CBHomeVC {
    CBBannerView *_bannerView;
    CGFloat _lastW;
    UIView *_empty;
}
- (void)viewDidLoad {
    self.title = @"Cobalt";
    _bannerView = [[CBBannerView alloc] initWithFrame:CGRectZero];
    __weak typeof(self) ws = self;
    _bannerView.onTap = ^(NSString *pid) {
        CBItem *it = [[CBStore shared] itemForID:pid];
        if (it) [ws openItem:it];
    };
    [super viewDidLoad];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"plus.app"]
                                                                              style:UIBarButtonItemStylePlain
                                                                             target:self action:@selector(addSource:)];
}
- (void)addSource:(UIBarButtonItem *)b {
    NSString *src = [CBStore shared].base;
    UIAlertController *s = [UIAlertController alertControllerWithTitle:@"Add Cobalt to your package manager"
                                                               message:src preferredStyle:UIAlertControllerStyleActionSheet];
    [s addAction:[UIAlertAction actionWithTitle:@"Sileo" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        CBOpen(self, [@"sileo://source/" stringByAppendingString:src], @"Sileo", nil);
    }]];
    [s addAction:[UIAlertAction actionWithTitle:@"Zebra" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        CBOpen(self, [@"zbra://sources/add/" stringByAppendingString:src], @"Zebra", nil);
    }]];
    [s addAction:[UIAlertAction actionWithTitle:@"Cydia" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        CBOpen(self, [@"cydia://url/https://cydia.saurik.com/api/share#?source=" stringByAppendingString:src], @"Cydia", nil);
    }]];
    [s addAction:[UIAlertAction actionWithTitle:@"Copy URL" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        UIPasteboard.generalPasteboard.string = src;
    }]];
    [s addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    if (s.popoverPresentationController) s.popoverPresentationController.barButtonItem = b;
    [self presentViewController:s animated:YES completion:nil];
}
- (void)reload {
    CBStore *st = [CBStore shared];
    NSMutableArray *secs = [NSMutableArray new];
    if (st.selfUpdateAvailable) [secs addObject:@{@"title": @"", @"items": @[], @"self": @YES}];
    [secs addObjectsFromArray:CBGroupBySection(st.items)];
    self.sections = secs;
    NSMutableArray *banners = [NSMutableArray new];
    for (NSDictionary *b in st.banners) if ([st itemForID:b[@"package"]]) [banners addObject:b];
    _bannerView.banners = banners;
    _lastW = 0;
    [self.view setNeedsLayout];
    if (!st.items.count) {
        UILabel *l = [UILabel new];
        l.numberOfLines = 0;
        l.textAlignment = NSTextAlignmentCenter;
        l.textColor = UIColor.secondaryLabelColor;
        l.text = st.loading ? @"Loading Cobalt…" : st.lastError ? [NSString stringWithFormat:@"Couldn't load the source.\n%@\n\nPull down to try again.", st.lastError] : @"Loading Cobalt…";
        self.tableView.backgroundView = l;
    } else self.tableView.backgroundView = nil;
    [super reload];
}
- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    CGFloat w = self.tableView.bounds.size.width;
    if (w == _lastW) return;
    _lastW = w;
    if (_bannerView.banners.count) {
        _bannerView.frame = CGRectMake(0, 0, w, [CBBannerView heightForWidth:w]);
        self.tableView.tableHeaderView = _bannerView;
    } else self.tableView.tableHeaderView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, w, 8)];
}
- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s {
    return self.sections[s][@"self"] ? 1 : [super tableView:tv numberOfRowsInSection:s];
}
- (CGFloat)tableView:(UITableView *)tv heightForRowAtIndexPath:(NSIndexPath *)ip {
    return self.sections[ip.section][@"self"] ? UITableViewAutomaticDimension : 86;
}
- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    if (!self.sections[ip.section][@"self"]) return [super tableView:tv cellForRowAtIndexPath:ip];
    UITableViewCell *c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    NSDictionary *u = [CBStore shared].selfUpdate;
    c.textLabel.text = [NSString stringWithFormat:@"Cobalt %@ is available", u[@"version"]];
    c.textLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
    c.detailTextLabel.text = [u[@"notes"] description] ?: @"Tap to download the new IPA, then sideload it over this one.";
    c.detailTextLabel.numberOfLines = 0;
    c.imageView.image = [UIImage systemImageNamed:@"arrow.down.circle.fill"];
    c.imageView.tintColor = TINT;
    c.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    return c;
}
- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    if (!self.sections[ip.section][@"self"]) { [super tableView:tv didSelectRowAtIndexPath:ip]; return; }
    [tv deselectRowAtIndexPath:ip animated:YES];
    CBDownload(self, [[CBStore shared] abs:[CBStore shared].selfUpdate[@"url"]], [tv cellForRowAtIndexPath:ip], nil);
}
@end

#pragma mark Search

@interface CBSearchVC : CBListVC <UISearchResultsUpdating>
@end
@implementation CBSearchVC {
    UISearchController *_sc;
}
- (void)viewDidLoad {
    self.title = @"Search";
    _sc = [[UISearchController alloc] initWithSearchResultsController:nil];
    _sc.searchResultsUpdater = self;
    _sc.obscuresBackgroundDuringPresentation = NO;
    _sc.searchBar.placeholder = @"Tweaks, apps, package IDs";
    self.navigationItem.searchController = _sc;
    self.navigationItem.hidesSearchBarWhenScrolling = NO;
    self.definesPresentationContext = YES;
    [super viewDidLoad];
}
- (void)updateSearchResultsForSearchController:(UISearchController *)sc { [self reload]; }
- (void)reload {
    NSString *q = [_sc.searchBar.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    NSArray *all = [CBStore shared].items;
    if (q.length) {
        all = [all filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(CBItem *i, id b) {
            for (NSString *f in @[i.name ?: @"", i.desc ?: @"", i.pid ?: @"", i.section ?: @""])
                if ([f rangeOfString:q options:NSCaseInsensitiveSearch | NSDiacriticInsensitiveSearch].location != NSNotFound) return YES;
            return NO;
        }]];
        all = [all sortedArrayUsingComparator:^NSComparisonResult(CBItem *a, CBItem *b) { return [a.name localizedCaseInsensitiveCompare:b.name]; }];
        self.sections = all.count ? @[@{@"title": [NSString stringWithFormat:@"%lu results", (unsigned long)all.count], @"items": all}]
                                  : @[@{@"title": @"No results", @"items": @[]}];
    } else {
        all = [all sortedArrayUsingComparator:^NSComparisonResult(CBItem *a, CBItem *b) { return [a.name localizedCaseInsensitiveCompare:b.name]; }];
        self.sections = @[@{@"title": @"Everything on Cobalt", @"items": all}];
    }
    [super reload];
}
@end

#pragma mark Updates

@interface CBUpdatesVC : CBListVC
@end
@implementation CBUpdatesVC
- (void)viewDidLoad {
    self.title = @"Updates";
    [super viewDidLoad];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"Mark Seen" style:UIBarButtonItemStylePlain
                                                                             target:self action:@selector(markSeen)];
}
- (void)markSeen { [[CBStore shared] markAllSeen]; }
- (void)reload {
    CBStore *st = [CBStore shared];
    NSMutableArray *secs = [NSMutableArray new];
    NSArray *mine = st.trackedUpdates, *fresh = st.newItems, *changed = st.updatedItems;
    if (mine.count) [secs addObject:@{@"title": @"Updates for your stuff", @"items": mine}];
    if (fresh.count) [secs addObject:@{@"title": @"New on Cobalt", @"items": fresh}];
    if (changed.count) [secs addObject:@{@"title": @"Updated since your last visit", @"items": changed,
                                         @"footer": @"Tap GET → \"I already have this installed\" on anything you use, and it moves to the top when it updates."}];
    NSMutableArray *tracked = [NSMutableArray new];
    for (CBItem *i in st.items) if ([st trackedVersion:i] && ![mine containsObject:i]) [tracked addObject:i];
    if (tracked.count) [secs addObject:@{@"title": @"Up to date", @"items": tracked}];
    self.sections = secs;
    self.navigationItem.rightBarButtonItem.enabled = fresh.count || changed.count;
    if (!secs.count) {
        UILabel *l = [UILabel new];
        l.numberOfLines = 0;
        l.textAlignment = NSTextAlignmentCenter;
        l.textColor = UIColor.secondaryLabelColor;
        l.text = @"You're all caught up.\n\nInstall something through Cobalt (or tap GET → \"I already have this installed\") and it'll show up here when it gets an update.";
        UIView *bg = [UIView new];
        l.translatesAutoresizingMaskIntoConstraints = NO;
        [bg addSubview:l];
        [NSLayoutConstraint activateConstraints:@[
            [l.centerYAnchor constraintEqualToAnchor:bg.centerYAnchor],
            [l.leadingAnchor constraintEqualToAnchor:bg.leadingAnchor constant:40],
            [l.trailingAnchor constraintEqualToAnchor:bg.trailingAnchor constant:-40],
        ]];
        self.tableView.backgroundView = bg;
    } else self.tableView.backgroundView = nil;
    NSInteger badge = st.badgeCount;
    self.navigationController.tabBarItem.badgeValue = badge ? [NSString stringWithFormat:@"%ld", (long)badge] : nil;
    [super reload];
}
@end

#pragma mark Settings

@interface CBSettingsVC : UITableViewController
@end
@implementation CBSettingsVC
- (instancetype)init {
    if ((self = [super initWithStyle:UITableViewStyleInsetGrouped])) self.title = @"Settings";
    return self;
}
- (void)viewDidLoad {
    [super viewDidLoad];
    self.navigationController.navigationBar.prefersLargeTitles = YES;
    [NSNotificationCenter.defaultCenter addObserver:self.tableView selector:@selector(reloadData) name:CBStoreDidChange object:nil];
}
- (void)dealloc { [NSNotificationCenter.defaultCenter removeObserver:self.tableView]; }
- (NSArray *)rows:(NSInteger)s {
    switch (s) {
        case 0: return @[@"Source URL", @"Reset to Cobalt"];
        case 1: return @[@"Add to Sileo", @"Add to Zebra", @"Add to Cydia", @"Open Storefront"];
        case 2: return @[@"Refresh Now", @"Check for Cobalt Update"];
        case 3: return @[@"Clear Image Cache", @"Stop Tracking Everything"];
        default: return @[];
    }
}
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv { return 4; }
- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s { return [self rows:s].count; }
- (NSString *)tableView:(UITableView *)tv titleForHeaderInSection:(NSInteger)s {
    return @[@"Source", @"Package Managers", @"Cobalt", @"Storage"][s];
}
- (NSString *)tableView:(UITableView *)tv titleForFooterInSection:(NSInteger)s {
    CBStore *st = [CBStore shared];
    if (s == 0) return @"Point the app at any APT source. Cobalt is the default.";
    if (s == 1) return @"Tweaks install through your package manager, so add Cobalt there once.";
    if (s == 2) {
        NSString *v = NSBundle.mainBundle.infoDictionary[@"CFBundleShortVersionString"];
        NSString *when = st.lastRefresh ? [NSDateFormatter localizedStringFromDate:st.lastRefresh dateStyle:NSDateFormatterNoStyle timeStyle:NSDateFormatterShortStyle] : @"not yet this launch";
        return [NSString stringWithFormat:@"Cobalt %@ · %lu packages · last refreshed %@\nMade by MYM Culture.", v, (unsigned long)st.items.count, when];
    }
    return nil;
}
- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:nil];
    NSString *t = [self rows:ip.section][ip.row];
    c.textLabel.text = t;
    c.textLabel.textColor = TINT;
    if (ip.section == 0 && ip.row == 0) {
        c.textLabel.textColor = UIColor.labelColor;
        c.detailTextLabel.text = [[[CBStore shared].base stringByReplacingOccurrencesOfString:@"https://" withString:@""] stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"/"]];
        c.detailTextLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;
        c.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    }
    if (ip.section == 3 && ip.row == 1) c.textLabel.textColor = UIColor.systemRedColor;
    return c;
}
- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    CBStore *st = [CBStore shared];
    NSString *src = st.base;
    NSInteger s = ip.section, r = ip.row;
    if (s == 0 && r == 0) {
        UIAlertController *a = [UIAlertController alertControllerWithTitle:@"Source URL" message:nil preferredStyle:UIAlertControllerStyleAlert];
        [a addTextFieldWithConfigurationHandler:^(UITextField *f) {
            f.text = src;
            f.keyboardType = UIKeyboardTypeURL;
            f.autocapitalizationType = UITextAutocapitalizationTypeNone;
            f.autocorrectionType = UITextAutocorrectionTypeNo;
            f.clearButtonMode = UITextFieldViewModeWhileEditing;
        }];
        [a addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
        [a addAction:[UIAlertAction actionWithTitle:@"Save" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
            [st setSource:a.textFields.firstObject.text];
            [st refresh:^(NSString *err) { if (err) CBAlert(self, @"Couldn't load that source", err); }];
        }]];
        [self presentViewController:a animated:YES completion:nil];
    } else if (s == 0 && r == 1) {
        [st setSource:kDefaultSource];
        [st refresh:nil];
    } else if (s == 1) {
        NSArray *urls = @[[@"sileo://source/" stringByAppendingString:src],
                          [@"zbra://sources/add/" stringByAppendingString:src],
                          [@"cydia://url/https://cydia.saurik.com/api/share#?source=" stringByAppendingString:src],
                          src];
        CBOpen(self, urls[r], r < 3 ? @[@"Sileo", @"Zebra", @"Cydia"][r] : nil, nil);
    } else if (s == 2 && r == 0) {
        [st refresh:^(NSString *err) { CBAlert(self, err ? @"Couldn't refresh" : @"Up to date", err ?: [NSString stringWithFormat:@"%lu packages loaded.", (unsigned long)st.items.count]); }];
    } else if (s == 2 && r == 1) {
        [st refresh:^(NSString *err) {
            if (err) { CBAlert(self, @"Couldn't check", err); return; }
            if (!st.selfUpdateAvailable) {
                CBAlert(self, @"You're on the latest Cobalt", [NSString stringWithFormat:@"Version %@", NSBundle.mainBundle.infoDictionary[@"CFBundleShortVersionString"]]);
                return;
            }
            CBDownload(self, [st abs:st.selfUpdate[@"url"]], [tv cellForRowAtIndexPath:ip], nil);
        }];
    } else if (s == 3 && r == 0) {
        [CBImages clear];
        CBAlert(self, @"Cleared", @"Icons and banners will download again.");
    } else if (s == 3 && r == 1) {
        [st untrackAll];
    }
}
@end

#pragma mark - App

@interface CBAppDelegate : UIResponder <UIApplicationDelegate>
@property (nonatomic, strong) UIWindow *window;
@end
@implementation CBAppDelegate
- (UINavigationController *)nav:(UIViewController *)vc title:(NSString *)t icon:(NSString *)icon {
    UINavigationController *n = [[UINavigationController alloc] initWithRootViewController:vc];
    n.navigationBar.prefersLargeTitles = YES;
    n.tabBarItem = [[UITabBarItem alloc] initWithTitle:t image:[UIImage systemImageNamed:icon] tag:0];
    return n;
}
- (BOOL)application:(UIApplication *)app didFinishLaunchingWithOptions:(NSDictionary *)opts {
    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    self.window.tintColor = TINT;
    UITabBarController *tabs = [UITabBarController new];
    CBUpdatesVC *updates = [CBUpdatesVC new];
    tabs.viewControllers = @[
        [self nav:[CBHomeVC new] title:@"Cobalt" icon:@"cube.fill"],
        [self nav:[CBSearchVC new] title:@"Search" icon:@"magnifyingglass"],
        [self nav:updates title:@"Updates" icon:@"arrow.down.circle.fill"],
        [self nav:[CBSettingsVC new] title:@"Settings" icon:@"gear"],
    ];
    self.window.rootViewController = tabs;
    [self.window makeKeyAndVisible];
    [updates loadViewIfNeeded]; // so the badge shows right away
    [[CBStore shared] refresh:nil];
    return YES;
}
- (void)applicationWillEnterForeground:(UIApplication *)app {
    CBStore *st = [CBStore shared];
    if (!st.lastRefresh || -[st.lastRefresh timeIntervalSinceNow] > 300) [st refresh:nil];
}
@end

int main(int argc, char *argv[]) {
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass(CBAppDelegate.class));
    }
}
