// Trollamine Installer - builds "Trollamine" on the device from the installed Dopamine and TrollStore,
// then installs it through TrollStore.
//
// Trollamine = the real Dopamine app (jailbreak code untouched) + the Trollamine theme and icon
//            + TrollStore's installer helper + an add-on library that provides the apps panel.
#import "tmcommon.h"
#import "tdzip.h"
#import "tmzip.h"
#import "machopatch.h"
#import "tmsign.h"

#define TI_APP_ID @"com.mymculture.trollamine"
#define TI_KIT_NAME @"TrollamineKit.dylib"
#define TI_KIT_LOAD_PATH "@executable_path/TrollamineKit.dylib"

#pragma mark - Small helpers

// Runs a program as the normal user and captures its output.
static int TISpawnUser(NSString *path, NSArray<NSString *> *args, NSString **output) {
    NSMutableArray *all = [NSMutableArray arrayWithObject:path];
    [all addObjectsFromArray:args];
    char **argv = calloc(all.count + 1, sizeof(char *));
    for (NSUInteger i = 0; i < all.count; i++) argv[i] = strdup([all[i] fileSystemRepresentation]);
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
    int rc = posix_spawn(&pid, argv[0], &actions, NULL, argv, environ);
    posix_spawn_file_actions_destroy(&actions);
    for (NSUInteger i = 0; i < all.count; i++) free(argv[i]);
    free(argv);
    if (piped) close(fds[1]);
    if (rc != 0) {
        if (piped) close(fds[0]);
        if (output) *output = [NSString stringWithFormat:@"couldn't start (%s)", strerror(rc)];
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

// Path to a tool/library bundled inside this installer app.
static NSString *TIResource(NSString *name) {
    NSString *p = [[NSBundle mainBundle].bundlePath stringByAppendingPathComponent:name];
    return [[NSFileManager defaultManager] fileExistsAtPath:p] ? p : nil;
}

static BOOL TIAddTree(TDZip *zip, NSString *srcDir, NSString *zipDir, NSSet<NSString *> *topSkip, BOOL top) {
    DIR *dir = opendir(srcDir.fileSystemRepresentation);
    if (!dir) {
        zip.errorMessage = [NSString stringWithFormat:@"Can't open %@ (%s)", srcDir, strerror(errno)];
        return NO;
    }
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    struct dirent *ent;
    while ((ent = readdir(dir))) {
        if (strcmp(ent->d_name, ".") == 0 || strcmp(ent->d_name, "..") == 0) continue;
        NSString *n = [[NSFileManager defaultManager] stringWithFileSystemRepresentation:ent->d_name length:strlen(ent->d_name)];
        if (n) [names addObject:n];
    }
    closedir(dir);
    [names sortUsingSelector:@selector(compare:)];
    for (NSString *n in names) {
        if (top && ([topSkip containsObject:n] || ([n hasPrefix:@"TMIcon"] && [n hasSuffix:@".png"]))) continue;
        NSString *src = [srcDir stringByAppendingPathComponent:n];
        NSString *zname = [zipDir stringByAppendingFormat:@"/%@", n];
        struct stat st;
        if (lstat(src.fileSystemRepresentation, &st) != 0) continue;
        if (S_ISLNK(st.st_mode)) {
            char target[PATH_MAX];
            ssize_t len = readlink(src.fileSystemRepresentation, target, sizeof(target));
            if (len < 0) continue;
            if (![zip addData:[NSData dataWithBytes:target length:(NSUInteger)len] name:zname mode:(S_IFLNK | 0755)]) return NO;
        } else if (S_ISDIR(st.st_mode)) {
            if (![zip addData:[NSData data] name:[zname stringByAppendingString:@"/"] mode:(S_IFDIR | 0755)]) return NO;
            if (!TIAddTree(zip, src, zname, topSkip, NO)) return NO;
        } else if (S_ISREG(st.st_mode)) {
            if (![zip addFile:src name:zname mode:(S_IFREG | ((st.st_mode & 0111) ? 0755 : 0644))]) return NO;
        }
    }
    return YES;
}

#pragma mark - The build

// Builds and installs Trollamine. Returns nil on success, or a message describing what failed.
//
// Trollamine is the whole Dopamine app (jailbreak untouched) + the Trollamine theme/icon
// + an add-on library (the TrollStore menu) + TrollStore's installer engine + a bundled signer.
// Every Mach-O is signed here with the bundled signer (adhoc + CoreTrust bypass), so installing
// Trollamine needs no ldid, and the finished app needs no TrollStore.

// Downloads the latest official Dopamine and unpacks it. Returns the path of the unpacked Dopamine.app, or nil.
// If this URL stops working, the installer falls back to the installed Dopamine copy.
#define TI_DOPAMINE_URL @"https://github.com/opa334/Dopamine/releases/latest/download/Dopamine.tipa"
static NSString *TIDownloadDopamine(NSString *work, void (^step)(NSString *), NSString **problem) {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *tipa = [work stringByAppendingPathComponent:@"Dopamine-download.tipa"];
    NSString *outDir = [work stringByAppendingPathComponent:@"dopamine_dl"];
    [fm removeItemAtPath:tipa error:nil];
    [fm removeItemAtPath:outDir error:nil];

    // iOS sometimes refuses this app's own outbound connections ("Operation not permitted").
    // Try three ways in turn so one blocked method doesn't stop the build:
    //   1) a background download task, with live progress;
    //   2) an in-memory request (no system-managed temp file);
    //   3) the command-line curl, which the system doesn't treat as this app.
    __block NSString *failure = nil;

    // Method 1: NSURLSession download task, with progress.
    {
        NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration ephemeralSessionConfiguration];
        cfg.timeoutIntervalForRequest = 60;
        cfg.timeoutIntervalForResource = 900;
        NSURLSession *session = [NSURLSession sessionWithConfiguration:cfg];
        dispatch_semaphore_t done = dispatch_semaphore_create(0);
        NSURLSessionDownloadTask *task = [session downloadTaskWithURL:[NSURL URLWithString:TI_DOPAMINE_URL]
            completionHandler:^(NSURL *location, NSURLResponse *response, NSError *error) {
                NSInteger status = [response isKindOfClass:[NSHTTPURLResponse class]] ? ((NSHTTPURLResponse *)response).statusCode : 0;
                if (error) failure = error.localizedDescription;
                else if (status != 200) failure = [NSString stringWithFormat:@"The server answered with code %ld.", (long)status];
                else if (![fm moveItemAtPath:location.path toPath:tipa error:nil]) failure = @"Couldn't save the download.";
                dispatch_semaphore_signal(done);
            }];
        [task resume];
        int waitCount = 0;
        while (dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC))) != 0) {
            if (++waitCount > 1200) { [task cancel]; failure = @"Download timed out."; dispatch_semaphore_signal(done); break; }
            double got = task.countOfBytesReceived / 1048576.0, total = task.countOfBytesExpectedToReceive / 1048576.0;
            if (total > 1) step([NSString stringWithFormat:@"Downloading Dopamine  %.0f / %.0f MB", got, total]);
            else if (got > 0) step([NSString stringWithFormat:@"Downloading Dopamine  %.0f MB", got]);
        }
        [session finishTasksAndInvalidate];
    }

    // Method 2: in-memory request.
    if (failure || ![fm fileExistsAtPath:tipa]) {
        NSString *m1 = failure; failure = nil;
        step(@"Downloading Dopamine (retrying)");
        [fm removeItemAtPath:tipa error:nil];
        NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration ephemeralSessionConfiguration];
        cfg.timeoutIntervalForRequest = 60;
        cfg.timeoutIntervalForResource = 900;
        NSURLSession *session = [NSURLSession sessionWithConfiguration:cfg];
        dispatch_semaphore_t done = dispatch_semaphore_create(0);
        NSURLSessionDataTask *task = [session dataTaskWithURL:[NSURL URLWithString:TI_DOPAMINE_URL]
            completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
                NSInteger status = [response isKindOfClass:[NSHTTPURLResponse class]] ? ((NSHTTPURLResponse *)response).statusCode : 0;
                if (error) failure = error.localizedDescription;
                else if (status != 200) failure = [NSString stringWithFormat:@"The server answered with code %ld.", (long)status];
                else if (!data.length || ![data writeToFile:tipa atomically:YES]) failure = @"Couldn't save the download.";
                dispatch_semaphore_signal(done);
            }];
        [task resume];
        dispatch_semaphore_wait(done, DISPATCH_TIME_FOREVER);
        [session finishTasksAndInvalidate];
        if (failure && m1.length) failure = [NSString stringWithFormat:@"%@ / %@", m1, failure];
    }

    // Method 3: curl (a separate process, which iOS doesn't treat as this app).
    if (failure || ![fm fileExistsAtPath:tipa]) {
        NSString *prev = failure; failure = nil;
        NSString *curl = nil;
        for (NSString *c in @[@"/var/jb/usr/bin/curl", @"/usr/bin/curl", @"/usr/local/bin/curl"])
            if ([fm isExecutableFileAtPath:c]) { curl = c; break; }
        if (!curl) {
            failure = [NSString stringWithFormat:@"%@ / curl isn't installed (install the \"curl\" package in Sileo)", prev ?: @""];
        } else {
            step(@"Downloading Dopamine (curl)");
            [fm removeItemAtPath:tipa error:nil];
            NSString *out = nil;
            int code = TISpawnUser(curl, @[@"-L", @"-f", @"-sS", @"--connect-timeout", @"30", @"--max-time", @"600", @"-o", tipa, TI_DOPAMINE_URL], &out);
            if (code != 0 || ![fm fileExistsAtPath:tipa]) {
                NSString *tail = out.length > 160 ? [out substringFromIndex:out.length - 160] : (out ?: @"");
                failure = [NSString stringWithFormat:@"%@ / curl failed (code %d) %@", prev ?: @"", code, tail];
            }
        }
    }

    if ((failure || ![fm fileExistsAtPath:tipa])) { if (problem) *problem = failure ?: @"The download didn't complete."; return nil; }

    // Sanity: a real package is a zip of many megabytes.
    unsigned long long size = [[fm attributesOfItemAtPath:tipa error:nil] fileSize];
    NSFileHandle *fh = [NSFileHandle fileHandleForReadingAtPath:tipa];
    NSData *magic = [fh readDataOfLength:2]; [fh closeFile];
    if (size < 5 * 1048576ULL || magic.length < 2 || memcmp(magic.bytes, "PK", 2) != 0) {
        [fm removeItemAtPath:tipa error:nil];
        if (problem) *problem = @"The download wasn't a valid Dopamine package.";
        return nil;
    }

    step(@"Unpacking Dopamine");
    char zerr[256] = "";
    int rc = tm_extract_zip(tipa.fileSystemRepresentation, outDir.fileSystemRepresentation, zerr, sizeof(zerr));
    [fm removeItemAtPath:tipa error:nil];
    if (rc != 0) { if (problem) *problem = [NSString stringWithFormat:@"Couldn't unpack the download: %s.", zerr]; return nil; }

    NSString *payload = [outDir stringByAppendingPathComponent:@"Payload"];
    for (NSString *item in [fm contentsOfDirectoryAtPath:payload error:nil]) {
        if (![item.pathExtension isEqualToString:@"app"]) continue;
        NSString *app = [payload stringByAppendingPathComponent:item];
        NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:[app stringByAppendingPathComponent:@"Info.plist"]];
        if (![info[@"CFBundleIdentifier"] isEqual:@"com.opa334.Dopamine"]) continue;
        // Version scan: refuse if this device is older than this Dopamine supports.
        NSString *minOS = info[@"MinimumOSVersion"];
        NSString *devOS = [UIDevice currentDevice].systemVersion;
        if ([minOS isKindOfClass:[NSString class]] && [devOS compare:minOS options:NSNumericSearch] == NSOrderedAscending) {
            [fm removeItemAtPath:outDir error:nil];
            if (problem) *problem = [NSString stringWithFormat:@"This device runs iOS %@, but Dopamine %@ needs iOS %@ or newer.", devOS, info[@"CFBundleShortVersionString"] ?: @"", minOS];
            return nil;
        }
        step([NSString stringWithFormat:@"Got Dopamine %@", info[@"CFBundleShortVersionString"] ?: @""]);
        return app;
    }
    [fm removeItemAtPath:outDir error:nil];
    if (problem) *problem = @"The download didn't contain Dopamine.";
    return nil;
}

static NSString *TIBuildAndInstall(void (^step)(NSString *)) {
    NSFileManager *fm = [NSFileManager defaultManager];

    NSString *__block _cleanupWork = nil;
    void (^cleanup)(void) = ^{
        if (!_cleanupWork) return;
        [fm removeItemAtPath:[_cleanupWork stringByAppendingPathComponent:@"staging"] error:nil];
        [fm removeItemAtPath:[_cleanupWork stringByAppendingPathComponent:@"dopamine_dl"] error:nil];
    };

    // Everything else is bundled inside this installer, so TrollStore is not required.
    NSString *signer = TIResource(@"fastPathSign");
    NSString *kit = TIResource(TI_KIT_NAME);
    NSString *bundledHelper = TIResource(@"trollstorehelper");
    NSString *bundledPHelper = TIResource(@"PersistenceHelper");
    NSString *helperEnts = TIResource(@"helper.entitlements");
    NSString *phelperEnts = TIResource(@"phelper.entitlements");
    if (!signer) return @"The signer tool is missing from this installer.";
    if (!kit) return @"The add-on library is missing from this installer.";
    if (!bundledHelper || !helperEnts) return @"The installer engine is missing from this installer.";

    NSString *work = TMWorkDir();
    if (!work) return @"Couldn't find a folder to build in.";
    _cleanupWork = work;

    // Get Dopamine: the latest official build from the internet. If that fails and Dopamine
    // is installed on this device, fall back to the installed copy.
    step(@"Downloading Dopamine");
    NSString *dlProblem = nil;
    NSString *dopamine = TIDownloadDopamine(work, step, &dlProblem);
    BOOL downloaded = (dopamine != nil);
    if (!dopamine) {
        if ([dlProblem hasPrefix:@"This device runs iOS"]) { cleanup(); return dlProblem; }
        dopamine = TMBundlePath(@"com.opa334.Dopamine");
        if (!dopamine) { cleanup(); return [NSString stringWithFormat:@"Couldn't download Dopamine. %@\nCheck your internet connection and try again.", dlProblem ?: @""]; }
        step(@"Download failed \u2014 using the installed Dopamine");
    }

    // Make our own runnable copy of the engine. The installer's bundled copy may have lost its
    // entitlements when the installer itself was signed, so re-sign it with the correct ones.
    step(@"Preparing the engine");
    NSString *helper = [work stringByAppendingPathComponent:@"trollstorehelper"];
    [fm removeItemAtPath:helper error:nil];
    if (![fm copyItemAtPath:bundledHelper toPath:helper error:nil]) { cleanup(); return @"Couldn't stage the installer engine."; }
    chmod(helper.fileSystemRepresentation, 0755);
    NSString *engLog = nil;
    if (tm_sign_file(signer, helper, helperEnts, work, &engLog) != 0) {
        NSString *tail = engLog.length > 200 ? [engLog substringFromIndex:engLog.length - 200] : (engLog ?: @"");
        cleanup(); return [NSString stringWithFormat:@"Couldn't prepare the engine (the signer failed). %@", tail];
    }
    NSString *staging = [work stringByAppendingPathComponent:@"staging"];
    [fm removeItemAtPath:staging error:nil];
    NSString *appDir = [staging stringByAppendingPathComponent:@"Payload/Trollamine.app"];
    if (![fm createDirectoryAtPath:[staging stringByAppendingPathComponent:@"Payload"] withIntermediateDirectories:YES attributes:nil error:nil])
        { cleanup(); return @"Couldn't create the build folder."; }

    // Copy the whole Dopamine app, then make it Trollamine.
    step(@"Copying Dopamine");
    NSError *copyErr = nil;
    if (![fm copyItemAtPath:dopamine toPath:appDir error:&copyErr])
        { cleanup(); return [NSString stringWithFormat:@"Couldn't copy Dopamine. %@", copyErr.localizedDescription ?: @""]; }
    if (downloaded) [fm removeItemAtPath:[work stringByAppendingPathComponent:@"dopamine_dl"] error:nil];
    // A fresh copy must not carry Dopamine's old bundle signature folder.
    [fm removeItemAtPath:[appDir stringByAppendingPathComponent:@"_CodeSignature"] error:nil];

    // --- Info.plist ---
    step(@"Theming");
    NSString *infoPath = [appDir stringByAppendingPathComponent:@"Info.plist"];
    NSMutableDictionary *info = [NSPropertyListSerialization propertyListWithData:[NSData dataWithContentsOfFile:infoPath] options:NSPropertyListMutableContainersAndLeaves format:NULL error:nil];
    if (![info isKindOfClass:[NSMutableDictionary class]]) { cleanup(); return @"Couldn't read Dopamine's Info.plist."; }
    NSString *exeName = info[@"CFBundleExecutable"];
    if (![exeName isKindOfClass:[NSString class]] || !exeName.length) { cleanup(); return @"Dopamine's Info.plist has no program name."; }
    info[@"CFBundleIdentifier"] = TI_APP_ID;
    info[@"CFBundleDisplayName"] = @"Trollamine";
    info[@"CFBundleName"] = @"Trollamine";
    [info removeObjectForKey:@"CFBundleIconName"];
    [info removeObjectForKey:@"CFBundleIconFile"];
    [info removeObjectForKey:@"CFBundleIconFiles"];
    NSDictionary *iconKeys = @{@"CFBundleIcons": @[@"TMIcon29x29", @"TMIcon40x40", @"TMIcon60x60"],
                               @"CFBundleIcons~ipad": @[@"TMIcon29x29", @"TMIcon40x40", @"TMIcon60x60", @"TMIcon76x76", @"TMIcon83.5x83.5"]};
    for (NSString *key in iconKeys) {
        NSMutableDictionary *icons = [info[key] isKindOfClass:[NSDictionary class]] ? [info[key] mutableCopy] : [NSMutableDictionary dictionary];
        icons[@"CFBundlePrimaryIcon"] = @{@"CFBundleIconFiles": iconKeys[key]};
        info[key] = icons;
    }
    // Tell TrollStore's installer engine that every binary is already signed with the
    // CMS SignerInfo bypass (EXPLOIT_TYPE_CMS_SIGNERINFO_V1 = value 2), so it takes
    // the fast path instead of trying to re-sign with ldid (which would fail with code 173).
    info[@"TSPreAppliedExploitType"] = @2;
    NSData *newInfo = [NSPropertyListSerialization dataWithPropertyList:info format:NSPropertyListBinaryFormat_v1_0 options:0 error:nil];
    if (!newInfo || ![newInfo writeToFile:infoPath atomically:YES]) { cleanup(); return @"Couldn't write the new Info.plist."; }

    // --- Theme: add Trollamine as the default theme ---
    NSArray *themes = [NSArray arrayWithContentsOfFile:[appDir stringByAppendingPathComponent:@"Themes.plist"]];
    if ([themes isKindOfClass:[NSArray class]] && themes.count > 0 && [themes.firstObject isKindOfClass:[NSDictionary class]]) {
        // Clone an existing theme so every key this Dopamine version expects is present in the right format;
        // override only the ones we care about. A hand-written dict can crash a version with a different schema.
        NSMutableDictionary *tm = [(NSDictionary *)themes.firstObject mutableCopy];
        tm[@"key"] = @"trollamine";
        tm[@"name"] = @"Trollamine";
        tm[@"image"] = @"Background_Trollamine.jpg";
        if (tm[@"windowColor"]) tm[@"windowColor"] = @"66081226";
        if (tm[@"actionMenuColor"]) tm[@"actionMenuColor"] = @"5F0C3A71";
        NSMutableArray *list = [NSMutableArray arrayWithObject:tm];
        for (id t in themes) { if (!([t isKindOfClass:[NSDictionary class]] && [t[@"key"] isEqual:@"trollamine"])) [list addObject:t]; }
        NSData *themeData = [NSPropertyListSerialization dataWithPropertyList:list format:NSPropertyListXMLFormat_v1_0 options:0 error:nil];
        if (themeData) [themeData writeToFile:[appDir stringByAppendingPathComponent:@"Themes.plist"] atomically:YES];
    }

    // --- Add our files: icons, background, add-on library, installer engine, signer ---
    NSString *res = [NSBundle mainBundle].bundlePath;
    for (NSString *item in [fm contentsOfDirectoryAtPath:res error:nil]) {
        BOOL wanted = [item isEqualToString:@"Background_Trollamine.jpg"] || ([item isEqualToString:@"Boot_Trollamine.png"] || [item isEqualToString:@"Boot_Trollamine_ipad.png"]) || ([item hasPrefix:@"TMIcon"] && [item hasSuffix:@".png"]) || ([item hasPrefix:@"TrollMenuIcon"] && [item hasSuffix:@".png"]);
        if (wanted) [fm copyItemAtPath:[res stringByAppendingPathComponent:item] toPath:[appDir stringByAppendingPathComponent:item] error:nil];
    }
    if (![fm copyItemAtPath:kit toPath:[appDir stringByAppendingPathComponent:TI_KIT_NAME] error:nil]) { cleanup(); return @"Couldn't add the add-on library."; }
    if (signer) [fm copyItemAtPath:signer toPath:[appDir stringByAppendingPathComponent:@"fastPathSign"] error:nil];
    if (![fm copyItemAtPath:bundledHelper toPath:[appDir stringByAppendingPathComponent:@"trollstorehelper"] error:nil]) { cleanup(); return @"Couldn't add the installer engine."; }
    if (bundledPHelper) {
        [fm copyItemAtPath:bundledPHelper toPath:[appDir stringByAppendingPathComponent:@"PersistenceHelper"] error:nil];
        chmod([appDir stringByAppendingPathComponent:@"PersistenceHelper"].fileSystemRepresentation, 0755);
    }
    if (signer) chmod([appDir stringByAppendingPathComponent:@"fastPathSign"].fileSystemRepresentation, 0755);
    chmod([appDir stringByAppendingPathComponent:@"trollstorehelper"].fileSystemRepresentation, 0755);
    // ldid, the signing tool the installer engine uses (the same build TrollStore downloads). The
    // engine looks for it next to itself, so shipping it here means the Apps panel can install
    // apps that need signing without any download.
    NSString *bundledLdid = TIResource(@"ldid");
    if (bundledLdid) {
        NSString *ldidDst = [appDir stringByAppendingPathComponent:@"ldid"];
        if ([fm copyItemAtPath:bundledLdid toPath:ldidDst error:nil]) {
            chmod(ldidDst.fileSystemRepresentation, 0755);
            NSString *ver = TIResource(@"ldid.version");
            if (ver) [fm copyItemAtPath:ver toPath:[appDir stringByAppendingPathComponent:@"ldid.version"] error:nil];
        }
    }

    // --- Patch the main program so it loads the add-on ---
    step(@"Preparing the app");
    char perr[256] = "";
    char *mainEntsXml = NULL;
    if (tm_patch_macho([appDir stringByAppendingPathComponent:exeName].fileSystemRepresentation, TI_KIT_LOAD_PATH, &mainEntsXml, perr, sizeof(perr)) != 0)
        { cleanup(); return [NSString stringWithFormat:@"Couldn't prepare the main program: %s.", perr]; }
    // Patching strips the old signature (and its entitlements). Keep Dopamine's own entitlements
    // so the main program is re-signed WITH them -- without this the engine refuses it (code 173).
    // Also ADD no-sandbox and persona-mgmt: Trollamine's Apps panel runs the bundled signer to
    // install apps, and a sandboxed app can't launch it (iOS kills it with signal 9). These two
    // entitlements let Trollamine run the signer the same way the unsandboxed installer does.
    NSString *mainEntsPath = [work stringByAppendingPathComponent:@"main.entitlements"];
    {
        NSMutableDictionary *ents = nil;
        if (mainEntsXml) {
            NSData *xml = [NSData dataWithBytes:mainEntsXml length:strlen(mainEntsXml)];
            id parsed = [NSPropertyListSerialization propertyListWithData:xml options:NSPropertyListMutableContainersAndLeaves format:NULL error:nil];
            if ([parsed isKindOfClass:[NSDictionary class]]) ents = parsed;
            free(mainEntsXml);
        }
        if (!ents) ents = [NSMutableDictionary dictionary];
        ents[@"com.apple.private.security.no-sandbox"] = @YES;
        ents[@"com.apple.private.persona-mgmt"] = @YES;
        if (!ents[@"platform-application"]) ents[@"platform-application"] = @YES;
        NSData *entsData = [NSPropertyListSerialization dataWithPropertyList:ents format:NSPropertyListXMLFormat_v1_0 options:0 error:nil];
        if (!entsData || ![entsData writeToFile:mainEntsPath atomically:YES]) {
            [fm removeItemAtPath:staging error:nil];
            [fm removeItemAtPath:[work stringByAppendingPathComponent:@"dopamine_dl"] error:nil];
            return @"Couldn't save the main program's entitlements.";
        }
    }

    // --- Sign every Mach-O ourselves (no ldid, no TrollStore) ---
    step(@"Signing (this takes a moment)");
    NSMutableDictionary *explicitEnts = [NSMutableDictionary dictionary];
    explicitEnts[@"trollstorehelper"] = helperEnts;
    explicitEnts[@"PersistenceHelper"] = phelperEnts ?: helperEnts;
    // The signer and ldid are launched as helper tools. Signed with no entitlements they are killed
    // on launch (signal 9) inside the installed app, so give them the engine's entitlements.
    explicitEnts[@"fastPathSign"] = helperEnts;
    explicitEnts[@"ldid"] = helperEnts;
    if (mainEntsPath) explicitEnts[exeName] = mainEntsPath;
    NSString *signErr = tm_sign_app_bundle_ents(appDir, signer, work, explicitEnts);
    if (signErr) { cleanup(); return signErr; }

    step(@"Packaging Trollamine");
    NSString *tipa = [work stringByAppendingPathComponent:@"Trollamine.tipa"];
    NSString *pkgErr = tm_make_tipa(staging, tipa);
    [fm removeItemAtPath:staging error:nil];
    if (pkgErr) { cleanup(); return pkgErr; }

    // --- Install with our own engine (every binary is already signed, so no ldid is needed) ---
    step(@"Installing Trollamine");
    NSString *log = nil;
    int code = TMSpawnRoot(helper, @[@"install", @"installd", @"force", tipa], &log);
    [fm removeItemAtPath:tipa error:nil];
    if (code != 0) {
        NSString *tail = log.length > 300 ? [log substringFromIndex:log.length - 300] : (log ?: @"");
        return [NSString stringWithFormat:@"The installer returned code %d.\n%@", code, tail];
    }
    return nil;
}

#pragma mark - Screen

@interface TIRootController : UIViewController
@end

@implementation TIRootController {
    UILabel *_dopamineLabel;
    UILabel *_trollStoreLabel;
    UILabel *_progress;
    UIButton *_build;
    UIButton *_open;
    BOOL _working;
}

- (UIStatusBarStyle)preferredStatusBarStyle { return UIStatusBarStyleLightContent; }

- (UILabel *)labelWithSize:(CGFloat)size weight:(UIFontWeight)weight alpha:(CGFloat)alpha {
    UILabel *l = [UILabel new];
    l.font = [UIFont systemFontOfSize:size weight:weight];
    l.textColor = [UIColor colorWithWhite:1 alpha:alpha];
    l.numberOfLines = 0;
    return l;
}

- (UIButton *)buttonWithTitle:(NSString *)title action:(SEL)action {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    [b setTitle:title forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont systemFontOfSize:18 weight:UIFontWeightSemibold];
    b.titleLabel.adjustsFontSizeToFitWidth = YES;
    b.titleLabel.minimumScaleFactor = 0.7;
    [b setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    [b setTitleColor:[UIColor colorWithWhite:1 alpha:0.4] forState:UIControlStateDisabled];
    b.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.24];
    b.layer.cornerRadius = 14;
    b.layer.borderWidth = 1;
    b.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.35].CGColor;
    b.contentEdgeInsets = UIEdgeInsetsMake(0, 10, 0, 10);
    [b addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    [b.heightAnchor constraintEqualToConstant:54].active = YES;
    return b;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor colorWithWhite:0.25 alpha:1];

    UIImageView *bg = [[UIImageView alloc] initWithImage:[UIImage imageNamed:@"Background_Trollamine.jpg"]];
    bg.contentMode = UIViewContentModeScaleAspectFill;
    bg.clipsToBounds = YES;
    bg.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:bg];

    UILabel *title = [self labelWithSize:34 weight:UIFontWeightHeavy alpha:1];
    title.text = @"Trollamine Installer";
    title.textAlignment = NSTextAlignmentCenter;
    title.numberOfLines = 1;
    title.adjustsFontSizeToFitWidth = YES;
    title.minimumScaleFactor = 0.6;
    UILabel *tagline = [self labelWithSize:15 weight:UIFontWeightMedium alpha:0.8];
    tagline.text = @"Downloads Dopamine and builds Trollamine \u2014 no TrollStore needed";
    tagline.textAlignment = NSTextAlignmentCenter;
    UIStackView *header = [[UIStackView alloc] initWithArrangedSubviews:@[title, tagline]];
    header.axis = UILayoutConstraintAxisVertical;
    header.spacing = 6;
    header.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:header];

    UIVisualEffectView *panel = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemUltraThinMaterialDark]];
    panel.layer.cornerRadius = 22;
    panel.layer.masksToBounds = YES;
    panel.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:panel];

    _dopamineLabel = [self labelWithSize:15 weight:UIFontWeightSemibold alpha:1];
    _trollStoreLabel = [self labelWithSize:15 weight:UIFontWeightSemibold alpha:1];
    UILabel *explain = [self labelWithSize:13 weight:UIFontWeightRegular alpha:0.8];
    explain.text = @"Trollamine is your Dopamine with the Trollamine theme, plus a TrollStore-style Apps panel. The installer downloads the latest official Dopamine (about 55 MB, needs internet) and carries its own installer engine and signer. An installed Dopamine is not changed.";
    _progress = [self labelWithSize:14 weight:UIFontWeightMedium alpha:0.95];
    _progress.textAlignment = NSTextAlignmentCenter;
    _progress.text = @"";
    _build = [self buttonWithTitle:@"Build and Install Trollamine" action:@selector(buildTapped)];
    _open = [self buttonWithTitle:@"Open Trollamine" action:@selector(openTapped)];
    _open.hidden = YES;

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[_dopamineLabel, _trollStoreLabel, explain, _progress, _build, _open]];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 12;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [panel.contentView addSubview:stack];

    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    NSLayoutConstraint *panelWidth = [panel.widthAnchor constraintEqualToAnchor:safe.widthAnchor constant:-40];
    panelWidth.priority = UILayoutPriorityDefaultHigh;
    [NSLayoutConstraint activateConstraints:@[
        [bg.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [bg.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [bg.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [bg.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [header.topAnchor constraintEqualToAnchor:safe.topAnchor constant:32],
        [header.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:20],
        [header.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-20],
        [panel.centerXAnchor constraintEqualToAnchor:safe.centerXAnchor],
        panelWidth,
        [panel.widthAnchor constraintLessThanOrEqualToConstant:460],
        [panel.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor constant:-28],
        [panel.topAnchor constraintGreaterThanOrEqualToAnchor:header.bottomAnchor constant:16],
        [stack.topAnchor constraintEqualToAnchor:panel.contentView.topAnchor constant:18],
        [stack.bottomAnchor constraintEqualToAnchor:panel.contentView.bottomAnchor constant:-18],
        [stack.leadingAnchor constraintEqualToAnchor:panel.contentView.leadingAnchor constant:16],
        [stack.trailingAnchor constraintEqualToAnchor:panel.contentView.trailingAnchor constant:-16],
    ]];

    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(refresh) name:UIApplicationDidBecomeActiveNotification object:nil];
    [self refresh];
}

- (NSString *)versionAt:(NSString *)bundlePath {
    NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:[bundlePath stringByAppendingPathComponent:@"Info.plist"]];
    NSString *v = info[@"CFBundleShortVersionString"];
    return [v isKindOfClass:[NSString class]] ? v : @"?";
}

- (void)refresh {
    if (_working) return;
    NSString *dop = TMBundlePath(@"com.opa334.Dopamine");
    (void)0;
    _dopamineLabel.text = dop ? [NSString stringWithFormat:@"Dopamine: downloads latest (installed: %@)", [self versionAt:dop]] : @"Dopamine: downloads the latest official build";
    _trollStoreLabel.text = TIResource(@"trollstorehelper") ? @"Engine + signer: bundled" : @"Engine missing from installer";
    _build.enabled = YES;
    NSString *existing = TMBundlePath(TI_APP_ID);
    _open.hidden = (existing == nil);
    if (existing) [_build setTitle:@"Rebuild Trollamine" forState:UIControlStateNormal];
}

- (void)buildTapped {
    _build.enabled = NO;
    if (_working) return;
    _working = YES;
    _progress.text = @"Starting";
    [UIApplication sharedApplication].idleTimerDisabled = YES;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        UIBackgroundTaskIdentifier bgTask = [[UIApplication sharedApplication] beginBackgroundTaskWithExpirationHandler:nil];
        NSString *problem = TIBuildAndInstall(^(NSString *text) {
            dispatch_async(dispatch_get_main_queue(), ^{ self->_progress.text = text; });
        });
        dispatch_async(dispatch_get_main_queue(), ^{
            [UIApplication sharedApplication].idleTimerDisabled = NO;
            self->_working = NO;
            self->_progress.text = problem ? @"" : @"Trollamine is installed";
            [self refresh];
            if (bgTask != UIBackgroundTaskInvalid) [[UIApplication sharedApplication] endBackgroundTask:bgTask];
            if (problem) TMAlert(self, @"Something went wrong", problem);
            else TMAlert(self, @"Trollamine installed", @"Look for Trollamine on your home screen. Keep your original Dopamine installed as a fallback.");
        });
    });
}

- (void)openTapped {
    if (!TMOpenApp(TI_APP_ID)) TMAlert(self, @"Couldn't open Trollamine", @"Try opening it from the home screen.");
}

@end

@interface TIAppDelegate : UIResponder <UIApplicationDelegate>
@property (nonatomic, strong) UIWindow *window;
@end

@implementation TIAppDelegate
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    self.window.rootViewController = [TIRootController new];
    [self.window makeKeyAndVisible];
    return YES;
}
@end

int main(int argc, char *argv[]) {
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass([TIAppDelegate class]));
    }
}
