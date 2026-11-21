// TrollDuplicator Lite (com.mymculture.trollduplicatorlite)
// Duplicates installed apps using the jailbreak instead of TrollStore:
//   copy the .app -> give it a new bundle ID and name -> re-sign the main binary with the
//   jailbreak's ldid -> install it through installd, which AppSync Unified lets through.
// Copies are normal user apps: they get their own data and can be deleted from the Home Screen.
// JBROOT is "" on rootful jailbreaks and "/var/jb" on rootless ones (set by build.sh).

#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <spawn.h>
#import <sys/wait.h>
#import <mach-o/loader.h>
#import <mach-o/fat.h>
#import <zlib.h>

#ifndef JBROOT
#define JBROOT ""
#endif

static NSString *const kOriginalKey = @"TDLiteOriginal";
extern char **environ;

#pragma mark - Private API glue

@interface NSObject (TDLitePrivate)
+ (id)defaultWorkspace;
- (NSArray *)allInstalledApplications;
- (NSString *)applicationIdentifier;
- (NSString *)applicationType;
- (NSURL *)bundleURL;
- (NSString *)localizedName;
- (BOOL)openApplicationWithBundleID:(NSString *)bid;
@end

@interface UIImage (TDLitePrivate)
+ (UIImage *)_applicationIconImageForBundleIdentifier:(NSString *)bid format:(int)format scale:(CGFloat)scale;
@end

static id Workspace(void) {
    return [NSClassFromString(@"LSApplicationWorkspace") defaultWorkspace];
}

#pragma mark - Small helpers

static NSString *JBPath(NSString *path) {
    return [@JBROOT stringByAppendingString:path];
}

static NSString *FindTool(NSArray<NSString *> *names) {
    NSFileManager *fm = NSFileManager.defaultManager;
    for (NSString *name in names) {
        for (NSString *dir in @[@"/usr/bin", @"/usr/local/bin", @"/bin", @"/usr/sbin"]) {
            NSString *p = JBPath([dir stringByAppendingPathComponent:name]);
            if ([fm isExecutableFileAtPath:p]) return p;
        }
    }
    return nil;
}

// Runs a tool, returns its exit code; stdout goes to *outData when asked for.
static int RunTool(NSString *tool, NSArray<NSString *> *args, NSData **outData) {
    NSMutableArray *all = [NSMutableArray arrayWithObject:tool];
    [all addObjectsFromArray:args];
    char **argv = calloc(all.count + 1, sizeof(char *));
    for (NSUInteger i = 0; i < all.count; i++) argv[i] = strdup([all[i] UTF8String]);

    int fds[2];
    pipe(fds);
    posix_spawn_file_actions_t fa;
    posix_spawn_file_actions_init(&fa);
    posix_spawn_file_actions_adddup2(&fa, fds[1], STDOUT_FILENO);
    posix_spawn_file_actions_adddup2(&fa, fds[1], STDERR_FILENO);
    posix_spawn_file_actions_addclose(&fa, fds[0]);

    pid_t pid = 0;
    int rc = posix_spawn(&pid, argv[0], &fa, NULL, argv, environ);
    posix_spawn_file_actions_destroy(&fa);
    close(fds[1]);

    NSMutableData *buf = [NSMutableData data];
    char chunk[4096];
    ssize_t n;
    while ((n = read(fds[0], chunk, sizeof(chunk))) > 0) [buf appendBytes:chunk length:n];
    close(fds[0]);

    int status = -1;
    if (rc == 0) {
        waitpid(pid, &status, 0);
        status = WIFEXITED(status) ? WEXITSTATUS(status) : -1;
    }
    for (NSUInteger i = 0; i < all.count; i++) free(argv[i]);
    free(argv);
    if (outData) *outData = buf;
    return rc == 0 ? status : -1;
}

static NSDictionary *InfoForBundle(NSURL *bundleURL) {
    return [NSDictionary dictionaryWithContentsOfURL:[bundleURL URLByAppendingPathComponent:@"Info.plist"]];
}

// YES when the main binary is still FairPlay-encrypted (App Store apps that weren't decrypted).
static BOOL IsEncrypted(NSString *path) {
    NSData *d = [NSData dataWithContentsOfFile:path options:NSDataReadingMappedIfSafe error:nil];
    if (d.length < sizeof(struct mach_header_64)) return NO;
    const uint8_t *b = d.bytes;
    NSMutableArray *offsets = [NSMutableArray array];
    uint32_t magic = *(const uint32_t *)b;
    if (magic == FAT_CIGAM || magic == FAT_MAGIC) {
        uint32_t n = OSSwapBigToHostInt32(((const struct fat_header *)b)->nfat_arch);
        const struct fat_arch *archs = (const struct fat_arch *)(b + sizeof(struct fat_header));
        for (uint32_t i = 0; i < n && (const uint8_t *)&archs[i + 1] <= b + d.length; i++)
            [offsets addObject:@(OSSwapBigToHostInt32(archs[i].offset))];
    } else {
        [offsets addObject:@0];
    }
    for (NSNumber *o in offsets) {
        NSUInteger off = o.unsignedIntegerValue;
        if (off + sizeof(struct mach_header_64) > d.length) continue;
        const struct mach_header_64 *mh = (const void *)(b + off);
        if (mh->magic != MH_MAGIC_64) continue;
        NSUInteger p = off + sizeof(struct mach_header_64);
        for (uint32_t i = 0; i < mh->ncmds && p + sizeof(struct load_command) <= d.length; i++) {
            const struct load_command *lc = (const void *)(b + p);
            if (lc->cmd == LC_ENCRYPTION_INFO_64 && p + sizeof(struct encryption_info_command_64) <= d.length) {
                if (((const struct encryption_info_command_64 *)lc)->cryptid != 0) return YES;
            }
            if (lc->cmdsize == 0) break;
            p += lc->cmdsize;
        }
    }
    return NO;
}

#pragma mark - Minimal .ipa writer (stored, no compression) for the appinst fallback

static void PutLE16(NSMutableData *d, uint16_t v) { [d appendBytes:&v length:2]; }
static void PutLE32(NSMutableData *d, uint32_t v) { [d appendBytes:&v length:4]; }

static BOOL WriteStoredZip(NSString *rootDir, NSString *zipPath, NSError **err) {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSOutputStream *out = [NSOutputStream outputStreamToFileAtPath:zipPath append:NO];
    [out open];
    NSMutableData *central = [NSMutableData data];
    uint32_t offset = 0, count = 0;
    NSDirectoryEnumerator *en = [fm enumeratorAtPath:rootDir];
    for (NSString *rel in en) {
        NSString *full = [rootDir stringByAppendingPathComponent:rel];
        BOOL isDir = NO;
        [fm fileExistsAtPath:full isDirectory:&isDir];
        NSDictionary *attrs = [fm attributesOfItemAtPath:full error:nil];
        BOOL isLink = [attrs[NSFileType] isEqual:NSFileTypeSymbolicLink];
        NSString *name = isDir && !isLink ? [rel stringByAppendingString:@"/"] : rel;
        NSData *nameData = [name dataUsingEncoding:NSUTF8StringEncoding];
        NSData *body = nil;
        if (isLink) body = [[fm destinationOfSymbolicLinkAtPath:full error:nil] dataUsingEncoding:NSUTF8StringEncoding];
        else if (!isDir) body = [NSData dataWithContentsOfFile:full options:NSDataReadingMappedIfSafe error:nil];
        if (!body) body = [NSData data];
        if (body.length > UINT32_MAX - 1 || offset > UINT32_MAX - body.length - 1024) {
            if (err) *err = [NSError errorWithDomain:@"TDLite" code:1 userInfo:@{NSLocalizedDescriptionKey: @"The app is too big for the fallback installer (over 4 GB)."}];
            [out close];
            return NO;
        }
        uint32_t crc = (uint32_t)crc32(0, body.bytes, (uInt)body.length);
        uint32_t mode = isLink ? 0120755 : (isDir ? 040755 : ([fm isExecutableFileAtPath:full] ? 0100755 : 0100644));

        NSMutableData *lh = [NSMutableData data];
        PutLE32(lh, 0x04034b50); PutLE16(lh, 20); PutLE16(lh, 0x0800); PutLE16(lh, 0);
        PutLE16(lh, 0); PutLE16(lh, 0x21);
        PutLE32(lh, crc); PutLE32(lh, (uint32_t)body.length); PutLE32(lh, (uint32_t)body.length);
        PutLE16(lh, (uint16_t)nameData.length); PutLE16(lh, 0);
        [lh appendData:nameData];
        [out write:lh.bytes maxLength:lh.length];
        if (body.length) [out write:body.bytes maxLength:body.length];

        PutLE32(central, 0x02014b50); PutLE16(central, (3 << 8) | 20); PutLE16(central, 20);
        PutLE16(central, 0x0800); PutLE16(central, 0); PutLE16(central, 0); PutLE16(central, 0x21);
        PutLE32(central, crc); PutLE32(central, (uint32_t)body.length); PutLE32(central, (uint32_t)body.length);
        PutLE16(central, (uint16_t)nameData.length); PutLE16(central, 0); PutLE16(central, 0);
        PutLE16(central, 0); PutLE16(central, 0); PutLE32(central, mode << 16); PutLE32(central, offset);
        [central appendData:nameData];

        offset += (uint32_t)(lh.length + body.length);
        count++;
    }
    [out write:central.bytes maxLength:central.length];
    NSMutableData *end = [NSMutableData data];
    PutLE32(end, 0x06054b50); PutLE16(end, 0); PutLE16(end, 0);
    PutLE16(end, (uint16_t)MIN(count, 0xFFFF)); PutLE16(end, (uint16_t)MIN(count, 0xFFFF));
    PutLE32(end, (uint32_t)central.length); PutLE32(end, offset); PutLE16(end, 0);
    [out write:end.bytes maxLength:end.length];
    [out close];
    return YES;
}

#pragma mark - Duplicating

static NSError *TDError(NSString *msg) {
    return [NSError errorWithDomain:@"TDLite" code:1 userInfo:@{NSLocalizedDescriptionKey: msg}];
}

static BOOL BundleIDTaken(NSString *bid) {
    for (id app in [Workspace() allInstalledApplications])
        if ([[app applicationIdentifier] isEqualToString:bid]) return YES;
    return NO;
}

// Re-signs the copy's main binary with its own entitlements, moved over to the new bundle ID.
static BOOL ResignMainBinary(NSString *exe, NSString *oldID, NSString *newID, NSString *workDir, NSError **err) {
    NSString *ldid = FindTool(@[@"ldid"]);
    if (!ldid) { if (err) *err = TDError(@"ldid is missing. Install ldid in Sileo and try again."); return NO; }

    NSData *entsData = nil;
    RunTool(ldid, @[@"-e", exe], &entsData);
    NSMutableDictionary *ents = nil;
    if (entsData.length) {
        ents = [[NSPropertyListSerialization propertyListWithData:entsData options:NSPropertyListMutableContainersAndLeaves format:NULL error:nil] mutableCopy];
    }
    NSString *entsPath = [workDir stringByAppendingPathComponent:@"ents.plist"];
    NSArray *args;
    if ([ents isKindOfClass:NSDictionary.class] && ents.count) {
        NSString *appID = ents[@"application-identifier"];
        if ([appID isKindOfClass:NSString.class] && [appID hasSuffix:oldID]) {
            ents[@"application-identifier"] = [[appID substringToIndex:appID.length - oldID.length] stringByAppendingString:newID];
        }
        NSData *out = [NSPropertyListSerialization dataWithPropertyList:ents format:NSPropertyListXMLFormat_v1_0 options:0 error:nil];
        [out writeToFile:entsPath atomically:YES];
        args = @[[@"-S" stringByAppendingString:entsPath], exe];
    } else {
        args = @[@"-S", exe];
    }
    NSData *log = nil;
    if (RunTool(ldid, args, &log) != 0) {
        NSString *s = [[NSString alloc] initWithData:log encoding:NSUTF8StringEncoding] ?: @"";
        if (err) *err = TDError([@"ldid couldn't sign the copy. " stringByAppendingString:s]);
        return NO;
    }
    return YES;
}

static BOOL InstallBundle(NSString *appPath, NSString *workDir, NSError **err) {
    // 1. installd directly, as a developer-type install. AppSync Unified lets the fake signature through.
    id ws = Workspace();
    SEL sel = @selector(installApplication:withOptions:error:);
    NSError *installErr = nil;
    if ([ws respondsToSelector:sel]) {
        BOOL ok = ((BOOL (*)(id, SEL, NSURL *, NSDictionary *, NSError **))objc_msgSend)(
            ws, sel, [NSURL fileURLWithPath:appPath], @{@"PackageType": @"Developer"}, &installErr);
        if (ok) return YES;
    }
    // 2. Fallback: pack an .ipa and hand it to appinst (comes with AppSync Unified's appinst package).
    NSString *appinst = FindTool(@[@"appinst"]);
    if (appinst) {
        NSString *ipa = [workDir stringByAppendingPathComponent:@"copy.ipa"];
        if (WriteStoredZip([workDir stringByAppendingPathComponent:@"ipa"], ipa, err)) {
            NSData *log = nil;
            if (RunTool(appinst, @[ipa], &log) == 0) return YES;
            NSString *s = [[NSString alloc] initWithData:log encoding:NSUTF8StringEncoding] ?: @"";
            if (err) *err = TDError([@"appinst couldn't install the copy. " stringByAppendingString:s]);
            return NO;
        }
        return NO;
    }
    NSString *why = installErr.localizedDescription ?: @"installd refused it.";
    if (err) *err = TDError([NSString stringWithFormat:@"Installing the copy failed: %@ Make sure AppSync Unified is installed and the jailbreak is active.", why]);
    return NO;
}

static BOOL DuplicateApp(id proxy, NSString *newName, NSString **newIDOut, NSError **err) {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSURL *srcURL = [proxy bundleURL];
    NSString *oldID = [proxy applicationIdentifier];
    NSDictionary *srcInfo = InfoForBundle(srcURL);
    NSString *exeName = srcInfo[@"CFBundleExecutable"];
    if (!srcURL || !oldID || !exeName) { if (err) *err = TDError(@"Couldn't read this app's bundle."); return NO; }
    if (IsEncrypted([srcURL.path stringByAppendingPathComponent:exeName])) {
        if (err) *err = TDError(@"This App Store app is still encrypted. Decrypt it first (for example with a decrypter tweak), then duplicate the decrypted copy.");
        return NO;
    }

    // Pick a free bundle ID: <original>.copy, .copy2, .copy3 ...
    NSString *base = [srcInfo[kOriginalKey] isKindOfClass:NSString.class] ? srcInfo[kOriginalKey] : oldID;
    NSString *newID = [base stringByAppendingString:@".copy"];
    for (int n = 2; BundleIDTaken(newID); n++) newID = [NSString stringWithFormat:@"%@.copy%d", base, n];

    NSString *workDir = [@"/var/tmp/tdlite" stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    NSString *payload = [workDir stringByAppendingPathComponent:@"ipa/Payload"];
    [fm createDirectoryAtPath:payload withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *dst = [payload stringByAppendingPathComponent:srcURL.lastPathComponent];
    BOOL ok = NO;
    @try {
        NSError *copyErr = nil;
        if (![fm copyItemAtPath:srcURL.path toPath:dst error:&copyErr]) {
            if (err) *err = TDError([@"Couldn't copy the app: " stringByAppendingString:copyErr.localizedDescription]);
            return NO;
        }
        // Extensions, watch apps and app clips carry their own bundle IDs and would clash with the original's.
        for (NSString *sub in @[@"PlugIns", @"Extensions", @"Watch", @"AppClips", @"SC_Info"])
            [fm removeItemAtPath:[dst stringByAppendingPathComponent:sub] error:nil];
        [fm removeItemAtPath:[dst stringByAppendingPathComponent:@"embedded.mobileprovision"] error:nil];

        NSMutableDictionary *info = [srcInfo mutableCopy];
        info[@"CFBundleIdentifier"] = newID;
        info[@"CFBundleDisplayName"] = newName;
        info[@"CFBundleName"] = newName;
        info[kOriginalKey] = base;
        [info removeObjectForKey:@"WKCompanionAppBundleIdentifier"];
        NSData *plist = [NSPropertyListSerialization dataWithPropertyList:info format:NSPropertyListBinaryFormat_v1_0 options:0 error:nil];
        [plist writeToFile:[dst stringByAppendingPathComponent:@"Info.plist"] atomically:YES];

        if (!ResignMainBinary([dst stringByAppendingPathComponent:exeName], oldID, newID, workDir, err)) return NO;
        if (!InstallBundle(dst, workDir, err)) return NO;
        if (newIDOut) *newIDOut = newID;
        ok = YES;
    } @finally {
        [fm removeItemAtPath:workDir error:nil];
    }
    return ok;
}

static BOOL RemoveCopy(NSString *bid, NSError **err) {
    id ws = Workspace();
    SEL sel = @selector(uninstallApplication:withOptions:);
    if (![ws respondsToSelector:sel]) { if (err) *err = TDError(@"This iOS version can't remove apps this way. Delete the copy from the Home Screen instead."); return NO; }
    BOOL ok = ((BOOL (*)(id, SEL, NSString *, NSDictionary *))objc_msgSend)(ws, sel, bid, nil);
    if (!ok && err) *err = TDError(@"iOS refused to remove the copy. Delete it from the Home Screen instead.");
    return ok;
}

#pragma mark - UI

@interface TDLiteListController : UITableViewController
@property (nonatomic, strong) NSArray *apps;
@property (nonatomic, strong) NSArray *copies;
@end

@implementation TDLiteListController

- (instancetype)init {
    if ((self = [super initWithStyle:UITableViewStyleGrouped])) self.title = @"TrollDuplicator Lite";
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.refreshControl = [UIRefreshControl new];
    [self.refreshControl addTarget:self action:@selector(reload) forControlEvents:UIControlEventValueChanged];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"About" style:UIBarButtonItemStylePlain target:self action:@selector(about)];
    [self reload];
}

- (void)reload {
    NSMutableArray *apps = [NSMutableArray array], *copies = [NSMutableArray array];
    NSString *me = NSBundle.mainBundle.bundleIdentifier;
    for (id app in [Workspace() allInstalledApplications]) {
        if (![[app applicationType] isEqualToString:@"User"]) continue;
        if ([[app applicationIdentifier] isEqualToString:me]) continue;
        if (InfoForBundle([app bundleURL])[kOriginalKey]) [copies addObject:app];
        else [apps addObject:app];
    }
    NSComparator byName = ^NSComparisonResult(id a, id b) {
        return [[a localizedName] ?: @"" localizedCaseInsensitiveCompare:[b localizedName] ?: @""];
    };
    self.apps = [apps sortedArrayUsingComparator:byName];
    self.copies = [copies sortedArrayUsingComparator:byName];
    [self.tableView reloadData];
    [self.refreshControl endRefreshing];
}

- (void)about {
    [self alert:@"TrollDuplicator Lite"
        message:@"Makes copies of your apps using the jailbreak instead of TrollStore. Copies are normal apps with their own data.\n\nNeeds AppSync Unified and ldid. App Store apps must be decrypted first. Extensions and widgets aren't copied."];
}

- (void)alert:(NSString *)title message:(NSString *)msg {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:title message:msg preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:a animated:YES completion:nil];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv { return 2; }
- (NSArray *)itemsIn:(NSInteger)s { return s == 0 ? self.copies : self.apps; }
- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s { return MAX((NSInteger)[self itemsIn:s].count, 1); }
- (NSString *)tableView:(UITableView *)tv titleForHeaderInSection:(NSInteger)s { return s == 0 ? @"Your copies" : @"Apps"; }
- (NSString *)tableView:(UITableView *)tv titleForFooterInSection:(NSInteger)s {
    return s == 1 ? @"Tap an app to make a copy. App Store apps must be decrypted first." : nil;
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *c = [tv dequeueReusableCellWithIdentifier:@"c"] ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"c"];
    NSArray *items = [self itemsIn:ip.section];
    if (!items.count) {
        c.textLabel.text = ip.section == 0 ? @"No copies yet" : @"No apps found";
        c.detailTextLabel.text = nil;
        c.imageView.image = nil;
        c.textLabel.textColor = UIColor.secondaryLabelColor;
        c.selectionStyle = UITableViewCellSelectionStyleNone;
        return c;
    }
    id app = items[ip.row];
    c.textLabel.text = [app localizedName];
    c.textLabel.textColor = UIColor.labelColor;
    c.detailTextLabel.text = [app applicationIdentifier];
    c.detailTextLabel.textColor = UIColor.secondaryLabelColor;
    c.selectionStyle = UITableViewCellSelectionStyleDefault;
    UIImage *icon = nil;
    if ([UIImage respondsToSelector:@selector(_applicationIconImageForBundleIdentifier:format:scale:)])
        icon = [UIImage _applicationIconImageForBundleIdentifier:[app applicationIdentifier] format:0 scale:UIScreen.mainScreen.scale];
    c.imageView.image = icon;
    return c;
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    NSArray *items = [self itemsIn:ip.section];
    if (!items.count) return;
    id app = items[ip.row];
    if (ip.section == 0) [self manageCopy:app at:ip];
    else [self askToDuplicate:app];
}

- (void)askToDuplicate:(id)app {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:[NSString stringWithFormat:@"Duplicate %@", [app localizedName]]
                                                               message:@"Name for the copy:"
                                                        preferredStyle:UIAlertControllerStyleAlert];
    [a addTextFieldWithConfigurationHandler:^(UITextField *f) {
        f.text = [NSString stringWithFormat:@"%@ 2", [app localizedName]];
        f.clearButtonMode = UITextFieldViewModeWhileEditing;
    }];
    [a addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [a addAction:[UIAlertAction actionWithTitle:@"Duplicate" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
        NSString *name = [a.textFields.firstObject.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        [self duplicate:app name:name.length ? name : [app localizedName]];
    }]];
    [self presentViewController:a animated:YES completion:nil];
}

- (void)duplicate:(id)app name:(NSString *)name {
    UIAlertController *busy = [UIAlertController alertControllerWithTitle:@"Duplicating…" message:@"This can take a minute for big apps." preferredStyle:UIAlertControllerStyleAlert];
    [self presentViewController:busy animated:YES completion:^{
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            NSError *err = nil;
            NSString *newID = nil;
            BOOL ok = DuplicateApp(app, name, &newID, &err);
            dispatch_async(dispatch_get_main_queue(), ^{
                [busy dismissViewControllerAnimated:YES completion:^{
                    [self reload];
                    if (ok) [self alert:@"Done" message:[NSString stringWithFormat:@"\"%@\" is on your Home Screen.", name]];
                    else [self alert:@"Couldn't duplicate" message:err.localizedDescription ?: @"Unknown error."];
                }];
            });
        });
    }];
}

- (void)manageCopy:(id)app at:(NSIndexPath *)ip {
    UIAlertController *s = [UIAlertController alertControllerWithTitle:[app localizedName] message:[app applicationIdentifier] preferredStyle:UIAlertControllerStyleActionSheet];
    [s addAction:[UIAlertAction actionWithTitle:@"Open" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
        [Workspace() openApplicationWithBundleID:[app applicationIdentifier]];
    }]];
    [s addAction:[UIAlertAction actionWithTitle:@"Delete Copy" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *x) {
        NSError *err = nil;
        if (RemoveCopy([app applicationIdentifier], &err)) [self reload];
        else [self alert:@"Couldn't delete" message:err.localizedDescription];
    }]];
    [s addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    UITableViewCell *cell = [self.tableView cellForRowAtIndexPath:ip];
    s.popoverPresentationController.sourceView = cell ?: self.view;
    s.popoverPresentationController.sourceRect = cell ? cell.bounds : self.view.bounds;
    [self presentViewController:s animated:YES completion:nil];
}

@end

@interface TDLiteAppDelegate : UIResponder <UIApplicationDelegate>
@property (nonatomic, strong) UIWindow *window;
@end

@implementation TDLiteAppDelegate
- (BOOL)application:(UIApplication *)app didFinishLaunchingWithOptions:(NSDictionary *)opts {
    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    self.window.rootViewController = [[UINavigationController alloc] initWithRootViewController:[TDLiteListController new]];
    [self.window makeKeyAndVisible];
    return YES;
}
@end

int main(int argc, char *argv[]) {
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass(TDLiteAppDelegate.class));
    }
}
