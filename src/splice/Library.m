// Splice shared library + admin publishing. See Library.h.
#import "Library.h"
#import "Engine.h"
#import <CommonCrypto/CommonCrypto.h>
#import <Security/Security.h>
#import "TokenBlob.h"

static NSString *const kOwner = @"benjaminsoble91-eng";
static NSString *const kRepo = @"cobalt";
static NSString *const kTag = @"splice-library";
static NSString *const kCatalogPath = @"splice/catalog.json";
static NSString *const kTokenService = @"com.mymculture.splice.github";

static NSError *LibErr(NSString *msg) {
    return [NSError errorWithDomain:@"Splice" code:2 userInfo:@{NSLocalizedDescriptionKey: msg}];
}

#pragma mark - Model

@implementation SPSharedApp
+ (instancetype)fromDict:(NSDictionary *)d {
    if (![d isKindOfClass:NSDictionary.class] || ![d[@"url"] isKindOfClass:NSString.class]) return nil;
    SPSharedApp *a = [SPSharedApp new];
    a.entryID = d[@"id"] ?: @"";
    a.name = d[@"name"] ?: @"App";
    a.bundleID = d[@"bundleID"] ?: @"";
    a.version = d[@"version"] ?: @"";
    a.size = [d[@"size"] longLongValue];
    a.url = d[@"url"];
    a.iconURL = [d[@"icon"] isKindOfClass:NSString.class] ? d[@"icon"] : nil;
    a.assetID = [d[@"assetID"] longLongValue];
    a.iconAssetID = [d[@"iconAssetID"] longLongValue];
    a.added = d[@"added"];
    a.fileName = [d[@"file"] isKindOfClass:NSString.class] ? d[@"file"] : nil;
    a.packageID = [d[@"package"] isKindOfClass:NSString.class] ? d[@"package"] : nil;
    return a;
}
- (NSDictionary *)dict {
    NSMutableDictionary *d = [@{@"id": self.entryID, @"name": self.name, @"bundleID": self.bundleID, @"version": self.version,
                                @"size": @(self.size), @"url": self.url, @"assetID": @(self.assetID)} mutableCopy];
    if (self.iconURL) { d[@"icon"] = self.iconURL; d[@"iconAssetID"] = @(self.iconAssetID); }
    if (self.added) d[@"added"] = self.added;
    if (self.fileName) d[@"file"] = self.fileName;
    if (self.packageID) d[@"package"] = self.packageID;
    return d;
}
@end

static NSArray<SPSharedApp *> *ParseList(NSDictionary *j, NSString *key, BOOL tweaks) {
    NSMutableArray *out = [NSMutableArray array];
    for (NSDictionary *d in [j[key] isKindOfClass:NSArray.class] ? j[key] : @[]) {
        SPSharedApp *a = [SPSharedApp fromDict:d];
        if (!a) continue;
        a.isTweak = tweaks;
        [out addObject:a];
    }
    return out;
}

static NSDictionary *ParseCatalog(NSData *data) {
    NSDictionary *j = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    if (![j isKindOfClass:NSDictionary.class]) return nil;
    return @{@"apps": ParseList(j, @"apps", NO), @"tweaks": ParseList(j, @"tweaks", YES)};
}

#pragma mark - Transfers with progress

@interface SPNet : NSObject <NSURLSessionDataDelegate, NSURLSessionDownloadDelegate>
@property (nonatomic, strong) NSURLSession *session;
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, NSMutableDictionary *> *tasks;
@end

@implementation SPNet
+ (instancetype)shared {
    static SPNet *n;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        n = [SPNet new];
        n.tasks = [NSMutableDictionary dictionary];
        NSURLSessionConfiguration *c = NSURLSessionConfiguration.defaultSessionConfiguration;
        c.timeoutIntervalForRequest = 120;
        c.timeoutIntervalForResource = 60 * 60 * 3;
        NSOperationQueue *q = [NSOperationQueue new];
        q.maxConcurrentOperationCount = 1;
        n.session = [NSURLSession sessionWithConfiguration:c delegate:n delegateQueue:q];
    });
    return n;
}
- (NSMutableDictionary *)infoFor:(NSURLSessionTask *)t {
    @synchronized (self.tasks) { return self.tasks[@(t.taskIdentifier)]; }
}
- (void)track:(NSURLSessionTask *)t info:(NSMutableDictionary *)info {
    @synchronized (self.tasks) { self.tasks[@(t.taskIdentifier)] = info; }
    [t resume];
}
- (void)download:(NSURL *)url to:(NSString *)dest progress:(SPProgressBlock)p done:(void (^)(NSError *))done {
    NSURLSessionDownloadTask *t = [self.session downloadTaskWithURL:url];
    [self track:t info:[@{@"p": p, @"done": done, @"dest": dest} mutableCopy]];
}
- (void)upload:(NSURLRequest *)req file:(NSString *)path progress:(SPProgressBlock)p
          done:(void (^)(NSData *, NSHTTPURLResponse *, NSError *))done {
    NSURLSessionUploadTask *t = [self.session uploadTaskWithRequest:req fromFile:[NSURL fileURLWithPath:path]];
    [self track:t info:[@{@"p": p, @"done": done, @"data": [NSMutableData data]} mutableCopy]];
}
- (void)URLSession:(NSURLSession *)s downloadTask:(NSURLSessionDownloadTask *)t didWriteData:(int64_t)w
 totalBytesWritten:(int64_t)total totalBytesExpectedToWrite:(int64_t)expected {
    SPProgressBlock p = [self infoFor:t][@"p"];
    if (p && expected > 0) p((double)total / (double)expected);
}
- (void)URLSession:(NSURLSession *)s downloadTask:(NSURLSessionDownloadTask *)t didFinishDownloadingToURL:(NSURL *)loc {
    NSMutableDictionary *info = [self infoFor:t];
    NSInteger code = [(NSHTTPURLResponse *)t.response statusCode];
    if (code >= 400) { info[@"err"] = LibErr([NSString stringWithFormat:@"The download failed (HTTP %ld).", (long)code]); return; }
    NSString *dest = info[@"dest"];
    [NSFileManager.defaultManager removeItemAtPath:dest error:nil];
    NSError *e = nil;
    if (![NSFileManager.defaultManager moveItemAtURL:loc toURL:[NSURL fileURLWithPath:dest] error:&e]) info[@"err"] = e;
}
- (void)URLSession:(NSURLSession *)s task:(NSURLSessionTask *)t didSendBodyData:(int64_t)sent
    totalBytesSent:(int64_t)total totalBytesExpectedToSend:(int64_t)expected {
    SPProgressBlock p = [self infoFor:t][@"p"];
    if (p && expected > 0) p((double)total / (double)expected);
}
- (void)URLSession:(NSURLSession *)s dataTask:(NSURLSessionDataTask *)t didReceiveData:(NSData *)data {
    [[self infoFor:t][@"data"] appendData:data];
}
- (void)URLSession:(NSURLSession *)s task:(NSURLSessionTask *)t didCompleteWithError:(NSError *)error {
    NSMutableDictionary *info = [self infoFor:t];
    @synchronized (self.tasks) { [self.tasks removeObjectForKey:@(t.taskIdentifier)]; }
    if (!info) return;
    if ([t isKindOfClass:NSURLSessionDownloadTask.class]) {
        void (^done)(NSError *) = info[@"done"];
        done(error ?: info[@"err"]);
    } else {
        void (^done)(NSData *, NSHTTPURLResponse *, NSError *) = info[@"done"];
        done(info[@"data"], (NSHTTPURLResponse *)t.response, error);
    }
}
@end

#pragma mark - Public side

@implementation SPLibrary

+ (void)fetchCatalog:(void (^)(NSArray<SPSharedApp *> *, NSArray<SPSharedApp *> *, NSError *))done {
    NSString *bust = [NSString stringWithFormat:@"?t=%lld", (long long)NSDate.date.timeIntervalSince1970 / 60];
    NSArray *urls = @[
        [NSString stringWithFormat:@"https://%@.github.io/%@/%@%@", kOwner, kRepo, kCatalogPath, bust],
        [NSString stringWithFormat:@"https://raw.githubusercontent.com/%@/%@/main/%@%@", kOwner, kRepo, kCatalogPath, bust],
    ];
    __block void (^attempt)(NSUInteger);
    __block void (^strongAttempt)(NSUInteger);
    attempt = strongAttempt = ^(NSUInteger i) {
        NSMutableURLRequest *r = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:urls[i]]];
        r.cachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
        r.timeoutInterval = 20;
        [[NSURLSession.sharedSession dataTaskWithRequest:r completionHandler:^(NSData *d, NSURLResponse *resp, NSError *e) {
            NSDictionary *cat = [(NSHTTPURLResponse *)resp statusCode] == 200 ? ParseCatalog(d) : nil;
            if (!cat && i + 1 < urls.count) { strongAttempt(i + 1); return; }
            strongAttempt = nil;   // break the retain cycle
            dispatch_async(dispatch_get_main_queue(), ^{
                done(cat[@"apps"], cat[@"tweaks"], cat ? nil : (e ?: LibErr(@"Couldn't load the shared apps.")));
            });
        }] resume];
    };
    attempt(0);
}

+ (void)download:(SPSharedApp *)app progress:(SPProgressBlock)progress completion:(void (^)(NSString *, NSError *))done {
    NSString *dir = [SPWorkRoot() stringByAppendingPathComponent:[@"dl-" stringByAppendingString:NSUUID.UUID.UUIDString]];
    [NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *safe = [[app.name componentsSeparatedByCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"/\\:"]] componentsJoinedByString:@"-"];
    NSString *dest = [dir stringByAppendingPathComponent:[NSString stringWithFormat:@"%@ %@.ipa", safe, app.version]];
    if (app.isTweak) {
        NSString *ext = app.fileName.pathExtension.lowercaseString.length ? app.fileName.pathExtension.lowercaseString : @"deb";
        NSString *base = app.fileName.lastPathComponent.length ? app.fileName.lastPathComponent : [NSString stringWithFormat:@"%@ %@.%@", safe, app.version, ext];
        dest = [dir stringByAppendingPathComponent:base];
    }
    NSURL *url = [NSURL URLWithString:app.url];
    if (!url) { done(nil, LibErr(@"That shared app has a bad link.")); return; }
    [[SPNet shared] download:url to:dest progress:^(double f) {
        dispatch_async(dispatch_get_main_queue(), ^{ progress(f); });
    } done:^(NSError *e) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (e) [NSFileManager.defaultManager removeItemAtPath:dir error:nil];
            done(e ? nil : dest, e);
        });
    }];
}

+ (void)loadIcon:(NSString *)url into:(UIImageView *)view {
    static NSCache *cache;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ cache = [NSCache new]; });
    if (!url.length) return;
    UIImage *hit = [cache objectForKey:url];
    if (hit) { view.image = hit; return; }
    view.accessibilityIdentifier = url;
    __weak UIImageView *wv = view;
    [[NSURLSession.sharedSession dataTaskWithURL:[NSURL URLWithString:url] completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {
        UIImage *img = d ? [UIImage imageWithData:d] : nil;
        if (!img) return;
        [cache setObject:img forKey:url];
        dispatch_async(dispatch_get_main_queue(), ^{
            if ([wv.accessibilityIdentifier isEqualToString:url]) wv.image = img;
        });
    }] resume];
}

@end

#pragma mark - Admin side

// PBKDF2-SHA256 of the admin password (100k rounds) - the password itself isn't stored in the app.
static const uint8_t kSalt[16] = {0xf6,0xa2,0xc9,0x13,0xcb,0xcf,0x90,0x96,0x4a,0x8d,0xe9,0x23,0xb9,0xe7,0x10,0x24};
static const uint8_t kHash[32] = {0xab,0x49,0x31,0x2d,0x98,0x73,0xfc,0x2b,0x19,0xb7,0xb4,0xf8,0x54,0x8c,0x09,0x6f,
                                  0x5f,0xae,0x8c,0xfa,0x55,0x23,0x7d,0x37,0xf9,0x3d,0xc5,0x83,0x1e,0x9a,0xdb,0x05};

// Small secret store: keychain, with a 0600 file fallback for installs without keychain access
// (some jailbreak/TrollStore setups).
static NSString *StoreFile(NSString *account) {
    NSString *dir = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES).firstObject;
    dir = [dir stringByAppendingPathComponent:@"Splice"];
    [NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    return [dir stringByAppendingPathComponent:[account isEqualToString:@"admin"] ? @".github-token" : [@"." stringByAppendingString:account]];
}

static NSDictionary *KeychainQuery(NSString *account) {
    return @{(__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
             (__bridge id)kSecAttrService: kTokenService, (__bridge id)kSecAttrAccount: account};
}

static NSString *StoreGet(NSString *account) {
    NSMutableDictionary *q = [KeychainQuery(account) mutableCopy];
    q[(__bridge id)kSecReturnData] = @YES;
    q[(__bridge id)kSecMatchLimit] = (__bridge id)kSecMatchLimitOne;
    CFTypeRef res = NULL;
    if (SecItemCopyMatching((__bridge CFDictionaryRef)q, &res) == errSecSuccess && res) {
        NSString *t = [[NSString alloc] initWithData:(__bridge_transfer NSData *)res encoding:NSUTF8StringEncoding];
        if (t.length) return t;
    }
    NSString *f = [NSString stringWithContentsOfFile:StoreFile(account) encoding:NSUTF8StringEncoding error:nil];
    return f.length ? f : nil;
}

static void StoreSet(NSString *account, NSString *value) {
    SecItemDelete((__bridge CFDictionaryRef)KeychainQuery(account));
    [NSFileManager.defaultManager removeItemAtPath:StoreFile(account) error:nil];
    if (!value.length) return;
    NSMutableDictionary *q = [KeychainQuery(account) mutableCopy];
    q[(__bridge id)kSecValueData] = [value dataUsingEncoding:NSUTF8StringEncoding];
    q[(__bridge id)kSecAttrAccessible] = (__bridge id)kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly;
    if (SecItemAdd((__bridge CFDictionaryRef)q, NULL) != errSecSuccess) {
        [value writeToFile:StoreFile(account) atomically:YES encoding:NSUTF8StringEncoding error:nil];
        [NSFileManager.defaultManager setAttributes:@{NSFilePosixPermissions: @0600} ofItemAtPath:StoreFile(account) error:nil];
    }
}

// "unlocked" holds the decrypted built-in token once the admin has entered the password on this
// device ("-" if there's no built-in token), so the panel stays unlocked across launches until "Lock admin".
static NSString *const kUnlockedAccount = @"unlocked";

static NSString *gBuiltIn;   // decrypted for this session after the admin unlocks

static NSString *DecryptBuiltIn(NSString *pw) {
    NSData *p = [pw dataUsingEncoding:NSUTF8StringEncoding];
    uint8_t k[64];
    if (CCKeyDerivationPBKDF(kCCPBKDF2, p.bytes, p.length, kTokSalt, sizeof kTokSalt, kCCPRFHmacAlgSHA256, 200000, k, sizeof k) != kCCSuccess) return nil;
    // Verify before decrypting.
    NSMutableData *msg = [NSMutableData dataWithBytes:kTokIV length:sizeof kTokIV];
    [msg appendBytes:kTokCT length:sizeof kTokCT];
    uint8_t mac[32];
    CCHmac(kCCHmacAlgSHA256, k + 32, 32, msg.bytes, msg.length, mac);
    uint8_t diff = 0;
    for (int i = 0; i < 32; i++) diff |= mac[i] ^ kTokTag[i];
    if (diff) return nil;
    uint8_t out[sizeof kTokCT + kCCBlockSizeAES128];
    size_t n = 0;
    if (CCCrypt(kCCDecrypt, kCCAlgorithmAES, kCCOptionPKCS7Padding, k, 32, kTokIV, kTokCT, sizeof kTokCT, out, sizeof out, &n) != kCCSuccess) return nil;
    return [[NSString alloc] initWithBytes:out length:n encoding:NSUTF8StringEncoding];
}

@implementation SPAdmin

+ (BOOL)unlock:(NSString *)pw {
    if (![self checkPassword:pw]) return NO;
    if (!gBuiltIn) gBuiltIn = DecryptBuiltIn(pw);
    StoreSet(kUnlockedAccount, gBuiltIn.length ? gBuiltIn : @"-");   // remember this device is unlocked
    return YES;
}

+ (BOOL)isUnlocked {
    NSString *saved = StoreGet(kUnlockedAccount);
    if (saved.length && ![saved isEqualToString:@"-"] && !gBuiltIn) gBuiltIn = saved;
    return saved.length > 0;
}

+ (void)lock {
    StoreSet(kUnlockedAccount, nil);
    gBuiltIn = nil;
}

+ (NSString *)builtInToken { [self isUnlocked]; return gBuiltIn; }

+ (BOOL)usingBuiltInToken {
    [self isUnlocked];
    NSString *t = [self token];
    return t && gBuiltIn && [t isEqualToString:gBuiltIn];
}

+ (BOOL)checkPassword:(NSString *)pw {
    NSData *p = [pw dataUsingEncoding:NSUTF8StringEncoding];
    uint8_t out[32];
    if (CCKeyDerivationPBKDF(kCCPBKDF2, p.bytes, p.length, kSalt, sizeof kSalt, kCCPRFHmacAlgSHA256, 100000, out, sizeof out) != kCCSuccess) return NO;
    uint8_t diff = 0;
    for (size_t i = 0; i < sizeof out; i++) diff |= out[i] ^ kHash[i];
    return diff == 0;
}

+ (NSString *)token {
    [self isUnlocked];
    return StoreGet(@"admin") ?: gBuiltIn;   // a token you saved wins over the built-in one
}

+ (void)setToken:(NSString *)token {
    StoreSet(@"admin", token);
}

#pragma mark GitHub API (blocking)

static NSMutableURLRequest *GHRequest(NSString *method, NSString *url, NSString *token) {
    NSMutableURLRequest *r = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:url]];
    r.HTTPMethod = method;
    r.timeoutInterval = 60;
    [r setValue:[@"Bearer " stringByAppendingString:token] forHTTPHeaderField:@"Authorization"];
    [r setValue:@"application/vnd.github+json" forHTTPHeaderField:@"Accept"];
    [r setValue:@"2022-11-28" forHTTPHeaderField:@"X-GitHub-Api-Version"];
    [r setValue:@"Splice" forHTTPHeaderField:@"User-Agent"];
    return r;
}

static id GH(NSString *method, NSString *path, id body, NSString *token, NSInteger *status) {
    NSString *url = [path hasPrefix:@"https://"] ? path : [@"https://api.github.com" stringByAppendingString:path];
    NSMutableURLRequest *r = GHRequest(method, url, token);
    if (body) {
        r.HTTPBody = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil];
        [r setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    }
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    __block id json = nil;
    __block NSInteger code = 0;
    [[NSURLSession.sharedSession dataTaskWithRequest:r completionHandler:^(NSData *d, NSURLResponse *resp, NSError *e) {
        code = e ? -1 : [(NSHTTPURLResponse *)resp statusCode];
        if (d.length) json = [NSJSONSerialization JSONObjectWithData:d options:0 error:nil];
        dispatch_semaphore_signal(sem);
    }] resume];
    dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER);
    if (status) *status = code;
    return json;
}

static NSString *GHMessage(id json, NSInteger code) {
    NSString *m = [json isKindOfClass:NSDictionary.class] ? json[@"message"] : nil;
    if (code == -1) return @"No connection to GitHub.";
    if (code == 401) return @"GitHub rejected the token. Set a new one in the admin panel.";
    if (code == 403 || code == 404) return @"The token can't write to the Cobalt repo. It needs Contents: Read and write on benjaminsoble91-eng/cobalt.";
    return [NSString stringWithFormat:@"GitHub error %ld%@", (long)code, m ? [@": " stringByAppendingString:m] : @""];
}

+ (NSString *)validateToken:(NSString *)token {
    NSInteger code = 0;
    id repo = GH(@"GET", [NSString stringWithFormat:@"/repos/%@/%@", kOwner, kRepo], nil, token, &code);
    if (code != 200) return GHMessage(repo, code);
    if (![repo[@"permissions"][@"push"] boolValue]) return @"That token can read Cobalt but can't write to it. Give it Contents: Read and write.";
    return nil;
}

static NSDictionary *EnsureRelease(NSString *token, NSError **err) {
    NSInteger code = 0;
    id rel = GH(@"GET", [NSString stringWithFormat:@"/repos/%@/%@/releases/tags/%@", kOwner, kRepo, kTag], nil, token, &code);
    if (code == 200) return rel;
    if (code != 404) { if (err) *err = LibErr(GHMessage(rel, code)); return nil; }
    rel = GH(@"POST", [NSString stringWithFormat:@"/repos/%@/%@/releases", kOwner, kRepo],
             @{@"tag_name": kTag, @"target_commitish": @"main", @"name": @"Splice Library",
               @"body": @"Decrypted apps shared in Splice. Managed from Splice's admin panel - edit there, not here.",
               @"prerelease": @YES, @"make_latest": @"false"}, token, &code);
    if (code != 201) { if (err) *err = LibErr(GHMessage(rel, code)); return nil; }
    return rel;
}

static void DeleteAssetsNamed(NSDictionary *release, NSArray *names, NSString *token) {
    for (NSDictionary *a in [release[@"assets"] isKindOfClass:NSArray.class] ? release[@"assets"] : @[])
        if ([names containsObject:a[@"name"]])
            GH(@"DELETE", [NSString stringWithFormat:@"/repos/%@/%@/releases/assets/%@", kOwner, kRepo, a[@"id"]], nil, token, NULL);
}

static NSString *AssetName(NSString *s) {
    NSCharacterSet *ok = [NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-"];
    NSMutableString *out = [NSMutableString string];
    for (NSUInteger i = 0; i < s.length; i++) {
        unichar c = [s characterAtIndex:i];
        [out appendString:[ok characterIsMember:c] ? [NSString stringWithCharacters:&c length:1] : @"_"];
    }
    return out;
}

static NSDictionary *UploadAsset(NSDictionary *release, NSString *file, NSString *name, NSString *type, NSString *token,
                                 SPProgressBlock progress, NSError **err) {
    NSString *base = [release[@"upload_url"] componentsSeparatedByString:@"{"].firstObject;
    NSString *url = [NSString stringWithFormat:@"%@?name=%@", base, [name stringByAddingPercentEncodingWithAllowedCharacters:NSCharacterSet.URLQueryAllowedCharacterSet]];
    NSMutableURLRequest *r = GHRequest(@"POST", url, token);
    r.timeoutInterval = 300;
    [r setValue:type forHTTPHeaderField:@"Content-Type"];
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    __block NSDictionary *json = nil;
    __block NSInteger code = 0;
    [[SPNet shared] upload:r file:file progress:progress ?: ^(double f) {} done:^(NSData *d, NSHTTPURLResponse *resp, NSError *e) {
        code = e ? -1 : resp.statusCode;
        if (d.length) json = [NSJSONSerialization JSONObjectWithData:d options:0 error:nil];
        dispatch_semaphore_signal(sem);
    }];
    dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER);
    if (code != 201 || ![json isKindOfClass:NSDictionary.class]) {
        if (err) *err = LibErr([NSString stringWithFormat:@"Upload failed. %@", GHMessage(json, code)]);
        return nil;
    }
    return json;
}

// Read-modify-write catalog.json on main; retries if someone else changed it in between.
static BOOL EditCatalog(NSString *token, NSString *message, void (^edit)(NSMutableArray *apps, NSMutableArray *tweaks), NSError **err) {
    NSString *path = [NSString stringWithFormat:@"/repos/%@/%@/contents/%@", kOwner, kRepo, kCatalogPath];
    for (int attempt = 0; attempt < 3; attempt++) {
        NSInteger code = 0;
        id cur = GH(@"GET", [path stringByAppendingString:@"?ref=main"], nil, token, &code);
        NSString *sha = nil;
        NSMutableArray *apps = [NSMutableArray array], *tweaks = [NSMutableArray array];
        if (code == 200) {
            sha = cur[@"sha"];
            NSData *raw = [[NSData alloc] initWithBase64EncodedString:cur[@"content"] ?: @"" options:NSDataBase64DecodingIgnoreUnknownCharacters];
            NSDictionary *j = raw ? [NSJSONSerialization JSONObjectWithData:raw options:0 error:nil] : nil;
            if ([j isKindOfClass:NSDictionary.class] && [j[@"apps"] isKindOfClass:NSArray.class]) [apps addObjectsFromArray:j[@"apps"]];
            if ([j isKindOfClass:NSDictionary.class] && [j[@"tweaks"] isKindOfClass:NSArray.class]) [tweaks addObjectsFromArray:j[@"tweaks"]];
        } else if (code != 404) {
            if (err) *err = LibErr(GHMessage(cur, code));
            return NO;
        }
        edit(apps, tweaks);
        NSData *out = [NSJSONSerialization dataWithJSONObject:@{@"version": @1, @"apps": apps, @"tweaks": tweaks}
                                                      options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys error:nil];
        NSMutableDictionary *body = [@{@"message": message, @"branch": @"main",
                                       @"content": [out base64EncodedStringWithOptions:0]} mutableCopy];
        if (sha) body[@"sha"] = sha;
        id res = GH(@"PUT", path, body, token, &code);
        if (code == 200 || code == 201) return YES;
        if (code != 409 && code != 422) { if (err) *err = LibErr(GHMessage(res, code)); return NO; }
    }
    if (err) *err = LibErr(@"Couldn't update the shared list (it kept changing). Try again.");
    return NO;
}

+ (SPSharedApp *)publishIPA:(NSString *)path progress:(void (^)(NSString *, double))progress error:(NSError **)err {
    NSString *token = [self token];
    if (!token) { if (err) *err = LibErr(@"Set a GitHub token first."); return nil; }
    progress(@"Checking the app", -1);
    SPApp *app = [SPApp importIPA:path error:err];
    if (!app) return nil;
    if (app.encrypted) { if (err) *err = LibErr(@"That app is still encrypted. Only decrypted apps can be shared."); return nil; }

    progress(@"Preparing the library", -1);
    NSDictionary *rel = EnsureRelease(token, err);
    if (!rel) return nil;
    NSString *stem = AssetName([NSString stringWithFormat:@"%@_%@", app.bundleID, app.version]);
    NSString *ipaName = [stem stringByAppendingString:@".ipa"], *iconName = [stem stringByAppendingString:@".png"];
    DeleteAssetsNamed(rel, @[ipaName, iconName], token);

    progress(@"Uploading", 0);
    NSDictionary *ipa = UploadAsset(rel, path, ipaName, @"application/octet-stream", token, ^(double f) { progress(@"Uploading", f); }, err);
    if (!ipa) return nil;
    NSDictionary *icon = nil;
    NSData *png = app.icon ? UIImagePNGRepresentation(app.icon) : nil;
    if (png) {
        NSString *tmp = [SPWorkRoot() stringByAppendingPathComponent:iconName];
        [png writeToFile:tmp atomically:YES];
        icon = UploadAsset(rel, tmp, iconName, @"image/png", token, nil, nil);   // an icon is nice-to-have
        [NSFileManager.defaultManager removeItemAtPath:tmp error:nil];
    }

    SPSharedApp *entry = [SPSharedApp new];
    entry.entryID = [NSString stringWithFormat:@"%@-%@", app.bundleID, app.version];
    entry.name = app.name; entry.bundleID = app.bundleID; entry.version = app.version;
    entry.size = [ipa[@"size"] longLongValue];
    entry.url = ipa[@"browser_download_url"];
    entry.assetID = [ipa[@"id"] longLongValue];
    entry.iconURL = icon[@"browser_download_url"];
    entry.iconAssetID = [icon[@"id"] longLongValue];
    NSISO8601DateFormatter *df = [NSISO8601DateFormatter new];
    entry.added = [df stringFromDate:NSDate.date];

    progress(@"Publishing", -1);
    NSDictionary *d = entry.dict;
    BOOL ok = EditCatalog(token, [NSString stringWithFormat:@"Splice library: add %@ %@", app.name, app.version], ^(NSMutableArray *apps, NSMutableArray *tweaks) {
        [apps filterUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSDictionary *a, NSDictionary *b) {
            return ![a isKindOfClass:NSDictionary.class] || ![a[@"id"] isEqual:d[@"id"]];
        }]];
        [apps insertObject:d atIndex:0];
    }, err);
    return ok ? entry : nil;
}

+ (SPSharedApp *)publishTweak:(NSString *)path progress:(void (^)(NSString *, double))progress error:(NSError **)err {
    NSString *token = [self token];
    if (!token) { if (err) *err = LibErr(@"Set a GitHub token first."); return nil; }
    progress(@"Checking the tweak", -1);
    SPTweak *t = [SPTweak importFile:path error:err];   // same checks as adding it to a build
    if (!t) return nil;
    progress(@"Preparing the library", -1);
    NSDictionary *rel = EnsureRelease(token, err);
    if (!rel) return nil;
    NSString *ext = path.pathExtension.lowercaseString;
    NSString *ident = t.packageID.length ? t.packageID : t.name;
    NSString *stem = AssetName([NSString stringWithFormat:@"tweak_%@_%@", ident, t.version.length ? t.version : @"1"]);
    NSString *assetName = [stem stringByAppendingPathExtension:ext];
    DeleteAssetsNamed(rel, @[assetName], token);
    progress(@"Uploading", 0);
    NSDictionary *asset = UploadAsset(rel, path, assetName, @"application/octet-stream", token, ^(double f) { progress(@"Uploading", f); }, err);
    if (!asset) return nil;

    SPSharedApp *entry = [SPSharedApp new];
    entry.isTweak = YES;
    entry.entryID = [NSString stringWithFormat:@"%@-%@", ident, t.version];
    entry.name = t.name;
    entry.bundleID = @"";
    entry.version = t.version ?: @"";
    entry.packageID = t.packageID.length ? t.packageID : nil;
    entry.fileName = path.lastPathComponent;
    entry.size = [asset[@"size"] longLongValue];
    entry.url = asset[@"browser_download_url"];
    entry.assetID = [asset[@"id"] longLongValue];
    entry.added = [[NSISO8601DateFormatter new] stringFromDate:NSDate.date];

    progress(@"Publishing", -1);
    NSDictionary *d = entry.dict;
    BOOL ok = EditCatalog(token, [NSString stringWithFormat:@"Splice library: add tweak %@ %@", t.name, t.version], ^(NSMutableArray *apps, NSMutableArray *tweaks) {
        [tweaks filterUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSDictionary *a, NSDictionary *b) {
            return ![a isKindOfClass:NSDictionary.class] || ![a[@"id"] isEqual:d[@"id"]];
        }]];
        [tweaks insertObject:d atIndex:0];
    }, err);
    return ok ? entry : nil;
}

+ (BOOL)remove:(SPSharedApp *)app error:(NSError **)err {
    NSString *token = [self token];
    if (!token) { if (err) *err = LibErr(@"Set a GitHub token first."); return NO; }
    BOOL ok = EditCatalog(token, [NSString stringWithFormat:@"Splice library: remove %@ %@", app.name, app.version], ^(NSMutableArray *apps, NSMutableArray *tweaks) {
        [(app.isTweak ? tweaks : apps) filterUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSDictionary *a, NSDictionary *b) {
            return ![a isKindOfClass:NSDictionary.class] || ![a[@"id"] isEqual:app.entryID];
        }]];
    }, err);
    if (!ok) return NO;
    for (NSNumber *aid in @[@(app.assetID), @(app.iconAssetID)])
        if (aid.longLongValue)
            GH(@"DELETE", [NSString stringWithFormat:@"/repos/%@/%@/releases/assets/%@", kOwner, kRepo, aid], nil, token, NULL);
    return YES;
}

@end
