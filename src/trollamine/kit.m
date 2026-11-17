// TrollamineKit - loaded inside the Dopamine-based Trollamine app.
// Adds an "Apps" button on top of Dopamine's screen that opens a TrollStore-style panel:
// install an IPA, list installed apps, open or uninstall them. It drives TrollStore's real installer helper.
#import "tmcommon.h"
#import "machopatch.h"
#import "tmzip.h"
#import "tmsign.h"
#import "tdzip.h"
#import <objc/runtime.h>
#import <objc/message.h>

@interface LSApplicationWorkspace : NSObject
+ (instancetype)defaultWorkspace;
- (void)enumerateApplicationsOfType:(NSUInteger)type block:(void (^)(id proxy))block;
- (NSArray *)allInstalledApplications;
@end

#pragma mark - TrollStore menu (Apps + Settings tabs; exposes everything TrollStore's installer engine can do)

static BOOL sPanelOpen;

static NSString *TKTrollStorePath(void) { return TMBundlePath(@"com.opa334.TrollStore"); }

// Plain-language meaning of the installer engine's result codes.
static NSString *TKInstallError(int code) {
    switch (code) {
        case 166: return @"The file couldn't be unpacked. It may not be a valid IPA.";
        case 167: return @"No app was found inside the file.";
        case 168: return @"The app couldn't be unpacked by the engine.";
        case 170: return @"The system couldn't create a container for the app.";
        case 171: return @"An app with the same identifier is already installed and it isn't a TrollStore app.";
        case 172: return @"The app has no Info.plist.";
        case 173: return @"This app needs the signing tool (ldid), and it still isn't available after Trollamine tried to install it.";
        case 174: return @"The app's main program file is missing.";
        case 175: return @"Signing the app failed.";
        case 176: return @"The app has no bundle identifier.";
        case 177: return @"Couldn't mark the app as a TrollStore app.";
        case 178: return @"Copying the app into place failed.";
        case 179: return @"That app can't be installed this way (it's TrollStore itself or a protected system app).";
        case 180: return @"The app is still encrypted (an App Store copy). It needs to be decrypted first.";
        case 181: return @"The app was copied but couldn't be registered with the system.";
        case 183: return @"The app needs Developer Mode, and turning it on failed.";
        case 185: return @"Applying the signature bypass failed.";
        default: return [NSString stringWithFormat:@"The installer returned code %d.", code];
    }
}

// ---- ldid (the signing tool the installer engine uses, exactly as TrollStore does) ----
// The engine keeps ldid next to itself, so that is where we look for it.
static NSString *TKLdidDir(void) { return [TMHelperPath() stringByDeletingLastPathComponent]; }

static NSString *TKLdidVersion(void) {
    NSString *dir = TKLdidDir();
    if (!dir || ![[NSFileManager defaultManager] fileExistsAtPath:[dir stringByAppendingPathComponent:@"ldid"]]) return nil;
    NSString *v = [NSString stringWithContentsOfFile:[dir stringByAppendingPathComponent:@"ldid.version"] encoding:NSUTF8StringEncoding error:nil];
    v = [v stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    return v.length ? v : @"installed";
}

// Runs a program as the normal user and waits for it. Returns its exit code, or -1.
static int TKSpawnUser(NSString *path, NSArray<NSString *> *args) {
    NSMutableArray *all = [NSMutableArray arrayWithObject:path];
    [all addObjectsFromArray:args];
    char **argv = calloc(all.count + 1, sizeof(char *));
    if (!argv) return -1;
    for (NSUInteger i = 0; i < all.count; i++) argv[i] = strdup([all[i] UTF8String]);
    pid_t pid = 0;
    int rc = posix_spawn(&pid, argv[0], NULL, NULL, argv, environ);
    for (NSUInteger i = 0; i < all.count; i++) free(argv[i]);
    free(argv);
    if (rc != 0) return -1;
    int status = 0;
    while (waitpid(pid, &status, 0) < 0 && errno == EINTR) {}
    return WIFEXITED(status) ? WEXITSTATUS(status) : -1;
}

// Downloads a URL into memory. Uses the app's own connection first; if iOS refuses that,
// falls back to the command-line curl. Call off the main thread. Returns nil on failure.
static NSData *TKFetch(NSString *urlString, NSString **problem) {
    NSURL *url = [NSURL URLWithString:urlString];
    if (!url) { if (problem) *problem = @"Bad download address."; return nil; }
    __block NSData *result = nil;
    __block NSString *why = nil;
    NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration ephemeralSessionConfiguration];
    cfg.timeoutIntervalForRequest = 45;
    cfg.timeoutIntervalForResource = 300;
    NSURLSession *session = [NSURLSession sessionWithConfiguration:cfg];
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    [[session dataTaskWithURL:url completionHandler:^(NSData *data, NSURLResponse *resp, NSError *error) {
        NSInteger status = [resp isKindOfClass:[NSHTTPURLResponse class]] ? ((NSHTTPURLResponse *)resp).statusCode : 0;
        if (error) why = error.localizedDescription;
        else if (status >= 400) why = [NSString stringWithFormat:@"The server answered with error %ld.", (long)status];
        else result = data;
        dispatch_semaphore_signal(done);
    }] resume];
    dispatch_semaphore_wait(done, DISPATCH_TIME_FOREVER);
    [session finishTasksAndInvalidate];
    if (result.length) return result;

    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *curl = nil;
    for (NSString *c in @[@"/var/jb/usr/bin/curl", @"/usr/bin/curl", @"/usr/local/bin/curl"])
        if ([fm isExecutableFileAtPath:c]) { curl = c; break; }
    NSString *work = TMWorkDir();
    if (curl && work) {
        NSString *tmp = [work stringByAppendingPathComponent:[@"dl-" stringByAppendingString:[NSUUID UUID].UUIDString]];
        int code = TKSpawnUser(curl, @[@"-L", @"-f", @"-sS", @"--connect-timeout", @"30", @"--max-time", @"300", @"-o", tmp, urlString]);
        NSData *data = (code == 0) ? [NSData dataWithContentsOfFile:tmp] : nil;
        [fm removeItemAtPath:tmp error:nil];
        if (data.length) return data;
        why = [NSString stringWithFormat:@"%@ (curl also failed, code %d)", why ?: @"The download failed.", code];
    }
    if (problem) *problem = why ?: @"The download failed.";
    return nil;
}

// Downloads the latest ldid and installs it through the engine. Call off the main thread.
// Returns nil on success, or a message saying what went wrong.
static NSString *TKInstallLdidSync(NSString **installedVersion) {
    NSString *helper = TMHelperPath();
    if (!helper) return @"The installer engine is missing.";
    NSString *problem = nil;
    NSData *meta = TKFetch(@"https://api.github.com/repos/opa334/ldid/releases/latest", &problem);
    if (!meta) return problem;
    NSDictionary *json = [NSJSONSerialization JSONObjectWithData:meta options:0 error:nil];
    NSString *version = [json isKindOfClass:[NSDictionary class]] ? json[@"tag_name"] : nil;
    NSString *link = nil;
    if ([json isKindOfClass:[NSDictionary class]] && [json[@"assets"] isKindOfClass:[NSArray class]]) {
        for (NSDictionary *asset in json[@"assets"]) {
            if ([asset isKindOfClass:[NSDictionary class]] && [asset[@"name"] isEqual:@"ldid"]) link = asset[@"browser_download_url"];
        }
    }
    if (![version isKindOfClass:[NSString class]] || ![link isKindOfClass:[NSString class]]) return @"GitHub didn't return the release information.";
    NSData *bin = TKFetch(link, &problem);
    if (!bin) return problem;
    if (bin.length < 50000) return @"The ldid download was incomplete.";
    NSString *work = TMWorkDir();
    NSString *local = [work stringByAppendingPathComponent:@"ldid"];
    [[NSFileManager defaultManager] removeItemAtPath:local error:nil];
    if (!work || ![bin writeToFile:local atomically:YES]) return @"Couldn't save the download.";
    chmod(local.fileSystemRepresentation, 0755);
    NSString *log = nil;
    int code = TMSpawnRoot(helper, @[@"install-ldid", local, version], &log);
    [[NSFileManager defaultManager] removeItemAtPath:local error:nil];
    if (code != 0) return [NSString stringWithFormat:@"The installer returned code %d while installing ldid.", code];
    if (installedVersion) *installedVersion = version;
    return nil;
}

// Runs the installer engine with a spinner, then calls back on the main thread.
static void TKRun(UIViewController *vc, NSString *title, NSArray<NSString *> *args, void (^done)(int code, NSString *log)) {
    NSString *helper = TMHelperPath();
    if (!helper) { TMAlert(vc, @"Installer not found", @"TrollStore's installer helper is missing."); return; }
    UIAlertController *busy = [UIAlertController alertControllerWithTitle:title message:nil preferredStyle:UIAlertControllerStyleAlert];
    [vc presentViewController:busy animated:YES completion:nil];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *log = nil;
        int code = TMSpawnRoot(helper, args, &log);
        dispatch_async(dispatch_get_main_queue(), ^{
            [busy dismissViewControllerAnimated:YES completion:^{
                if (done) {
                    done(code, log);
                } else {
                    NSString *msg = code == 0 ? @"Done." : [NSString stringWithFormat:@"Failed (code %d).\n%@", code, log.length > 200 ? [log substringFromIndex:log.length - 200] : (log ?: @"")];
                    TMAlert(vc, code == 0 ? title : @"Error", msg);
                }
            }];
        });
    });
}

#pragma mark App details

@interface TKDetailController : UITableViewController
- (instancetype)initWithApp:(NSDictionary *)app;
@end

// ---- Trollamine theming for the menu's tables ----
#define TK_ACCENT [UIColor colorWithRed:0.42 green:0.95 blue:0.72 alpha:1.0]

static void TKThemeTable(UITableViewController *vc) {
    UIImageView *bg = [[UIImageView alloc] initWithImage:[UIImage imageNamed:@"Background_Trollamine.jpg"]];
    bg.contentMode = UIViewContentModeScaleAspectFill;
    vc.tableView.backgroundView = bg;
    vc.tableView.backgroundColor = [UIColor clearColor];
    vc.tableView.separatorColor = [UIColor colorWithWhite:1.0 alpha:0.12];
    vc.view.tintColor = TK_ACCENT;
    UINavigationBarAppearance *ap = [UINavigationBarAppearance new];
    [ap configureWithTransparentBackground];
    ap.backgroundEffect = [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemThinMaterialDark];
    ap.titleTextAttributes = @{NSForegroundColorAttributeName: UIColor.whiteColor};
    ap.largeTitleTextAttributes = @{NSForegroundColorAttributeName: UIColor.whiteColor};
    vc.navigationController.navigationBar.standardAppearance = ap;
    vc.navigationController.navigationBar.scrollEdgeAppearance = ap;
    vc.navigationController.navigationBar.tintColor = TK_ACCENT;
}

// Translucent cell look; leaves text color alone for rows tagged as actions (tag == 1).
static void TKThemeCell(UITableViewCell *cell) {
    cell.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.10];
    UIView *sel = [UIView new];
    sel.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.20];
    cell.selectedBackgroundView = sel;
    if (cell.tag != 1) cell.textLabel.textColor = [UIColor whiteColor];
    cell.detailTextLabel.textColor = [UIColor colorWithWhite:1.0 alpha:0.6];
}

static void TKThemeHeader(UIView *view, BOOL footer) {
    if (![view isKindOfClass:[UITableViewHeaderFooterView class]]) return;
    ((UITableViewHeaderFooterView *)view).textLabel.textColor = [UIColor colorWithWhite:1.0 alpha:footer ? 0.55 : 0.9];
}

@implementation TKDetailController {
    NSDictionary *_app;
    NSArray<NSArray<NSString *> *> *_info;
    NSArray<NSArray<NSString *> *> *_entitlements;
}

- (instancetype)initWithApp:(NSDictionary *)app {
    if ((self = [super initWithStyle:UITableViewStyleInsetGrouped])) _app = app;
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = _app[@"name"];
    self.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeNever;
    TKThemeTable(self);
    NSString *path = _app[@"path"];
    NSDictionary *plist = [NSDictionary dictionaryWithContentsOfFile:[path stringByAppendingPathComponent:@"Info.plist"]];
    Class proxyClass = NSClassFromString(@"LSApplicationProxy");
    id proxy = [proxyClass performSelector:NSSelectorFromString(@"applicationProxyForIdentifier:") withObject:_app[@"id"]];
    NSString *type = TMSafeValue(proxy, @"applicationType");
    NSMutableArray *info = [NSMutableArray array];
    [info addObject:@[@"Name", _app[@"name"] ?: @""]];
    [info addObject:@[@"Bundle ID", _app[@"id"] ?: @""]];
    [info addObject:@[@"Version", [NSString stringWithFormat:@"%@ (%@)", plist[@"CFBundleShortVersionString"] ?: @"?", plist[@"CFBundleVersion"] ?: @"?"]]];
    [info addObject:@[@"Registered as", [type isKindOfClass:[NSString class]] ? type : @"Unknown"]];
    if (plist[@"MinimumOSVersion"]) [info addObject:@[@"Minimum iOS", [plist[@"MinimumOSVersion"] description]]];
    [info addObject:@[@"Program", [plist[@"CFBundleExecutable"] description] ?: @"?"]];
    [info addObject:@[@"Location", path ?: @""]];
    _info = info;

    NSMutableArray *ents = [NSMutableArray array];
    NSString *exe = plist[@"CFBundleExecutable"];
    if ([exe isKindOfClass:[NSString class]]) {
        char *xml = tm_read_entitlements([path stringByAppendingPathComponent:exe].fileSystemRepresentation);
        if (xml) {
            id dict = [NSPropertyListSerialization propertyListWithData:[NSData dataWithBytes:xml length:strlen(xml)] options:0 format:NULL error:nil];
            free(xml);
            if ([dict isKindOfClass:[NSDictionary class]]) {
                for (NSString *key in [[dict allKeys] sortedArrayUsingSelector:@selector(compare:)]) {
                    id value = dict[key];
                    NSString *text;
                    if ([value isKindOfClass:[NSNumber class]] && CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID()) text = [value boolValue] ? @"Yes" : @"No";
                    else if ([value isKindOfClass:[NSArray class]]) text = [(NSArray *)value componentsJoinedByString:@", "];
                    else text = [value description];
                    [ents addObject:@[key, text ?: @""]];
                }
            }
        }
    }
    _entitlements = ents;
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 2; }
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return (NSInteger)(section == 0 ? _info.count : MAX((NSUInteger)1, _entitlements.count));
}
- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return section == 0 ? @"App" : [NSString stringWithFormat:@"Entitlements (%lu)", (unsigned long)_entitlements.count];
}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    cell.textLabel.numberOfLines = 0;
    cell.detailTextLabel.numberOfLines = 0;
    cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
    if (indexPath.section == 1 && _entitlements.count == 0) {
        cell.textLabel.text = @"None found";
        return cell;
    }
    NSArray<NSString *> *row = indexPath.section == 0 ? _info[(NSUInteger)indexPath.row] : _entitlements[(NSUInteger)indexPath.row];
    cell.textLabel.text = row[0];
    cell.textLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightMedium];
    cell.detailTextLabel.text = row[1];
    return cell;
}

- (void)tableView:(UITableView *)tableView willDisplayCell:(UITableViewCell *)cell forRowAtIndexPath:(NSIndexPath *)indexPath { TKThemeCell(cell); }
- (void)tableView:(UITableView *)tableView willDisplayHeaderView:(UIView *)view forSection:(NSInteger)section { TKThemeHeader(view, NO); }
- (void)tableView:(UITableView *)tableView willDisplayFooterView:(UIView *)view forSection:(NSInteger)section { TKThemeHeader(view, YES); }

@end

#pragma mark Apps tab

@interface TKAppsController : TMAppsController <UIDocumentPickerDelegate>
@end

@implementation TKAppsController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Apps";
    self.navigationController.navigationBar.prefersLargeTitles = YES;
    TKThemeTable(self);
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:self action:@selector(closeMenu)];
    UIAction *fileAction = [UIAction actionWithTitle:@"Install IPA File" image:[UIImage systemImageNamed:@"doc.badge.plus"] identifier:nil handler:^(__unused UIAction *a) { [self pickFile]; }];
    UIAction *urlAction = [UIAction actionWithTitle:@"Install from URL" image:[UIImage systemImageNamed:@"link.badge.plus"] identifier:nil handler:^(__unused UIAction *a) { [self askLink]; }];
    UIMenu *addMenu = [UIMenu menuWithTitle:@"" children:@[fileAction, urlAction]];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemAdd menu:addMenu];
}

- (void)closeMenu { [self.tabBarController dismissViewControllerAnimated:YES completion:^{ sPanelOpen = NO; }]; }

#pragma mark Installing

- (void)pickFile {
    // Use UTTypeItem (public.item) to let the user pick any file.
    // Filtering by specific UTTypes for .ipa/.tipa doesn't work reliably because:
    //  - .tipa is a TrollStore-specific extension with no system UTI declaration
    //  - .ipa is com.apple.itunes.ipa, but typeWithFilenameExtension: can return
    //    a dynamic type that doesn't match what the file provider reports
    //  - typeWithIdentifier: needs UTImportedTypeDeclarations in our Info.plist
    //    to resolve properly, and even then file providers may disagree
    // The delegate already validates .ipa/.tipa by extension after selection.
    UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[UTTypeItem] asCopy:YES];
    picker.delegate = self;
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    NSURL *url = urls.firstObject;
    if (!url) return;
    NSString *ext = url.pathExtension.lowercaseString;
    if (![ext isEqualToString:@"ipa"] && ![ext isEqualToString:@"tipa"]) { TMAlert(self, @"Not an app file", @"Pick a .ipa or .tipa file."); return; }
    // Copy into our work folder first so the installer (running as root) can always read it.
    NSString *work = TMWorkDir();
    if (!work) { TMAlert(self, @"Something went wrong", @"Couldn't find a folder to copy the file into."); return; }
    NSString *local = [work stringByAppendingPathComponent:url.lastPathComponent];
    BOOL scoped = [url startAccessingSecurityScopedResource];
    [[NSFileManager defaultManager] removeItemAtPath:local error:nil];
    NSError *err = nil;
    BOOL copied = [[NSFileManager defaultManager] copyItemAtPath:url.path toPath:local error:&err];
    if (scoped) [url stopAccessingSecurityScopedResource];
    if (!copied) { TMAlert(self, @"Couldn't read the file", err.localizedDescription ?: @""); return; }
    [self installLocalFile:local force:NO];
}

- (void)askLink {
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"Install from a link" message:@"Paste a direct link to a .ipa or .tipa file." preferredStyle:UIAlertControllerStyleAlert];
    [ac addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.placeholder = @"https://example.com/app.ipa";
        tf.keyboardType = UIKeyboardTypeURL;
        tf.autocapitalizationType = UITextAutocapitalizationTypeNone;
        tf.autocorrectionType = UITextAutocorrectionTypeNo;
        tf.clearButtonMode = UITextFieldViewModeWhileEditing;
    }];
    __weak UIAlertController *weak = ac;
    [ac addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [ac addAction:[UIAlertAction actionWithTitle:@"Download" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *a) {
        NSString *text = [weak.textFields.firstObject.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        NSURL *url = text.length ? [NSURL URLWithString:text] : nil;
        if (!url || !([url.scheme isEqualToString:@"https"] || [url.scheme isEqualToString:@"http"])) {
            TMAlert(self, @"That doesn't look like a link", @"It should start with https://");
            return;
        }
        [self downloadAndInstall:url];
    }]];
    [self presentViewController:ac animated:YES completion:nil];
}

- (void)downloadAndInstall:(NSURL *)url {
    UIAlertController *busy = [UIAlertController alertControllerWithTitle:@"Downloading..." message:url.host preferredStyle:UIAlertControllerStyleAlert];
    __block NSURLSessionDownloadTask *task = nil;
    [busy addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:^(__unused UIAlertAction *a) { [task cancel]; }]];
    [self presentViewController:busy animated:YES completion:nil];
    NSURLSessionConfiguration *config = [NSURLSessionConfiguration defaultSessionConfiguration];
    config.timeoutIntervalForRequest = 60;
    config.timeoutIntervalForResource = 600;
    NSURLSession *session = [NSURLSession sessionWithConfiguration:config];
    task = [session downloadTaskWithURL:url completionHandler:^(NSURL *location, NSURLResponse *response, NSError *error) {
        NSString *problem = nil;
        NSString *local = nil;
        if (error) {
            if (error.code == NSURLErrorCancelled) problem = @"";
            else problem = error.localizedDescription ?: @"The download failed.";
        } else if ([response isKindOfClass:[NSHTTPURLResponse class]] && ((NSHTTPURLResponse *)response).statusCode >= 400) {
            problem = [NSString stringWithFormat:@"The server answered with error %ld.", (long)((NSHTTPURLResponse *)response).statusCode];
        } else {
            NSString *name = response.suggestedFilename.length ? response.suggestedFilename : url.lastPathComponent;
            NSString *ext = name.pathExtension.lowercaseString;
            if (![ext isEqualToString:@"ipa"] && ![ext isEqualToString:@"tipa"]) name = [name stringByAppendingPathExtension:@"ipa"];
            name = [[name componentsSeparatedByCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"/:\\"]] componentsJoinedByString:@"-"];
            NSString *work = TMWorkDir();
            local = [work stringByAppendingPathComponent:name];
            [[NSFileManager defaultManager] removeItemAtPath:local error:nil];
            NSError *moveErr = nil;
            if (!work || ![[NSFileManager defaultManager] moveItemAtPath:location.path toPath:local error:&moveErr]) problem = moveErr.localizedDescription ?: @"Couldn't save the download.";
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            [busy dismissViewControllerAnimated:YES completion:^{
                if (problem) { if (problem.length) TMAlert(self, @"Download failed", problem); return; }
                [self installLocalFile:local force:NO];
            }];
        });
    }];
    [task resume];
}

// Installs a package the way TrollStore does: hand the file to the installer engine untouched first.
// The engine installs packages that are already signed for TrollStore (Dopamine's own .tipa, for
// example) as they are, and signs others itself if ldid is installed. Only when the engine says it
// can't sign the app (no ldid, or its signing failed) do we fall back to signing it ourselves with
// the bundled signer.
// Installs a package the way TrollStore does: hand the file to the installer engine as it is. The
// engine installs packages already signed for TrollStore untouched and signs the rest itself with
// the bundled ldid. Only if the engine reports it couldn't sign the app do we fall back to signing
// it ourselves with the bundled signer.
- (void)installLocalFile:(NSString *)local force:(BOOL)force {
    BOOL custom = [[NSUserDefaults standardUserDefaults] integerForKey:@"TMInstallMethod"] == 1;
    NSMutableArray *args = [NSMutableArray arrayWithObjects:@"install", custom ? @"custom" : @"installd", nil];
    if (force) [args addObject:@"force"];
    [args addObject:local];
    TKRun(self, @"Installing...", args, ^(int code, __unused NSString *log) {
        if (code == 173 || code == 175) { [self selfSignAndInstall:local force:force]; return; }
        if (code == 171 && !force) {
            UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"Already installed" message:@"An app with the same identifier is installed and it isn't a TrollStore app. Installing anyway replaces it, and its data may be lost." preferredStyle:UIAlertControllerStyleAlert];
            [ac addAction:[UIAlertAction actionWithTitle:@"Install Anyway" style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *a) { [self installLocalFile:local force:YES]; }]];
            [ac addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:^(__unused UIAlertAction *a) {
                [[NSFileManager defaultManager] removeItemAtPath:local error:nil];
            }]];
            [self presentViewController:ac animated:YES completion:nil];
            return;
        }
        [[NSFileManager defaultManager] removeItemAtPath:local error:nil];
        [self reload];
        if (code == 0) TMAlert(self, @"Installed", @"Look for the app on your home screen.");
        else if (code == 182) TMAlert(self, @"Installed, with a note", @"This app needs Developer Mode. Restart the phone and turn it on when asked, then the app will open.");
        else if (code == 184) TMAlert(self, @"Installed, with a note", @"Some parts of the app (such as extensions) are still encrypted, so those parts may not work.");
        else TMAlert(self, @"Install failed", TKInstallError(code));
    });
}

// Fallback: unpack the IPA, sign every binary with the bundled signer, mark the app as already
// signed so the engine needs no ldid, repackage, and install.
- (void)selfSignAndInstall:(NSString *)local force:(BOOL)force {
    NSString *signer = [[NSBundle mainBundle].bundlePath stringByAppendingPathComponent:@"fastPathSign"];
    if (![[NSFileManager defaultManager] fileExistsAtPath:signer]) { TMAlert(self, @"Signer missing", @"Trollamine's signer tool isn't present, so it can't install apps on its own."); return; }
    UIAlertController *busy = [UIAlertController alertControllerWithTitle:@"Preparing..." message:local.lastPathComponent preferredStyle:UIAlertControllerStyleAlert];
    [self presentViewController:busy animated:YES completion:nil];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSFileManager *fm = [NSFileManager defaultManager];
        NSString *work = TMWorkDir();
        NSString *stage = [work stringByAppendingPathComponent:[@"ins-" stringByAppendingString:[NSUUID UUID].UUIDString]];
        [fm createDirectoryAtPath:stage withIntermediateDirectories:YES attributes:nil error:nil];
        NSString *problem = nil;
        NSString *tipa = nil;
        NSDictionary *fileAttrs = [fm attributesOfItemAtPath:local error:nil];
        if ([fileAttrs fileSize] > 500 * 1024 * 1024) {
            problem = @"File is too large (over 500 MB).";
        }
        char zerr[256] = "";
        if (!problem && tm_extract_zip(local.fileSystemRepresentation, stage.fileSystemRepresentation, zerr, sizeof(zerr)) != 0) {
            problem = [NSString stringWithFormat:@"Couldn't unpack the app: %s", zerr];
        }
        NSString *appDir = nil;
        if (!problem) {
            NSString *payload = [stage stringByAppendingPathComponent:@"Payload"];
            for (NSString *item in [fm contentsOfDirectoryAtPath:payload error:nil]) {
                if ([item.pathExtension isEqualToString:@"app"]) { appDir = [payload stringByAppendingPathComponent:item]; break; }
            }
            if (!appDir) problem = @"No app was found inside the file.";
        }
        if (!problem) {
            // Mark every binary as already carrying the CMS SignerInfo bypass (value 2), so the
            // installer engine takes the fast path and does not try to re-sign with ldid.
            NSString *infoP = [appDir stringByAppendingPathComponent:@"Info.plist"];
            NSMutableDictionary *info = [NSPropertyListSerialization propertyListWithData:[NSData dataWithContentsOfFile:infoP] options:NSPropertyListMutableContainersAndLeaves format:NULL error:nil];
            if ([info isKindOfClass:[NSMutableDictionary class]]) {
                info[@"TSPreAppliedExploitType"] = @2;
                NSData *d = [NSPropertyListSerialization dataWithPropertyList:info format:NSPropertyListBinaryFormat_v1_0 options:0 error:nil];
                if (d) [d writeToFile:infoP atomically:YES];
            }
        }
        if (!problem) {
            NSString *signErr = tm_sign_app_bundle(appDir, signer, work);
            if (signErr) problem = signErr;
        }
        if (!problem) {
            tipa = [work stringByAppendingPathComponent:[[NSUUID UUID].UUIDString stringByAppendingPathExtension:@"tipa"]];
            NSString *pkgErr = tm_make_tipa(stage, tipa);
            if (pkgErr) problem = pkgErr;
        }
        [fm removeItemAtPath:stage error:nil];
        dispatch_async(dispatch_get_main_queue(), ^{
            [busy dismissViewControllerAnimated:YES completion:^{
                [fm removeItemAtPath:local error:nil];
                if (problem) { TMAlert(self, @"Something went wrong", problem); return; }
                [self installPreparedTipa:tipa force:force];
            }];
        });
    });
}

- (void)installPreparedTipa:(NSString *)tipa force:(BOOL)force {
    BOOL custom = [[NSUserDefaults standardUserDefaults] integerForKey:@"TMInstallMethod"] == 1;
    NSMutableArray *args = [NSMutableArray arrayWithObjects:@"install", custom ? @"custom" : @"installd", nil];
    if (force) [args addObject:@"force"];
    [args addObject:tipa];
    TKRun(self, @"Installing...", args, ^(int code, NSString *log) {
        if (code == 171 && !force) {
            UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"Already installed" message:@"An app with the same identifier is installed and it isn't a TrollStore app. Installing anyway replaces it, and its data may be lost." preferredStyle:UIAlertControllerStyleAlert];
            [ac addAction:[UIAlertAction actionWithTitle:@"Install Anyway" style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *a) { [self installPreparedTipa:tipa force:YES]; }]];
            [ac addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:^(__unused UIAlertAction *a) {
                [[NSFileManager defaultManager] removeItemAtPath:tipa error:nil];
            }]];
            [self presentViewController:ac animated:YES completion:nil];
            return;
        }
        [[NSFileManager defaultManager] removeItemAtPath:tipa error:nil];
        [self reload];
        if (code == 0) TMAlert(self, @"Installed", @"Look for the app on your home screen.");
        else if (code == 182) TMAlert(self, @"Installed, with a note", @"This app needs Developer Mode. Restart the phone and turn it on when asked, then the app will open.");
        else if (code == 184) TMAlert(self, @"Installed, with a note", @"Some parts of the app (such as extensions) are still encrypted, so those parts may not work.");
        else TMAlert(self, @"Install failed", TKInstallError(code));
    });
}

#pragma mark Per-app actions

- (NSString *)registrationOf:(NSDictionary *)app {
    Class proxyClass = NSClassFromString(@"LSApplicationProxy");
    id proxy = [proxyClass performSelector:NSSelectorFromString(@"applicationProxyForIdentifier:") withObject:app[@"id"]];
    NSString *type = TMSafeValue(proxy, @"applicationType");
    return [type isKindOfClass:[NSString class]] ? type : nil;
}

- (void)showActionsForApp:(NSDictionary *)app {
    BOOL isTrollStore = [app[@"id"] isEqualToString:@"com.opa334.TrollStore"];
    BOOL isSelf = [app[@"id"] isEqualToString:[NSBundle mainBundle].bundleIdentifier];
    NSString *reg = [self registrationOf:app];
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:app[@"name"] message:app[@"id"] preferredStyle:UIAlertControllerStyleAlert];
    if (!isSelf) {
        [ac addAction:[UIAlertAction actionWithTitle:@"Open" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *a) {
            if (!TMOpenApp(app[@"id"])) TMAlert(self, @"Couldn't open it", @"The app didn't launch.");
        }]];
        [ac addAction:[UIAlertAction actionWithTitle:@"Open with JIT" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *a) { [self openWithJIT:app]; }]];
    }
    [ac addAction:[UIAlertAction actionWithTitle:@"Show Details" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *a) {
        [self.navigationController pushViewController:[[TKDetailController alloc] initWithApp:app] animated:YES];
    }]];
    if (reg && !isTrollStore) {
        NSString *target = [reg isEqualToString:@"User"] ? @"System" : @"User";
        [ac addAction:[UIAlertAction actionWithTitle:[NSString stringWithFormat:@"Switch to \"%@\" Registration", target] style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *a) {
            [self switchApp:app to:target];
        }]];
    }
    if (!isTrollStore && !isSelf) {
        [ac addAction:[UIAlertAction actionWithTitle:@"Uninstall" style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *a) { [self confirmUninstall:app]; }]];
    }
    [ac addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:ac animated:YES completion:nil];
}

- (void)openWithJIT:(NSDictionary *)app {
    if (!TMOpenApp(app[@"id"])) { TMAlert(self, @"Couldn't open it", @"The app didn't launch."); return; }
    NSString *helper = TMHelperPath();
    if (!helper) return;
    // The app has to be running before JIT can be switched on for it.
    // Timing race: the app needs time to fully launch before we can enable JIT.
    // 1.5s is generous enough to handle slow app starts.
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        typeof(self) self = weakSelf; if (!self) return;
        NSString *log = nil;
        int code = TMSpawnRoot(helper, @[@"enable-jit", app[@"id"]], &log);
        if (code != 0) dispatch_async(dispatch_get_main_queue(), ^{
            TMAlert(self, @"JIT wasn't enabled", [NSString stringWithFormat:@"The installer returned code %d.", code]);
        });
    });
}

- (void)switchApp:(NSDictionary *)app to:(NSString *)target {
    NSString *msg = [target isEqualToString:@"User"]
        ? @"\"User\" keeps iOS permissions working normally, but the app stops opening after the next icon cache reload until you refresh registrations."
        : @"\"System\" survives icon cache reloads, but some permissions and settings pages may not work for the app.";
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:[NSString stringWithFormat:@"Switch to \"%@\"?", target] message:msg preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"Switch" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *a) {
        TKRun(self, @"Switching...", @[@"modify-registration", app[@"path"], target], ^(int code, __unused NSString *log) {
            if (code != 0) TMAlert(self, @"Something went wrong", [NSString stringWithFormat:@"The installer returned code %d.", code]);
            [self reload];
        });
    }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:ac animated:YES completion:nil];
}

- (void)tableView:(UITableView *)tableView willDisplayCell:(UITableViewCell *)cell forRowAtIndexPath:(NSIndexPath *)indexPath { TKThemeCell(cell); }
- (void)tableView:(UITableView *)tableView willDisplayHeaderView:(UIView *)view forSection:(NSInteger)section { TKThemeHeader(view, NO); }
- (void)tableView:(UITableView *)tableView willDisplayFooterView:(UIView *)view forSection:(NSInteger)section { TKThemeHeader(view, YES); }

@end

#pragma mark Settings tab

// ---- Persistence helper (device-wide; hosted in a removable system app) ----
// All installed apps, user AND system, deduped — allInstalledApplications alone can omit system apps.
static NSArray *TKAllAppProxies(void) {
    Class wsClass = NSClassFromString(@"LSApplicationWorkspace");
    id ws = [wsClass performSelector:NSSelectorFromString(@"defaultWorkspace")];
    NSMutableArray *all = [NSMutableArray array];
    NSMutableSet *seen = [NSMutableSet set];
    void (^add)(id) = ^(id proxy) {
        NSString *bid = TMSafeValue(proxy, @"bundleIdentifier");
        if ([bid isKindOfClass:[NSString class]] && ![seen containsObject:bid]) { [seen addObject:bid]; [all addObject:proxy]; }
    };
    if ([ws respondsToSelector:@selector(allInstalledApplications)]) {
        for (id p in [ws allInstalledApplications]) add(p);
    }
    if ([ws respondsToSelector:@selector(enumerateApplicationsOfType:block:)]) {
        @try { [ws enumerateApplicationsOfType:0 block:^(id proxy) { add(proxy); }]; } @catch (__unused NSException *e) {}  // user
        @try { [ws enumerateApplicationsOfType:1 block:^(id proxy) { add(proxy); }]; } @catch (__unused NSException *e) {}  // system
    }
    return all;
}

// Finds any app already hosting a persistence helper (TrollStore's or ours), or nil.
// Scans the filesystem for the helper's marker file, since that is the real source of truth
// and the app database can omit system apps or deny reads.
static NSString *TKNameForAppDir(NSString *appDir, NSString **outId) {
    NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:[appDir stringByAppendingPathComponent:@"Info.plist"]];
    if (outId) *outId = info[@"CFBundleIdentifier"];
    NSString *name = info[@"CFBundleDisplayName"] ?: info[@"CFBundleName"];
    return [name isKindOfClass:[NSString class]] ? name : [[appDir lastPathComponent] stringByDeletingPathExtension];
}

static NSString *TKPersistenceHostName(NSString **outId) {
    NSFileManager *fm = [NSFileManager defaultManager];
    // Primary: every installed app's bundle (user + system), checked for the marker via its bundle URL.
    for (id proxy in TKAllAppProxies()) {
        NSURL *url = TMSafeValue(proxy, @"bundleURL");
        if (![url isKindOfClass:[NSURL class]]) continue;
        NSString *markPath = [url.path stringByAppendingPathComponent:@".TrollStorePersistenceHelper"];
        if (![fm fileExistsAtPath:markPath]) continue;
        // Marker exists; also verify the PersistenceHelper binary is present in the bundle.
        if (![fm fileExistsAtPath:[url.path stringByAppendingPathComponent:@"PersistenceHelper"]]) continue;
        if (outId) *outId = TMSafeValue(proxy, @"bundleIdentifier");
        NSString *name = TMSafeValue(proxy, @"localizedName");
        return [name isKindOfClass:[NSString class]] ? name : TMSafeValue(proxy, @"bundleIdentifier");
    }
    // Secondary: stock system apps in /Applications (that directory is listable).
    for (NSString *item in [fm contentsOfDirectoryAtPath:@"/Applications" error:nil]) {
        if (![item.pathExtension isEqualToString:@"app"]) continue;
        NSString *appDir = [@"/Applications" stringByAppendingPathComponent:item];
        if ([fm fileExistsAtPath:[appDir stringByAppendingPathComponent:@".TrollStorePersistenceHelper"]]
            && [fm fileExistsAtPath:[appDir stringByAppendingPathComponent:@"PersistenceHelper"]])
            return TKNameForAppDir(appDir, outId);
    }
    return nil;
}

static NSArray<NSDictionary *> *TKEligibleSystemApps(void) {
    NSMutableArray *out = [NSMutableArray array];
    NSFileManager *fm = [NSFileManager defaultManager];
    for (id proxy in TKAllAppProxies()) {
        if (![TMSafeValue(proxy, @"applicationType") isEqualToString:@"System"]) continue;
        NSString *bid = TMSafeValue(proxy, @"bundleIdentifier");
        if (![bid isKindOfClass:[NSString class]]) continue;
        if (![fm fileExistsAtPath:[@"/System/Library/AppSignatures" stringByAppendingPathComponent:bid]]) continue; // removable system app
        NSString *name = TMSafeValue(proxy, @"localizedName");
        [out addObject:@{@"id": bid, @"name": [name isKindOfClass:[NSString class]] ? name : bid}];
    }
    [out sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) { return [a[@"name"] localizedCaseInsensitiveCompare:b[@"name"]]; }];
    return out;
}

// Count of apps installed via the TrollStore engine (marked with _TrollStore).
static NSUInteger TKCountTrollStoreApps(void) {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSUInteger n = 0;
    NSString *root = @"/var/containers/Bundle/Application";
    for (NSString *uuid in [fm contentsOfDirectoryAtPath:root error:nil]) {
        if ([fm fileExistsAtPath:[[root stringByAppendingPathComponent:uuid] stringByAppendingPathComponent:@"_TrollStore"]]) n++;
    }
    return n;
}

typedef NS_ENUM(NSInteger, TKSection) { TKSectionUtilities, TKSectionSigning, TKSectionInstall, TKSectionUninstall, TKSectionPersistence, TKSectionScheme, TKSectionAbout, TKSectionCount };

@interface TKSettingsController : UITableViewController
@end

@implementation TKSettingsController

- (instancetype)init { return [super initWithStyle:UITableViewStyleInsetGrouped]; }

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Settings";
    self.navigationController.navigationBar.prefersLargeTitles = YES;
    TKThemeTable(self);
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:self action:@selector(closeMenu)];

    UIView *header = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 320, 150)];
    UIImageView *icon = [[UIImageView alloc] initWithImage:[UIImage imageNamed:@"TMIcon60x60@3x.png"]];
    icon.layer.cornerRadius = 16;
    icon.layer.masksToBounds = YES;
    icon.translatesAutoresizingMaskIntoConstraints = NO;
    UILabel *name = [UILabel new];
    name.text = @"Trollamine";
    name.font = [UIFont systemFontOfSize:22 weight:UIFontWeightBold];
    name.textColor = [UIColor whiteColor];
    name.translatesAutoresizingMaskIntoConstraints = NO;
    UILabel *sub = [UILabel new];
    sub.text = @"TrollStore x Dopamine";
    sub.font = [UIFont systemFontOfSize:14];
    sub.textColor = [UIColor colorWithWhite:1.0 alpha:0.7];
    sub.translatesAutoresizingMaskIntoConstraints = NO;
    [header addSubview:icon]; [header addSubview:name]; [header addSubview:sub];
    [NSLayoutConstraint activateConstraints:@[
        [icon.centerXAnchor constraintEqualToAnchor:header.centerXAnchor],
        [icon.topAnchor constraintEqualToAnchor:header.topAnchor constant:12],
        [icon.widthAnchor constraintEqualToConstant:72], [icon.heightAnchor constraintEqualToConstant:72],
        [name.centerXAnchor constraintEqualToAnchor:header.centerXAnchor],
        [name.topAnchor constraintEqualToAnchor:icon.bottomAnchor constant:8],
        [sub.centerXAnchor constraintEqualToAnchor:header.centerXAnchor],
        [sub.topAnchor constraintEqualToAnchor:name.bottomAnchor constant:2],
    ]];
    self.tableView.tableHeaderView = header;
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self.tableView reloadData];
}

- (void)closeMenu { [self.tabBarController dismissViewControllerAnimated:YES completion:^{ sPanelOpen = NO; }]; }

#pragma mark State

- (NSString *)ldidVersion { return TKLdidVersion(); }

- (BOOL)schemeEnabled {
    NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:[TKTrollStorePath() stringByAppendingPathComponent:@"Info.plist"]];
    for (NSDictionary *type in info[@"CFBundleURLTypes"]) {
        if (![type isKindOfClass:[NSDictionary class]]) continue;
        for (NSString *scheme in type[@"CFBundleURLSchemes"]) {
            if ([scheme isKindOfClass:[NSString class]] && [scheme isEqualToString:@"apple-magnifier"]) return YES;
        }
    }
    return NO;
}

#pragma mark Table

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return TKSectionCount; }

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    switch (section) {
        case TKSectionUtilities: return 3;
        case TKSectionSigning: return 1;
        case TKSectionInstall: return 2;
        case TKSectionUninstall: return 2;
        case TKSectionPersistence: return 1;
        case TKSectionScheme: return 1;
        default: return 2;
    }
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    switch (section) {
        case TKSectionUtilities: return @"Utilities";
        case TKSectionSigning: return @"Signer";
        case TKSectionInstall: return @"Install method";
        case TKSectionUninstall: return @"Uninstall method";
        case TKSectionPersistence: return @"Persistence helper";
        case TKSectionScheme: return @"Links";
        default: return @"About";
    }
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    switch (section) {
        case TKSectionUtilities: return @"Refresh fixes apps that stopped opening. Rebuilding the icon cache restarts the home screen. Re-register sends every TrollStore app through the system again so they keep working without TrollStore.";
        case TKSectionSigning: return @"Trollamine signs apps itself with a built-in signer, so it installs apps without TrollStore.";
        case TKSectionInstall: return @"installd is TrollStore's default and survives icon cache reloads best. Custom is the fallback if installd fails.";
        case TKSectionUninstall: return @"installd is the default. Custom removes the app directly.";
        case TKSectionPersistence: return @"Optional. Installs into a removable system app (you pick which) and auto-refreshes app registrations after a reboot, so TrollStore apps keep opening. Device-wide: one helper covers everything.";
        case TKSectionScheme: return @"Lets websites hand apps to TrollStore with apple-magnifier:// links. This changes the TrollStore app's own setting.";
        default: return @"Trollamine is self-contained: it carries its own signer and installer engine. TrollStore is not required.";
    }
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:nil];
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    switch (indexPath.section) {
        case TKSectionUtilities:
            cell.textLabel.text = indexPath.row == 0 ? @"Refresh App Registrations" : (indexPath.row == 1 ? @"Rebuild Icon Cache" : @"Re-register All Apps");
            cell.textLabel.textColor = self.view.tintColor;
            cell.tag = 1;
            break;
        case TKSectionSigning: {
            NSString *signer = [[NSBundle mainBundle].bundlePath stringByAppendingPathComponent:@"fastPathSign"];
            cell.textLabel.text = @"Signer";
            cell.detailTextLabel.text = [[NSFileManager defaultManager] fileExistsAtPath:signer] ? @"Built-in" : @"Missing";
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
            break;
        }
        case TKSectionInstall:
            cell.textLabel.text = indexPath.row == 0 ? @"installd (default)" : @"Custom";
            cell.accessoryType = ([defaults integerForKey:@"TMInstallMethod"] == indexPath.row) ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
            break;
        case TKSectionUninstall:
            cell.textLabel.text = indexPath.row == 0 ? @"installd (default)" : @"Custom";
            cell.accessoryType = ([defaults integerForKey:@"TMUninstallMethod"] == indexPath.row) ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
            break;
        case TKSectionPersistence: {
            NSString *host = TKPersistenceHostName(NULL);
            if (host) {
                cell.textLabel.text = @"Uninstall from";
                cell.detailTextLabel.text = host;
                cell.textLabel.textColor = [UIColor colorWithRed:0.95 green:0.45 blue:0.45 alpha:1.0];
                cell.tag = 1;
            } else {
                cell.textLabel.text = @"Install Persistence Helper";
                cell.textLabel.textColor = self.view.tintColor;
                cell.tag = 1;
            }
            break;
        }
        case TKSectionScheme: {
            cell.textLabel.text = @"TrollStore URL Scheme";
            UISwitch *sw = [UISwitch new];
            sw.on = [self schemeEnabled];
            sw.enabled = TKTrollStorePath() != nil;
            [sw addTarget:self action:@selector(schemeToggled:) forControlEvents:UIControlEventValueChanged];
            cell.accessoryView = sw;
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
            break;
        }
        default: {
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
            if (indexPath.row == 0) {
                NSString *own = [[NSBundle mainBundle].bundlePath stringByAppendingPathComponent:@"trollstorehelper"];
                BOOL bundled = [[NSFileManager defaultManager] fileExistsAtPath:own];
                cell.textLabel.text = @"Installer engine";
                cell.detailTextLabel.text = bundled ? @"Bundled" : (TMHelperPath() ? @"From TrollStore" : @"Missing");
            } else {
                cell.textLabel.text = @"Version";
                cell.detailTextLabel.text = @"Trollamine 2.0";
            }
            break;
        }
    }
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    switch (indexPath.section) {
        case TKSectionUtilities:
            if (indexPath.row == 0) {
                TKRun(self, @"Refreshing...", @[@"refresh"], ^(int code, __unused NSString *log) {
                    if (code == 0) TMAlert(self, @"Done", @"App registrations refreshed.");
                    else TMAlert(self, @"Something went wrong", [NSString stringWithFormat:@"The installer returned code %d.", code]);
                });
            } else if (indexPath.row == 1) {
                UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"Rebuild icon cache?" message:@"The home screen restarts, which takes a little while." preferredStyle:UIAlertControllerStyleAlert];
                [ac addAction:[UIAlertAction actionWithTitle:@"Rebuild" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *a) {
                    TKRun(self, @"Rebuilding...", @[@"refresh-all"], nil);
                }]];
                [ac addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
                [self presentViewController:ac animated:YES completion:nil];
            } else {
                [self adoptAllApps];
            }
            break;
        case TKSectionSigning:
            break;
        case TKSectionInstall:
            [defaults setInteger:indexPath.row forKey:@"TMInstallMethod"];
            [tableView reloadData];
            break;
        case TKSectionUninstall:
            [defaults setInteger:indexPath.row forKey:@"TMUninstallMethod"];
            [tableView reloadData];
            break;
        case TKSectionPersistence: [self persistenceTapped]; break;
        default: break;
    }
}

- (void)adoptAllApps {
    NSUInteger count = TKCountTrollStoreApps();
    NSString *msg = count ? [NSString stringWithFormat:@"Re-register all %lu TrollStore apps through the system? They'll keep working even if you remove TrollStore.", (unsigned long)count]
                          : @"Re-register all TrollStore apps through the system?";
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"Re-register all apps" message:msg preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"Re-register" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *a) {
        TKRun(self, @"Re-registering...", @[@"refresh"], ^(int code, __unused NSString *log) {
            if (code == 0) {
                NSUInteger n = TKCountTrollStoreApps();
                TMAlert(self, @"Done", n ? [NSString stringWithFormat:@"Re-registered %lu apps.", (unsigned long)n] : @"All TrollStore apps have been re-registered.");
            } else {
                TMAlert(self, @"Something went wrong", [NSString stringWithFormat:@"The engine returned code %d.", code]);
            }
        });
    }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:ac animated:YES completion:nil];
}

- (void)persistenceTapped {
    NSString *hostId = nil;
    NSString *host = TKPersistenceHostName(&hostId);
    if (host) {
        UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"Remove persistence helper?" message:[NSString stringWithFormat:@"This restores \"%@\" to normal.", host] preferredStyle:UIAlertControllerStyleAlert];
        [ac addAction:[UIAlertAction actionWithTitle:@"Remove" style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *a) {
            TKRun(self, @"Removing...", @[@"uninstall-persistence-helper"], ^(int code, __unused NSString *log) {
                if (code != 0) TMAlert(self, @"Something went wrong", [NSString stringWithFormat:@"The engine returned code %d.", code]);
                [self.tableView reloadData];
            });
        }]];
        [ac addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
        [self presentViewController:ac animated:YES completion:nil];
        return;
    }
    // No helper is installed (the check above returned nil and we fell through).
    NSString *phelper = [[NSBundle mainBundle].bundlePath stringByAppendingPathComponent:@"PersistenceHelper"];
    if (![[NSFileManager defaultManager] fileExistsAtPath:phelper]) {
        TMAlert(self, @"Not available", @"This Trollamine build doesn't include the persistence helper binary (TrollStore wasn't installed when it was built). Rebuild Trollamine with TrollStore present to include it.");
        return;
    }
    NSArray<NSDictionary *> *apps = TKEligibleSystemApps();
    if (apps.count == 0) { TMAlert(self, @"No eligible apps", @"No removable system app was found to host the helper."); return; }
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"Install into which app?" message:@"Pick a removable system app to host the helper. It keeps its icon, but its normal function is replaced until you remove the helper. \"Tips\" is the usual choice." preferredStyle:UIAlertControllerStyleActionSheet];
    for (NSDictionary *app in apps) {
        [ac addAction:[UIAlertAction actionWithTitle:app[@"name"] style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *a) { [self installPersistenceInto:app]; }]];
    }
    [ac addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    ac.popoverPresentationController.sourceView = self.tableView;
    NSIndexPath *persIP = [NSIndexPath indexPathForRow:0 inSection:TKSectionPersistence];
    ac.popoverPresentationController.sourceRect = [self.tableView rectForRowAtIndexPath:persIP];
    [self presentViewController:ac animated:YES completion:nil];
}

- (void)installPersistenceInto:(NSDictionary *)app {
    NSString *phelper = [[NSBundle mainBundle].bundlePath stringByAppendingPathComponent:@"PersistenceHelper"];
    NSString *rhelper = [[NSBundle mainBundle].bundlePath stringByAppendingPathComponent:@"trollstorehelper"];
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:[NSString stringWithFormat:@"Use \"%@\"?", app[@"name"]] message:[NSString stringWithFormat:@"\"%@\" becomes the persistence helper. After a reboot, open it once to refresh your apps. You can undo this here anytime.", app[@"name"]] preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"Install" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *a) {
        TKRun(self, @"Installing...", @[@"install-persistence-helper", app[@"id"], phelper, rhelper], ^(int code, __unused NSString *log) {
            if (code == 0) TMAlert(self, @"Done", [NSString stringWithFormat:@"\"%@\" is now the persistence helper.", app[@"name"]]);
            else TMAlert(self, @"Something went wrong", [NSString stringWithFormat:@"The engine returned code %d.", code]);
            [self.tableView reloadData];
        });
    }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:ac animated:YES completion:nil];
}

- (void)schemeToggled:(UISwitch *)sw {
    TKRun(self, @"Updating...", @[@"url-scheme", sw.on ? @"enable" : @"disable"], ^(int code, __unused NSString *log) {
        if (code != 0) TMAlert(self, @"Something went wrong", [NSString stringWithFormat:@"The installer returned code %d.", code]);
        [self.tableView reloadData];
    });
}

// Also run automatically by the Apps tab when an app needs signing (installer code 173).
// Downloads opa334's ldid build from GitHub, the same source TrollStore uses, and hands it to the installer engine.
- (void)installLdid {
    UIAlertController *busy = [UIAlertController alertControllerWithTitle:@"Installing ldid..." message:nil preferredStyle:UIAlertControllerStyleAlert];
    [self presentViewController:busy animated:YES completion:nil];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *version = nil;
        NSString *problem = TKInstallLdidSync(&version);
        dispatch_async(dispatch_get_main_queue(), ^{
            [busy dismissViewControllerAnimated:YES completion:^{
                if (problem) TMAlert(self, @"Couldn't get ldid", problem);
                else TMAlert(self, @"Done", [NSString stringWithFormat:@"ldid %@ is installed.", version ?: @""]);
                [self.tableView reloadData];
            }];
        });
    });
}

- (void)tableView:(UITableView *)tableView willDisplayCell:(UITableViewCell *)cell forRowAtIndexPath:(NSIndexPath *)indexPath { TKThemeCell(cell); }
- (void)tableView:(UITableView *)tableView willDisplayHeaderView:(UIView *)view forSection:(NSInteger)section { TKThemeHeader(view, NO); }
- (void)tableView:(UITableView *)tableView willDisplayFooterView:(UIView *)view forSection:(NSInteger)section { TKThemeHeader(view, YES); }

@end

static UIViewController *TKTopController(void);

static void TKOpenMenu(void) {
    if (sPanelOpen) return;
    UIViewController *top = TKTopController();
    if (!top) return;
    sPanelOpen = YES;
    UINavigationController *apps = [[UINavigationController alloc] initWithRootViewController:[TKAppsController new]];
    apps.tabBarItem = [[UITabBarItem alloc] initWithTitle:@"Apps" image:[UIImage systemImageNamed:@"square.stack.3d.up.fill"] tag:0];
    UINavigationController *settings = [[UINavigationController alloc] initWithRootViewController:[TKSettingsController new]];
    settings.tabBarItem = [[UITabBarItem alloc] initWithTitle:@"Settings" image:[UIImage systemImageNamed:@"gear"] tag:1];
    UITabBarController *tabs = [UITabBarController new];
    tabs.viewControllers = @[apps, settings];
    tabs.view.tintColor = [UIColor colorWithRed:0.42 green:0.95 blue:0.72 alpha:1.0];
    UITabBarAppearance *tb = [UITabBarAppearance new];
    [tb configureWithTransparentBackground];
    tb.backgroundEffect = [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemThinMaterialDark];
    tabs.tabBar.standardAppearance = tb;
    if ([tabs.tabBar respondsToSelector:@selector(setScrollEdgeAppearance:)]) tabs.tabBar.scrollEdgeAppearance = tb;
    tabs.modalPresentationStyle = UIModalPresentationFullScreen;
    [top presentViewController:tabs animated:YES completion:nil];
}

#pragma mark - Jailbreak state management

// Detect whether a jailbreak is ACTIVELY RUNNING right now.
// Uses DOEnvironmentManager — the same logic Dopamine itself uses:
//   isJailbroken:                 XPC to Dopamine's jbserver (Dopamine-specific)
//   isJailbrokenWithOtherJailbreak: CS_PLATFORM_BINARY flag via csops (detects palera1n)
// Combined, these cover Dopamine + palera1n + older Dopamine + any jailbreak that
// grants platform binary status. Both are runtime-only — they return NO after reboot.
static BOOL TKIsCurrentlyJailbroken(void) {
    @try {
        id mgr = [objc_getClass("DOEnvironmentManager") performSelector:sel_registerName("sharedManager")];
        if (!mgr) return NO;
        // Dopamine's own jailbreak (XPC to jbserver)
        if ([mgr respondsToSelector:sel_registerName("isJailbroken")]) {
            if (((BOOL (*)(id, SEL))objc_msgSend)(mgr, sel_registerName("isJailbroken"))) return YES;
        }
        // Other jailbreaks — palera1n (CS_PLATFORM_BINARY), older Dopamine (/usr/lib/systemhook.dylib)
        if ([mgr respondsToSelector:sel_registerName("isJailbrokenWithOtherJailbreak")]) {
            if (((BOOL (*)(id, SEL))objc_msgSend)(mgr, sel_registerName("isJailbrokenWithOtherJailbreak"))) return YES;
        }
    } @catch (__unused NSException *e) {}
    return NO;
}

// Reboots the device (removes any semi-untethered/semi-tethered jailbreak).
static void TKRebootDevice(UIViewController *vc) {
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"Reboot"
        message:@"This will reboot your device."
        preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"Reboot" style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *a) {
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            NSString *log = nil;
            sync();
            TMSpawnRoot(@"/usr/sbin/reboot", @[], &log);
            NSString *helper = TMHelperPath();
            if (helper) TMSpawnRoot(helper, @[@"reboot"], &log);
        });
    }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [vc presentViewController:ac animated:YES completion:nil];
}

#pragma mark - Hooks into Dopamine's screen

static BOOL gMenuRowAdded;

// Adds a "TrollStore" row to Dopamine's action menu, right after Settings.
static id (*orig_menuInit)(id, SEL, NSArray *, id);
static id hook_menuInit(id self, SEL _cmd, NSArray *actions, id delegate) {
    @try {
        if ([actions isKindOfClass:[NSArray class]]) {
            NSMutableArray *list = [actions mutableCopy];

            // Add the TrollStore row (after Settings, index 1).
            UIImage *image = [[UIImage imageNamed:@"TrollMenuIcon"] imageWithRenderingMode:UIImageRenderingModeAlwaysOriginal];
            if (!image) image = [UIImage systemImageNamed:@"square.stack.3d.up"];
            UIAction *row = [UIAction actionWithTitle:@"TrollStore" image:image identifier:@"trollstore" handler:^(__unused UIAction *a) { TKOpenMenu(); }];
            [list insertObject:row atIndex:MIN((NSUInteger)1, list.count)];

            actions = list;
            gMenuRowAdded = YES;
        }
    } @catch (__unused NSException *e) {}
    return orig_menuInit(self, _cmd, actions, delegate);
}

static BOOL (*orig_showsChevron)(id, SEL, UIAction *);
static BOOL hook_showsChevron(id self, SEL _cmd, UIAction *action) {
    if ([action.identifier isEqualToString:@"trollstore"]) return YES;
    return orig_showsChevron(self, _cmd, action);
}

// Hook DOMainViewController's jailbreakButtonTitle to return "Remove" when jailbroken.
// Dopamine calls this in viewWillAppear AND at init to set the button's visible text.
// Hooking the button's own init doesn't work because viewWillAppear overwrites the title.
static NSString *(*orig_jbButtonTitle)(id, SEL);
static NSString *hook_jbButtonTitle(id self, SEL _cmd) {
    if (TKIsCurrentlyJailbroken()) return @"Remove";
    return orig_jbButtonTitle(self, _cmd);
}

// Hook DOMainViewController's startJailbreak to intercept the button tap.
// When jailbroken, show the reboot dialog instead of running the exploit (which would
// crash the kernel and cause an uncontrolled reboot).
static void (*orig_startJailbreak)(id, SEL);
static void hook_startJailbreak(id self, SEL _cmd) {
    if (TKIsCurrentlyJailbroken()) {
        TKRebootDevice(self);
        return;
    }
    orig_startJailbreak(self, _cmd);
}

// Hook DOJailbreakButton -setEnabled: so that when jailbroken, the button stays
// tappable (Dopamine disables it when it detects a jailbreak).
static void (*orig_jbButtonSetEnabled)(id, SEL, BOOL);
static void hook_jbButtonSetEnabled(id self, SEL _cmd, BOOL enabled) {
    if (TKIsCurrentlyJailbroken()) enabled = YES;
    orig_jbButtonSetEnabled(self, _cmd, enabled);
}

// Draws the "Trollamine" wordmark that replaces the "Dopamine" one at the top.
static UIImage *TKWordmark(void) {
    UIFont *base = [UIFont systemFontOfSize:46 weight:UIFontWeightHeavy];
    UIFontDescriptor *rounded = [base.fontDescriptor fontDescriptorWithDesign:UIFontDescriptorSystemDesignRounded];
    UIFont *font = rounded ? [UIFont fontWithDescriptor:rounded size:46] : base;
    NSDictionary *attrs = @{NSFontAttributeName: font, NSForegroundColorAttributeName: [UIColor whiteColor]};
    NSString *text = @"Trollamine";
    CGSize textSize = [text sizeWithAttributes:attrs];
    CGFloat pad = font.capHeight * 0.10;
    CGFloat height = ceil(pad * 2 + font.capHeight * 1.04);
    CGSize size = CGSizeMake(ceil(textSize.width), height);
    UIGraphicsImageRendererFormat *fmt = [UIGraphicsImageRendererFormat preferredFormat];
    fmt.opaque = NO;
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:size format:fmt];
    return [renderer imageWithActions:^(__unused UIGraphicsImageRendererContext *ctx) {
        [text drawAtPoint:CGPointMake(0, pad + font.capHeight * 1.04 - font.ascender) withAttributes:attrs];
    }];
}

static id (*orig_headerInit)(id, SEL, UIImage *, NSArray *);
static id hook_headerInit(id self, SEL _cmd, UIImage *image, NSArray *subtitles) {
    @try {
        UIImage *wordmark = TKWordmark();
        if (wordmark.size.width > 0 && wordmark.size.height > 0) image = wordmark;
        if ([subtitles isKindOfClass:[NSArray class]]) {
            NSAttributedString *line = [[NSAttributedString alloc] initWithString:@"TrollStore x Dopamine" attributes:@{
                NSFontAttributeName: [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold],
                NSForegroundColorAttributeName: [UIColor whiteColor],
            }];
            NSMutableArray *list = [subtitles mutableCopy];
            [list insertObject:line atIndex:0];
            subtitles = list;
        }
    } @catch (__unused NSException *e) {}
    return orig_headerInit(self, _cmd, image, subtitles);
}

static void TKSwap(const char *className, const char *selName, IMP replacement, IMP *original, unsigned expectedArgs) {
    Class cls = objc_getClass(className);
    Method m = cls ? class_getInstanceMethod(cls, sel_registerName(selName)) : NULL;
    if (!m || *original) return;
    // Only hook if the method takes exactly the arguments we expect. If this Dopamine version has a
    // different signature, skip the hook (the floating TrollStore button is the fallback) rather than crash.
    if (method_getNumberOfArguments(m) != expectedArgs) return;
    *original = method_getImplementation(m);
    method_setImplementation(m, replacement);
}

static void TKInstallHooks(void) {
    // arg counts include the implicit self + _cmd.
    TKSwap("DOActionMenuView", "initWithActions:delegate:", (IMP)hook_menuInit, (IMP *)&orig_menuInit, 4);
    TKSwap("DOMainViewController", "actionMenuShowsChevronForAction:", (IMP)hook_showsChevron, (IMP *)&orig_showsChevron, 3);
    TKSwap("DOHeaderView", "initWithImage:subtitles:", (IMP)hook_headerInit, (IMP *)&orig_headerInit, 4);
    // Jailbreak button: when jailbroken, show "Remove" and reboot on tap instead of running the exploit.
    // We hook DOMainViewController (not the button) because the VC controls the title and action.
    TKSwap("DOMainViewController", "jailbreakButtonTitle", (IMP)hook_jbButtonTitle, (IMP *)&orig_jbButtonTitle, 2);
    TKSwap("DOMainViewController", "startJailbreak", (IMP)hook_startJailbreak, (IMP *)&orig_startJailbreak, 2);
    TKSwap("DOJailbreakButton", "setEnabled:", (IMP)hook_jbButtonSetEnabled, (IMP *)&orig_jbButtonSetEnabled, 3);
}

#pragma mark - Floating button (fallback, only if the menu row could not be added)

@interface TKButtonHost : NSObject
+ (instancetype)shared;
- (UIWindow *)mainWindow;
@end

@implementation TKButtonHost {
    UIButton *_button;
    NSInteger _ticks;
}

+ (instancetype)shared {
    static TKButtonHost *host;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ host = [TKButtonHost new]; });
    return host;
}

- (UIWindow *)mainWindow {
    UIWindow *fallback = nil;
    for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) continue;
        for (UIWindow *w in ((UIWindowScene *)scene).windows) {
            if (w.isHidden || w.windowLevel != UIWindowLevelNormal) continue;
            if (w.isKeyWindow) return w;
            if (!fallback) fallback = w;
        }
    }
    return fallback;
}

- (void)start {
    // Dopamine builds its screen shortly after launch; keep checking for a few seconds, then settle.
    [NSTimer scheduledTimerWithTimeInterval:0.5 repeats:YES block:^(NSTimer *t) {
        // Give Dopamine a moment to build its menu; only show the fallback button if our row never appeared.
        if (++self->_ticks < 4) return;
        if (gMenuRowAdded) { [self->_button removeFromSuperview]; [t invalidate]; return; }
        @try { [self place]; } @catch (__unused NSException *e) {}
        if (self->_ticks > 40) [t invalidate];
    }];
    // Reposition the floating button when the device rotates.
    [[NSNotificationCenter defaultCenter] addObserverForName:UIDeviceOrientationDidChangeNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(__unused NSNotification *n) {
        [self place];
    }];
}

- (void)place {
    UIWindow *window = [self mainWindow];
    if (!window) return;
    if (!_button) {
        _button = [UIButton buttonWithType:UIButtonTypeSystem];
        [_button setTitle:@" TrollStore" forState:UIControlStateNormal];
        [_button setImage:[UIImage systemImageNamed:@"square.grid.2x2.fill"] forState:UIControlStateNormal];
        _button.tintColor = [UIColor whiteColor];
        _button.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
        _button.backgroundColor = [UIColor colorWithRed:0.10 green:0.30 blue:0.75 alpha:0.85];
        _button.layer.cornerRadius = 18;
        _button.layer.borderWidth = 1;
        _button.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.35].CGColor;
        // Deprecated in iOS 15; works through iOS 18. Replace with UIButtonConfiguration when dropping iOS 14.
        _button.contentEdgeInsets = UIEdgeInsetsMake(0, 12, 0, 14);
        [_button addTarget:self action:@selector(open) forControlEvents:UIControlEventTouchUpInside];
    }
    if (_button.superview != window) [window addSubview:_button];
    [window bringSubviewToFront:_button];
    CGSize size = [_button sizeThatFits:CGSizeMake(200, 36)];
    CGFloat w = MAX(86, size.width), h = 36;
    UIEdgeInsets safe = window.safeAreaInsets;
    _button.frame = CGRectMake(window.bounds.size.width - w - 14 - safe.right, safe.top + 8, w, h);
}

- (void)open { TKOpenMenu(); }

@end

static UIViewController *TKTopController(void) {
    UIWindow *window = [[TKButtonHost shared] mainWindow];
    UIViewController *top = window.rootViewController;
    while (top.presentedViewController) top = top.presentedViewController;
    // A UIAlertController can't present anything; return its presenter instead.
    if ([top isKindOfClass:[UIAlertController class]] && top.presentingViewController)
        top = top.presentingViewController;
    return top;
}

// Bake in Trollamine's boot logo: on first launch, set Dopamine's custom boot logo to our bundled
// gradient wordmark. Done once (guarded by a flag) so the user can still change it later in Settings.
static void TKSeedBootLogo(void) {
    @try {
        NSString *home = NSHomeDirectory();
        NSString *prefsPath = [home stringByAppendingPathComponent:@"Library/Preferences/com.opa334.Dopamine.plist"];
        NSMutableDictionary *prefs = [NSMutableDictionary dictionaryWithContentsOfFile:prefsPath] ?: [NSMutableDictionary new];
        if ([prefs[@"TrollamineBootLogoSeeded"] boolValue]) return;

        BOOL pad = [UIDevice currentDevice].userInterfaceIdiom == UIUserInterfaceIdiomPad;
        NSString *name = pad ? @"Boot_Trollamine_ipad.png" : @"Boot_Trollamine.png";
        NSString *src = [[NSBundle mainBundle].bundlePath stringByAppendingPathComponent:name];
        NSData *img = [NSData dataWithContentsOfFile:src];
        if (!img) { // fall back to the other if the matching one is missing
            src = [[NSBundle mainBundle].bundlePath stringByAppendingPathComponent:@"Boot_Trollamine.png"];
            img = [NSData dataWithContentsOfFile:src];
        }
        if (!img) return;
        NSFileManager *fm = [NSFileManager defaultManager];
        NSString *docs = [home stringByAppendingPathComponent:@"Documents"];
        [fm createDirectoryAtPath:docs withIntermediateDirectories:YES attributes:nil error:nil];
        if (![img writeToFile:[docs stringByAppendingPathComponent:@"bootlogo.png"] atomically:YES]) return;

        prefs[@"bootlogoEnabled"] = @YES;        // master boot-logo switch (defaults YES anyway)
        prefs[@"customBootlogoEnabled"] = @YES;  // use our custom image instead of Dopamine's logo
        prefs[@"TrollamineBootLogoSeeded"] = @YES;
        [fm createDirectoryAtPath:[prefsPath stringByDeletingLastPathComponent] withIntermediateDirectories:YES attributes:nil error:nil];
        [prefs writeToFile:prefsPath atomically:YES];
    } @catch (__unused NSException *e) {}
}

__attribute__((constructor)) static void TKInit(void) {
    @autoreleasepool {
        TKInstallHooks();
        [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidFinishLaunchingNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(__unused NSNotification *n) {
            TKInstallHooks(); // in case the classes weren't ready earlier
            TKSeedBootLogo();
            // The TrollStore entry is added directly to Dopamine's action-menu list (hook_menuInit),
            // so the floating fallback button is not shown.
        }];
    }
}
