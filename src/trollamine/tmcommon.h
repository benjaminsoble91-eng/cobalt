// Shared helpers and the installed-apps list, used by both the installer app and the add-on.
#import <UIKit/UIKit.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <spawn.h>
#import <sys/stat.h>
#import <sys/wait.h>
#import <mach-o/dyld.h>
#import <objc/message.h>

#define TM_BLUE  [UIColor colorWithRed:0.16 green:0.42 blue:0.96 alpha:1.0]
#define TM_GREEN [UIColor colorWithRed:0.18 green:0.78 blue:0.55 alpha:1.0]

#pragma mark - Private API

@interface UIImage (TMPrivate)
+ (UIImage *)_applicationIconImageForBundleIdentifier:(NSString *)bundleID format:(int)format scale:(CGFloat)scale;
@end

#define POSIX_SPAWN_PERSONA_FLAGS_OVERRIDE 1
extern int posix_spawnattr_set_persona_np(const posix_spawnattr_t *__restrict, uid_t, uint32_t);
extern int posix_spawnattr_set_persona_uid_np(const posix_spawnattr_t *__restrict, uid_t);
extern int posix_spawnattr_set_persona_gid_np(const posix_spawnattr_t *__restrict, uid_t);
extern char **environ;

#pragma mark - Helpers

static id TMSafeValue(id obj, NSString *key) {
    @try { return [obj valueForKey:key]; } @catch (__unused NSException *e) { return nil; }
}

static NSString *TMBundlePath(NSString *bundleID) {
    Class proxyClass = NSClassFromString(@"LSApplicationProxy");
    id proxy = [proxyClass performSelector:NSSelectorFromString(@"applicationProxyForIdentifier:") withObject:bundleID];
    NSURL *url = TMSafeValue(proxy, @"bundleURL");
    if (![url isKindOfClass:[NSURL class]]) return nil;
    return [[NSFileManager defaultManager] fileExistsAtPath:url.path] ? url.path : nil;
}

static BOOL TMOpenApp(NSString *bundleID) {
    Class wsClass = NSClassFromString(@"LSApplicationWorkspace");
    id ws = [wsClass performSelector:NSSelectorFromString(@"defaultWorkspace")];
    SEL open = NSSelectorFromString(@"openApplicationWithBundleID:");
    if (![ws respondsToSelector:open]) return NO;
    return ((BOOL (*)(id, SEL, id))objc_msgSend)(ws, open, bundleID);
}

// Dopamine loads its hook library into every process while the jailbreak is active.
// Used by the installer (main.m) only. kit.m uses DOEnvironmentManager instead (TKIsCurrentlyJailbroken).
static BOOL TMIsJailbroken(void) {
    uint32_t count = _dyld_image_count();
    for (uint32_t i = 0; i < count; i++) {
        const char *name = _dyld_get_image_name(i);
        if (name && (strstr(name, "systemhook") || strstr(name, "/var/jb/"))) return YES;
    }
    const char *insert = getenv("DYLD_INSERT_LIBRARIES");
    return insert && strstr(insert, "systemhook");
}

// TrollStore's installer helper: the copy bundled inside this app if there is one, else the installed TrollStore's.
static NSString *TMHelperPath(void) {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *own = [[NSBundle mainBundle].bundlePath stringByAppendingPathComponent:@"trollstorehelper"];
    if ([fm fileExistsAtPath:own]) return own;
    NSString *app = TMBundlePath(@"com.opa334.TrollStore");
    NSString *p = [app stringByAppendingPathComponent:@"trollstorehelper"];
    return (p && [fm fileExistsAtPath:p]) ? p : nil;
}

static NSString *TMWorkDir(void) {
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *dir in @[[NSTemporaryDirectory() stringByAppendingPathComponent:@"Trollamine"], @"/var/mobile/Documents/Trollamine",
                            @"/var/mobile/Library/Caches/Trollamine", @"/var/tmp/Trollamine", @"/tmp/Trollamine"]) {
        [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions: @0700} error:nil];
        NSString *probe = [dir stringByAppendingPathComponent:@".probe"];
        if ([[NSData dataWithBytes:"x" length:1] writeToFile:probe atomically:NO]) {
            [fm removeItemAtPath:probe error:nil];
            return dir;
        }
    }
    return nil;
}

// Runs a binary as root (needs the persona-mgmt entitlement). Returns exit code, or -1 if it couldn't start.
static int TMSpawnRoot(NSString *path, NSArray<NSString *> *args, NSString **output) {
    NSMutableArray *all = [NSMutableArray arrayWithObject:path];
    [all addObjectsFromArray:args];
    char **argv = calloc(all.count + 1, sizeof(char *));
    for (NSUInteger i = 0; i < all.count; i++) argv[i] = strdup([all[i] fileSystemRepresentation]);
    posix_spawnattr_t attr;
    posix_spawnattr_init(&attr);
    posix_spawnattr_set_persona_np(&attr, 99, POSIX_SPAWN_PERSONA_FLAGS_OVERRIDE);
    posix_spawnattr_set_persona_uid_np(&attr, 0);
    posix_spawnattr_set_persona_gid_np(&attr, 0);
    int fds[2] = {-1, -1};
    posix_spawn_file_actions_t actions;
    posix_spawn_file_actions_init(&actions);
    BOOL piped = (pipe(fds) == 0);
    if (piped) {
        posix_spawn_file_actions_adddup2(&actions, fds[1], STDOUT_FILENO);
        posix_spawn_file_actions_adddup2(&actions, fds[1], STDERR_FILENO);
        posix_spawn_file_actions_addclose(&actions, fds[0]);
        posix_spawn_file_actions_addclose(&actions, fds[1]);
    }
    pid_t pid = 0;
    int rc = posix_spawn(&pid, argv[0], &actions, &attr, argv, environ);
    posix_spawn_file_actions_destroy(&actions);
    posix_spawnattr_destroy(&attr);
    for (NSUInteger i = 0; i < all.count; i++) free(argv[i]);
    free(argv);
    if (piped) close(fds[1]);
    if (rc != 0) {
        if (piped) close(fds[0]);
        if (output) *output = [NSString stringWithFormat:@"Couldn't start the installer (%s).", strerror(rc)];
        return -1;
    }
    NSMutableData *buf = [NSMutableData data];
    if (piped) {
        char tmp[4096];
        ssize_t n;
        while ((n = read(fds[0], tmp, sizeof(tmp))) > 0) {
            if (buf.length < 64 * 1024) [buf appendBytes:tmp length:(NSUInteger)n];
        }
        close(fds[0]);
    }
    int status = 0;
    while (waitpid(pid, &status, 0) < 0 && errno == EINTR) {}
    if (output) *output = [[NSString alloc] initWithData:buf encoding:NSUTF8StringEncoding] ?: @"";
    return WIFEXITED(status) ? WEXITSTATUS(status) : 255;
}

static void TMAlert(UIViewController *vc, NSString *title, NSString *message) {
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
    [vc presentViewController:ac animated:YES completion:nil];
}

#pragma mark - Installed apps list

@interface TMAppsController : UITableViewController
- (void)reload;
// Called when a row is tapped; app has keys id, name, version, path. Subclasses can override.
- (void)showActionsForApp:(NSDictionary *)app;
- (void)confirmUninstall:(NSDictionary *)app;
@end

@implementation TMAppsController {
    NSArray<NSDictionary *> *_apps;
}

- (instancetype)init { return [super initWithStyle:UITableViewStyleInsetGrouped]; }

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Installed Apps";
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:self action:@selector(done)];
    self.refreshControl = [[UIRefreshControl alloc] init];
    [self.refreshControl addTarget:self action:@selector(reload) forControlEvents:UIControlEventValueChanged];
    [self reload];
}

- (void)done { [self dismissViewControllerAnimated:YES completion:nil]; }

- (void)reload {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSMutableArray *found = [NSMutableArray array];
        NSFileManager *fm = [NSFileManager defaultManager];
        NSString *root = @"/var/containers/Bundle/Application";
        for (NSString *uuid in [fm contentsOfDirectoryAtPath:root error:nil]) {
            NSString *dir = [root stringByAppendingPathComponent:uuid];
            // TrollStore leaves a marker file next to every app it installs.
            if (![fm fileExistsAtPath:[dir stringByAppendingPathComponent:@"_TrollStore"]]) continue;
            for (NSString *item in [fm contentsOfDirectoryAtPath:dir error:nil]) {
                if (![item.pathExtension isEqualToString:@"app"]) continue;
                NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:[[dir stringByAppendingPathComponent:item] stringByAppendingPathComponent:@"Info.plist"]];
                NSString *bid = info[@"CFBundleIdentifier"];
                if (![bid isKindOfClass:[NSString class]]) continue;
                NSString *name = info[@"CFBundleDisplayName"] ?: info[@"CFBundleName"] ?: [item stringByDeletingPathExtension];
                NSString *ver = info[@"CFBundleShortVersionString"] ?: @"";
                [found addObject:@{@"id": bid, @"name": name, @"version": ver, @"path": [dir stringByAppendingPathComponent:item]}];
            }
        }
        // Also scan /Applications for TrollStore apps (e.g. apps registered as System).
        NSMutableSet *seen = [NSMutableSet set];
        for (NSDictionary *d in found) [seen addObject:d[@"id"]];
        for (NSString *item in [fm contentsOfDirectoryAtPath:@"/Applications" error:nil]) {
            if (![item hasSuffix:@".app"]) continue;
            NSString *app = [@"/Applications" stringByAppendingPathComponent:item];
            if (![fm fileExistsAtPath:[app stringByAppendingPathComponent:@"_TrollStore"]]) continue;
            NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:[app stringByAppendingPathComponent:@"Info.plist"]];
            NSString *bid = info[@"CFBundleIdentifier"];
            if (![bid isKindOfClass:[NSString class]] || [seen containsObject:bid]) continue;
            [seen addObject:bid];
            NSString *name = info[@"CFBundleDisplayName"] ?: info[@"CFBundleName"] ?: [item stringByDeletingPathExtension];
            NSString *ver = info[@"CFBundleShortVersionString"] ?: @"";
            [found addObject:@{@"id": bid, @"name": name, @"version": ver, @"path": app}];
        }
        [found sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
            return [a[@"name"] localizedCaseInsensitiveCompare:b[@"name"]];
        }];
        dispatch_async(dispatch_get_main_queue(), ^{
            self->_apps = found;
            [self.tableView reloadData];
            [self.refreshControl endRefreshing];
        });
    });
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { return (NSInteger)_apps.count; }

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    if (!_apps) return @"Loading...";
    if (_apps.count == 0) return @"No TrollStore apps found. Use + to install an IPA.";
    return [NSString stringWithFormat:@"%lu apps installed with TrollStore", (unsigned long)_apps.count];
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"app"];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"app"];
        cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
    }
    NSDictionary *app = _apps[(NSUInteger)indexPath.row];
    cell.textLabel.text = app[@"name"];
    cell.detailTextLabel.text = [app[@"version"] length] ? [NSString stringWithFormat:@"%@  -  v%@", app[@"id"], app[@"version"]] : app[@"id"];
    UIImage *icon = nil;
    if ([UIImage respondsToSelector:@selector(_applicationIconImageForBundleIdentifier:format:scale:)]) {
        icon = [UIImage _applicationIconImageForBundleIdentifier:app[@"id"] format:1 scale:[UIScreen mainScreen].scale];
    }
    cell.imageView.image = icon ?: [UIImage systemImageNamed:@"app.dashed"];
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    [self showActionsForApp:_apps[(NSUInteger)indexPath.row]];
}

- (void)showActionsForApp:(NSDictionary *)app {
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:app[@"name"] message:app[@"id"] preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"Open" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *a) {
        if (!TMOpenApp(app[@"id"])) TMAlert(self, @"Couldn't open it", @"The app didn't launch.");
    }]];
    BOOL protected = [app[@"id"] isEqualToString:@"com.opa334.TrollStore"] || [app[@"id"] isEqualToString:[NSBundle mainBundle].bundleIdentifier];
    if (!protected) {
        [ac addAction:[UIAlertAction actionWithTitle:@"Uninstall" style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *a) {
            [self confirmUninstall:app];
        }]];
    }
    [ac addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:ac animated:YES completion:nil];
}

- (void)confirmUninstall:(NSDictionary *)app {
    NSString *msg = [NSString stringWithFormat:@"This deletes \"%@\" and its data.", app[@"name"]];
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"Uninstall?" message:msg preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"Uninstall" style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *a) {
        NSString *helper = TMHelperPath();
        if (!helper) { TMAlert(self, @"TrollStore not found", @"Trollamine uses TrollStore's installer to remove apps."); return; }
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            NSString *log = nil;
            // "custom" asks the helper to remove the app itself instead of going through the system installer.
            BOOL custom = [[NSUserDefaults standardUserDefaults] integerForKey:@"TMUninstallMethod"] == 1;
            int code = TMSpawnRoot(helper, custom ? @[@"uninstall", @"custom", app[@"id"]] : @[@"uninstall", app[@"id"]], &log);
            dispatch_async(dispatch_get_main_queue(), ^{
                if (code != 0) TMAlert(self, @"Uninstall failed", [NSString stringWithFormat:@"Installer code %d.", code]);
                [self reload];
            });
        });
    }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:ac animated:YES completion:nil];
}

@end

