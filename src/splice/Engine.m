// Splice engine. Everything runs in-process (libarchive + our Mach-O patcher), so Splice works
// as a sandboxed TrollStore/sideloaded app too. On a jailbreak it can also fall back to dpkg-deb.
#import "Engine.h"
#import "machopatch.h"
#import <dlfcn.h>
#import <spawn.h>
#import <sys/wait.h>
#import <sys/stat.h>
#import <unistd.h>
#import <fcntl.h>

#ifndef JBROOT
#define JBROOT ""
#endif

extern char **environ;

#pragma mark - libarchive (ships with iOS; the SDK has no header, so declare what we use)

struct archive; struct archive_entry;
#define ARCHIVE_OK 0
#define ARCHIVE_EOF 1
#define ARCHIVE_WARN (-20)
#define AE_IFMT  0170000
#define AE_IFREG 0100000
#define AE_IFLNK 0120000
#define AE_IFDIR 0040000
struct archive *archive_read_new(void);
int archive_read_support_filter_all(struct archive *);
int archive_read_support_format_all(struct archive *);
int archive_read_support_format_ar(struct archive *);
int archive_read_open_filename(struct archive *, const char *, size_t);
int archive_read_open_memory(struct archive *, const void *, size_t);
int archive_read_next_header(struct archive *, struct archive_entry **);
ssize_t archive_read_data(struct archive *, void *, size_t);
int archive_read_free(struct archive *);
const char *archive_error_string(struct archive *);
const char *archive_entry_pathname(struct archive_entry *);
mode_t archive_entry_filetype(struct archive_entry *);
mode_t archive_entry_perm(struct archive_entry *);
const char *archive_entry_symlink(struct archive_entry *);
struct archive *archive_write_new(void);
int archive_write_set_format_zip(struct archive *);
int archive_write_zip_set_compression_deflate(struct archive *);
int archive_write_zip_set_compression_store(struct archive *);
int archive_write_open_filename(struct archive *, const char *);
int archive_write_header(struct archive *, struct archive_entry *);
ssize_t archive_write_data(struct archive *, const void *, size_t);
int archive_write_finish_entry(struct archive *);
int archive_write_close(struct archive *);
int archive_write_free(struct archive *);
struct archive_entry *archive_entry_new(void);
void archive_entry_free(struct archive_entry *);
void archive_entry_set_pathname(struct archive_entry *, const char *);
void archive_entry_set_size(struct archive_entry *, int64_t);
void archive_entry_set_filetype(struct archive_entry *, unsigned int);
void archive_entry_set_perm(struct archive_entry *, mode_t);
void archive_entry_set_symlink(struct archive_entry *, const char *);
void archive_entry_set_mtime(struct archive_entry *, time_t, long);

static NSError *SPErr(NSString *msg) {
    return [NSError errorWithDomain:@"Splice" code:1 userInfo:@{NSLocalizedDescriptionKey: msg}];
}

#pragma mark - Paths

static NSString *SPBaseDir(void) {
    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    // Unsandboxed (jailbreak .deb) installs share /var/mobile/Documents, so keep to our own folder.
    if ([NSHomeDirectory() isEqualToString:@"/var/mobile"]) docs = [docs stringByAppendingPathComponent:@"Splice"];
    return docs;
}

// Some installs (e.g. the jailbreak .deb, depending on the jailbreak) can't write to every folder iOS
// hands them, so try a few and keep the first one where a real file write works.
static BOOL CanWrite(NSString *dir) {
    if (!dir.length) return NO;
    [NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *probe = [dir stringByAppendingPathComponent:[@".probe-" stringByAppendingString:NSUUID.UUID.UUIDString]];
    FILE *f = fopen(probe.fileSystemRepresentation, "wb");
    if (!f) return NO;
    BOOL ok = fwrite("splice", 1, 6, f) == 6;
    fclose(f);
    unlink(probe.fileSystemRepresentation);
    return ok;
}

static NSString *FirstWritable(NSArray<NSString *> *candidates) {
    for (NSString *c in candidates) if (CanWrite(c)) return c;
    return candidates.firstObject;
}

static NSString *CachesDir(void) {
    return NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES).firstObject ?: @"";
}

NSString *SPWorkRoot(void) {
    static NSString *root;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        root = FirstWritable(@[
            [NSTemporaryDirectory() stringByAppendingPathComponent:@"SpliceWork"],
            [CachesDir() stringByAppendingPathComponent:@"SpliceWork"],
            [SPBaseDir() stringByAppendingPathComponent:@".SpliceWork"],
            @"/var/mobile/Library/Caches/com.mymculture.splice/Work",
            @"/var/mobile/Documents/Splice/.work",
            @JBROOT "/var/mobile/Splice/work",
        ]);
        NSLog(@"[Splice] work folder: %@", root);
    });
    [NSFileManager.defaultManager createDirectoryAtPath:root withIntermediateDirectories:YES attributes:nil error:nil];
    return root;
}

NSString *SPBuildsDir(void) {
    static NSString *dir;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        dir = FirstWritable(@[
            [SPBaseDir() stringByAppendingPathComponent:@"Modded Apps"],
            @"/var/mobile/Documents/Splice/Modded Apps",
            [CachesDir() stringByAppendingPathComponent:@"Modded Apps"],
            @"/var/mobile/Library/Splice/Modded Apps",
        ]);
    });
    [NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    return dir;
}

// Plain byte copy: unlike copyItemAtURL it doesn't try to carry over the source's owner, ACLs or
// file-protection class, which other apps' files can refuse.
static BOOL StreamCopy(NSURL *src, NSString *dst, NSError **err) {
    NSInputStream *in = [NSInputStream inputStreamWithURL:src];
    [in open];
    if (in.streamStatus == NSStreamStatusError || !in) {
        if (err) *err = SPErr([NSString stringWithFormat:@"can't read the file (%@)", in.streamError.localizedDescription ?: @"no access"]);
        return NO;
    }
    FILE *f = fopen(dst.fileSystemRepresentation, "wb");
    if (!f) {
        [in close];
        if (err) *err = SPErr([NSString stringWithFormat:@"can't write to %@ (%s)", dst.stringByDeletingLastPathComponent, strerror(errno)]);
        return NO;
    }
    uint8_t *buf = malloc(1 << 20);
    BOOL ok = YES;
    NSInteger n;
    while ((n = [in read:buf maxLength:1 << 20]) > 0) {
        if (fwrite(buf, 1, (size_t)n, f) != (size_t)n) {
            ok = NO;
            if (err) *err = SPErr([NSString stringWithFormat:@"can't write to %@ (%s)", dst.stringByDeletingLastPathComponent, strerror(errno)]);
            break;
        }
    }
    if (ok && n < 0) { ok = NO; if (err) *err = SPErr([NSString stringWithFormat:@"reading stopped (%@)", in.streamError.localizedDescription ?: @"?"]); }
    free(buf);
    fclose(f);
    [in close];
    if (!ok) unlink(dst.fileSystemRepresentation);
    return ok;
}

NSString *SPStashURL(NSURL *url, NSError **err) {
    if ([url.path hasPrefix:SPWorkRoot()]) return url.path;   // already our own copy (drop/download)
    BOOL scoped = [url startAccessingSecurityScopedResource];
    NSString *dir = [SPWorkRoot() stringByAppendingPathComponent:[@"in-" stringByAppendingString:NSUUID.UUID.UUIDString]];
    [NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *dst = [dir stringByAppendingPathComponent:url.lastPathComponent ?: @"file"];
    // A coordinated read gets access to files in other apps' storage and downloads iCloud files first.
    __block BOOL ok = NO;
    __block NSError *copyErr = nil;
    NSError *coordErr = nil;
    [[[NSFileCoordinator alloc] initWithFilePresenter:nil] coordinateReadingItemAtURL:url options:NSFileCoordinatorReadingWithoutChanges
                                                                               error:&coordErr byAccessor:^(NSURL *u) {
        NSError *e = nil;
        ok = StreamCopy(u, dst, &e);
        if (!ok) {
            copyErr = e;
            ok = [NSFileManager.defaultManager copyItemAtURL:u toURL:[NSURL fileURLWithPath:dst] error:nil];
        }
    }];
    if (!ok) {
        NSError *e = nil;
        ok = StreamCopy(url, dst, &e);
        if (!ok && !copyErr) copyErr = e ?: coordErr;
    }
    if (scoped) [url stopAccessingSecurityScopedResource];
    if (!ok) {
        [NSFileManager.defaultManager removeItemAtPath:dir error:nil];
        if (err) *err = SPErr([NSString stringWithFormat:@"Couldn't copy %@: %@.",
                               url.lastPathComponent, copyErr.localizedDescription ?: @"no access"]);
        return nil;
    }
    return dst;
}

static NSString *NewWorkDir(NSString *tag) {
    NSString *p = [SPWorkRoot() stringByAppendingPathComponent:[NSString stringWithFormat:@"%@-%@", tag, NSUUID.UUID.UUIDString]];
    [NSFileManager.defaultManager createDirectoryAtPath:p withIntermediateDirectories:YES attributes:nil error:nil];
    return p;
}

#pragma mark - Safe extraction

// Entry names come from untrusted archives: no absolute paths, no "..", nothing through a symlink.
static NSString *SafeJoin(NSString *root, const char *name) {
    if (!name || !*name) return nil;
    NSString *rel = @(name);
    if (!rel) return nil;
    while ([rel hasPrefix:@"./"]) rel = [rel substringFromIndex:2];
    if ([rel hasPrefix:@"/"] || !rel.length || [rel isEqualToString:@"."]) return nil;
    for (NSString *c in rel.pathComponents) if ([c isEqualToString:@".."]) return nil;
    return [root stringByAppendingPathComponent:rel];
}

static BOOL ParentInside(NSString *root, NSString *path) {
    char a[PATH_MAX], b[PATH_MAX];
    if (!realpath(root.fileSystemRepresentation, a)) return NO;
    if (!realpath(path.stringByDeletingLastPathComponent.fileSystemRepresentation, b)) return NO;
    size_t n = strlen(a);
    return strncmp(a, b, n) == 0 && (b[n] == 0 || b[n] == '/');
}

typedef BOOL (^SPEntryFilter)(NSString *name);

static BOOL ExtractOpen(struct archive *a, NSString *dest, SPProgress progress, uint64_t totalHint, NSError **err) {
    NSFileManager *fm = NSFileManager.defaultManager;
    [fm createDirectoryAtPath:dest withIntermediateDirectories:YES attributes:nil error:nil];
    struct archive_entry *e;
    char *buf = malloc(1 << 20);
    uint64_t done = 0;
    int r;
    BOOL ok = YES;
    while ((r = archive_read_next_header(a, &e)) == ARCHIVE_OK || r == ARCHIVE_WARN) {
        NSString *path = SafeJoin(dest, archive_entry_pathname(e));
        if (!path) continue;
        mode_t type = archive_entry_filetype(e) & AE_IFMT;
        if (type == AE_IFDIR) {
            [fm createDirectoryAtPath:path withIntermediateDirectories:YES attributes:nil error:nil];
            continue;
        }
        [fm createDirectoryAtPath:path.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil];
        if (!ParentInside(dest, path)) continue;
        if (type == AE_IFLNK) {
            const char *target = archive_entry_symlink(e);
            // Only relative links that stay inside (framework Versions/Current style).
            if (target && target[0] != '/' && !strstr(target, "..")) {
                unlink(path.fileSystemRepresentation);
                symlink(target, path.fileSystemRepresentation);
            }
            continue;
        }
        if (type != AE_IFREG) continue;
        unlink(path.fileSystemRepresentation);
        mode_t perm = archive_entry_perm(e) & 0777;
        int fd = open(path.fileSystemRepresentation, O_WRONLY | O_CREAT | O_TRUNC | O_NOFOLLOW, (perm & 0111) ? 0755 : 0644);
        if (fd < 0) { ok = NO; if (err) *err = SPErr([NSString stringWithFormat:@"Couldn't write %@.", path.lastPathComponent]); break; }
        ssize_t n;
        while ((n = archive_read_data(a, buf, 1 << 20)) > 0) {
            if (write(fd, buf, (size_t)n) != n) { n = -1; break; }
            done += (uint64_t)n;
            if (progress && totalHint) progress(@"Unpacking", MIN(1.0, (double)done / (double)totalHint));
        }
        close(fd);
        if (n < 0) {
            ok = NO;
            if (err) *err = SPErr([NSString stringWithFormat:@"Couldn't unpack %@: %s", path.lastPathComponent, archive_error_string(a) ?: "out of space?"]);
            break;
        }
    }
    if (ok && r != ARCHIVE_EOF) {
        ok = NO;
        if (err) *err = SPErr([NSString stringWithFormat:@"The archive is damaged or in a format Splice can't read (%s).", archive_error_string(a) ?: "unknown error"]);
    }
    free(buf);
    return ok;
}

static BOOL ExtractFile(NSString *file, NSString *dest, SPProgress progress, NSError **err) {
    struct archive *a = archive_read_new();
    archive_read_support_filter_all(a);
    archive_read_support_format_all(a);
    if (archive_read_open_filename(a, file.fileSystemRepresentation, 1 << 16) != ARCHIVE_OK) {
        if (err) *err = SPErr([NSString stringWithFormat:@"Couldn't open %@ (%s).", file.lastPathComponent, archive_error_string(a) ?: "?"]);
        archive_read_free(a);
        return NO;
    }
    uint64_t size = [[NSFileManager.defaultManager attributesOfItemAtPath:file error:nil] fileSize];
    // Unpacked size is usually ~1.5-2.5x the .ipa; good enough for a progress bar.
    BOOL ok = ExtractOpen(a, dest, progress, size * 2, err);
    archive_read_free(a);
    return ok;
}

static BOOL ExtractData(NSData *data, NSString *dest, NSError **err) {
    struct archive *a = archive_read_new();
    archive_read_support_filter_all(a);
    int (*zstd)(struct archive *) = dlsym(RTLD_DEFAULT, "archive_read_support_filter_zstd");
    if (zstd) zstd(a);
    archive_read_support_format_all(a);
    if (archive_read_open_memory(a, data.bytes, data.length) != ARCHIVE_OK) {
        if (err) *err = SPErr([NSString stringWithFormat:@"%s", archive_error_string(a) ?: "unreadable archive"]);
        archive_read_free(a);
        return NO;
    }
    BOOL ok = ExtractOpen(a, dest, nil, 0, err);
    archive_read_free(a);
    return ok;
}

#pragma mark - zstd (newer .debs) - libarchive on iOS has no zstd, so use libzstd when we can reach it

typedef struct { const void *src; size_t size; size_t pos; } ZIn;
typedef struct { void *dst; size_t size; size_t pos; } ZOut;

static NSData *Unzstd(NSData *in) {
    static void *lib;
    if (!lib) {
        for (NSString *p in @[@JBROOT "/usr/lib/libzstd.1.dylib", @"/var/jb/usr/lib/libzstd.1.dylib", @"/usr/lib/libzstd.1.dylib", @"/usr/local/lib/libzstd.1.dylib"]) {
            if ((lib = dlopen(p.fileSystemRepresentation, RTLD_NOW))) break;
        }
    }
    if (!lib) return nil;
    void *(*create)(void) = dlsym(lib, "ZSTD_createDStream");
    size_t (*init)(void *) = dlsym(lib, "ZSTD_initDStream");
    size_t (*dec)(void *, ZOut *, ZIn *) = dlsym(lib, "ZSTD_decompressStream");
    unsigned (*isErr)(size_t) = dlsym(lib, "ZSTD_isError");
    size_t (*freeS)(void *) = dlsym(lib, "ZSTD_freeDStream");
    if (!create || !init || !dec || !isErr || !freeS) return nil;
    void *ds = create();
    init(ds);
    NSMutableData *out = [NSMutableData data];
    uint8_t *chunk = malloc(1 << 20);
    ZIn zi = { in.bytes, in.length, 0 };
    BOOL ok = YES;
    while (zi.pos < zi.size) {
        ZOut zo = { chunk, 1 << 20, 0 };
        size_t r = dec(ds, &zo, &zi);
        if (isErr(r)) { ok = NO; break; }
        [out appendBytes:chunk length:zo.pos];
        if (r == 0 && zi.pos >= zi.size) break;
    }
    free(chunk);
    freeS(ds);
    return ok ? out : nil;
}

static NSString *FindTool(NSString *name) {
    for (NSString *dir in @[@"/usr/bin", @"/usr/local/bin", @"/bin"]) {
        NSString *p = [@JBROOT stringByAppendingPathComponent:[dir stringByAppendingPathComponent:name]];
        if ([NSFileManager.defaultManager isExecutableFileAtPath:p]) return p;
    }
    return nil;
}

static int Run(NSString *tool, NSArray<NSString *> *args) {
    NSMutableArray *all = [NSMutableArray arrayWithObject:tool];
    [all addObjectsFromArray:args];
    char **argv = calloc(all.count + 1, sizeof(char *));
    for (NSUInteger i = 0; i < all.count; i++) argv[i] = strdup([all[i] UTF8String]);
    pid_t pid = 0;
    int rc = posix_spawn(&pid, argv[0], NULL, NULL, argv, environ), st = -1;
    if (rc == 0) { waitpid(pid, &st, 0); st = WIFEXITED(st) ? WEXITSTATUS(st) : -1; }
    for (NSUInteger i = 0; i < all.count; i++) free(argv[i]);
    free(argv);
    return rc == 0 ? st : -1;
}

#pragma mark - SPApp

static NSString *FindAppBundle(NSString *dir) {
    NSString *payload = [dir stringByAppendingPathComponent:@"Payload"];
    for (NSString *n in [NSFileManager.defaultManager contentsOfDirectoryAtPath:payload error:nil])
        if ([n.pathExtension isEqualToString:@"app"]) return [payload stringByAppendingPathComponent:n];
    return nil;
}

static UIImage *FindIcon(NSString *appPath, NSDictionary *info) {
    NSMutableArray *bases = [NSMutableArray array];
    for (NSString *key in @[@"CFBundleIcons", @"CFBundleIcons~ipad"]) {
        NSDictionary *primary = info[key][@"CFBundlePrimaryIcon"];
        if (![primary isKindOfClass:NSDictionary.class]) continue;
        id files = primary[@"CFBundleIconFiles"];
        if ([files isKindOfClass:NSArray.class]) [bases addObjectsFromArray:files];
        if ([primary[@"CFBundleIconName"] isKindOfClass:NSString.class]) [bases addObject:primary[@"CFBundleIconName"]];
    }
    if ([info[@"CFBundleIconFiles"] isKindOfClass:NSArray.class]) [bases addObjectsFromArray:info[@"CFBundleIconFiles"]];
    if ([info[@"CFBundleIconFile"] isKindOfClass:NSString.class]) [bases addObject:info[@"CFBundleIconFile"]];
    [bases addObject:@"AppIcon"];
    [bases addObject:@"Icon"];
    NSString *best = nil; unsigned long long bestSize = 0;
    NSFileManager *fm = NSFileManager.defaultManager;
    for (NSString *f in [fm contentsOfDirectoryAtPath:appPath error:nil]) {
        if (![f.pathExtension.lowercaseString isEqualToString:@"png"]) continue;
        for (NSString *b in bases) {
            if (![f hasPrefix:b.stringByDeletingPathExtension]) continue;
            NSString *full = [appPath stringByAppendingPathComponent:f];
            unsigned long long s = [[fm attributesOfItemAtPath:full error:nil] fileSize];
            if (s > bestSize) { bestSize = s; best = full; }
        }
    }
    return best ? [UIImage imageWithContentsOfFile:best] : nil;
}

@implementation SPApp

+ (instancetype)importIPA:(NSString *)ipaPath error:(NSError **)err {
    NSString *dir = NewWorkDir(@"app");
    if (!ExtractFile(ipaPath, dir, nil, err)) {
        [NSFileManager.defaultManager removeItemAtPath:dir error:nil];
        return nil;
    }
    NSString *appPath = FindAppBundle(dir);
    NSDictionary *info = appPath ? [NSDictionary dictionaryWithContentsOfFile:[appPath stringByAppendingPathComponent:@"Info.plist"]] : nil;
    if (!info) {
        [NSFileManager.defaultManager removeItemAtPath:dir error:nil];
        if (err) *err = SPErr(@"That file isn't an app. Pick a decrypted .ipa (it needs a Payload folder with an .app inside).");
        return nil;
    }
    SPApp *app = [SPApp new];
    app.dir = dir;
    app.appPath = appPath;
    app.executable = info[@"CFBundleExecutable"] ?: appPath.lastPathComponent.stringByDeletingPathExtension;
    app.name = info[@"CFBundleDisplayName"] ?: info[@"CFBundleName"] ?: app.executable;
    app.bundleID = info[@"CFBundleIdentifier"] ?: @"?";
    app.version = info[@"CFBundleShortVersionString"] ?: info[@"CFBundleVersion"] ?: @"";
    app.icon = FindIcon(appPath, info);
    NSString *exe = [appPath stringByAppendingPathComponent:app.executable];
    app.encrypted = mp_is_encrypted(exe.fileSystemRepresentation) != 0;
    NSString *fw = [appPath stringByAppendingPathComponent:@"Frameworks"];
    app.existingTweaks = [NSFileManager.defaultManager fileExistsAtPath:[fw stringByAppendingPathComponent:@"CydiaSubstrate.framework"]] ? 1 : 0;
    return app;
}

- (void)dealloc {
    if (_dir) [NSFileManager.defaultManager removeItemAtPath:_dir error:nil];
}

@end

#pragma mark - SPTweak

static NSDictionary *ParseControl(NSString *text) {
    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    NSString *last = nil;
    for (NSString *line in [text componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]) {
        if (!line.length) continue;
        if (([line hasPrefix:@" "] || [line hasPrefix:@"\t"]) && last) continue;   // continuation lines
        NSRange r = [line rangeOfString:@":"];
        if (r.location == NSNotFound) continue;
        last = [[line substringToIndex:r.location] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        d[last] = [[line substringFromIndex:r.location + 1] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    }
    return d;
}

static NSArray *JBLibraryNames(void) {
    return @[@"CydiaSubstrate", @"libsubstrate", @"libsubstitute", @"libellekit", @"ellekit", @"libhooker", @"libblackjack", @"libroot"];
}
static BOOL IsHookingLibrary(NSString *path) {
    for (NSString *n in JBLibraryNames()) if ([path rangeOfString:n options:NSCaseInsensitiveSearch].location != NSNotFound) return YES;
    return NO;
}

@implementation SPTweak

+ (instancetype)importFile:(NSString *)path error:(NSError **)err {
    NSString *ext = path.pathExtension.lowercaseString;
    NSString *dir = NewWorkDir(@"tweak");
    NSFileManager *fm = NSFileManager.defaultManager;
    SPTweak *t = [SPTweak new];
    t.dir = dir;
    t.fileName = path.lastPathComponent;
    NSDictionary *control = nil;

    if ([ext isEqualToString:@"dylib"]) {
        if (!mp_is_macho(path.fileSystemRepresentation)) { if (err) *err = SPErr(@"That .dylib isn't a valid library."); return nil; }
        NSString *dst = [dir stringByAppendingPathComponent:@"Library/MobileSubstrate/DynamicLibraries"];
        [fm createDirectoryAtPath:dst withIntermediateDirectories:YES attributes:nil error:nil];
        [fm copyItemAtPath:path toPath:[dst stringByAppendingPathComponent:path.lastPathComponent] error:nil];
    } else if ([ext isEqualToString:@"deb"]) {
        // .deb = ar archive: debian-binary, control.tar.*, data.tar.*
        struct archive *a = archive_read_new();
        archive_read_support_format_ar(a);
        if (archive_read_open_filename(a, path.fileSystemRepresentation, 1 << 16) != ARCHIVE_OK) {
            archive_read_free(a);
            if (err) *err = SPErr(@"That .deb is damaged.");
            return nil;
        }
        NSMutableData *dataTar = nil, *controlTar = nil;
        NSString *dataName = nil;
        struct archive_entry *e;
        int r;
        while ((r = archive_read_next_header(a, &e)) == ARCHIVE_OK || r == ARCHIVE_WARN) {
            NSString *n = @(archive_entry_pathname(e) ?: "");
            NSMutableData *target = nil;
            if ([n hasPrefix:@"data.tar"]) { target = dataTar = [NSMutableData data]; dataName = n; }
            else if ([n hasPrefix:@"control.tar"]) target = controlTar = [NSMutableData data];
            if (!target) continue;
            char buf[65536]; ssize_t k;
            while ((k = archive_read_data(a, buf, sizeof buf)) > 0) [target appendBytes:buf length:(NSUInteger)k];
        }
        archive_read_free(a);
        if (!dataTar) { if (err) *err = SPErr(@"That .deb has no files in it."); return nil; }

        NSString *ctlDir = [dir stringByAppendingPathComponent:@".control"];
        if (controlTar) {
            NSData *raw = controlTar;
            if (!ExtractData(raw, ctlDir, nil)) {
                NSData *plain = Unzstd(raw);
                if (plain) ExtractData(plain, ctlDir, nil);
            }
            NSString *ctl = [NSString stringWithContentsOfFile:[ctlDir stringByAppendingPathComponent:@"control"] encoding:NSUTF8StringEncoding error:nil];
            if (ctl) control = ParseControl(ctl);
        }
        NSError *de = nil;
        BOOL ok = ExtractData(dataTar, dir, &de);
        if (!ok) {
            NSData *plain = Unzstd(dataTar);
            if (plain) ok = ExtractData(plain, dir, &de);
        }
        if (!ok) {
            NSString *dpkg = FindTool(@"dpkg-deb");
            if (dpkg && Run(dpkg, @[@"-x", path, dir]) == 0) ok = YES;
        }
        if (!ok) {
            [fm removeItemAtPath:dir error:nil];
            if (err) *err = SPErr([dataName hasSuffix:@".zst"]
                ? @"This .deb is compressed with zstd, which Splice can't unpack here. Open the .deb in Filza, take the .dylib from Library/MobileSubstrate/DynamicLibraries and add that instead."
                : [NSString stringWithFormat:@"Couldn't unpack that .deb: %@", de.localizedDescription]);
            return nil;
        }
    } else {
        [fm removeItemAtPath:dir error:nil];
        if (err) *err = SPErr(@"Tweaks need to be a .deb or a .dylib.");
        return nil;
    }

    // Find what's in it.
    NSMutableArray *dylibs = [NSMutableArray array], *libs = [NSMutableArray array], *fws = [NSMutableArray array], *bundles = [NSMutableArray array];
    NSDirectoryEnumerator *en = [fm enumeratorAtPath:dir];
    for (NSString *rel in en) {
        if ([rel hasPrefix:@".control"]) { [en skipDescendants]; continue; }
        NSString *full = [dir stringByAppendingPathComponent:rel];
        NSString *ext2 = rel.pathExtension.lowercaseString;
        if ([ext2 isEqualToString:@"framework"]) {
            if (![rel.lastPathComponent isEqualToString:@"CydiaSubstrate.framework"]) [fws addObject:full];
            [en skipDescendants];
        } else if ([ext2 isEqualToString:@"bundle"]) {
            // Resource bundles; Settings panes (PreferenceBundles) can't work inside an app.
            if ([rel rangeOfString:@"PreferenceBundles"].location == NSNotFound) [bundles addObject:full];
            [en skipDescendants];
        } else if ([ext2 isEqualToString:@"dylib"]) {
            BOOL injected = [rel rangeOfString:@"MobileSubstrate/DynamicLibraries"].location != NSNotFound ||
                            [rel rangeOfString:@"TweakInject"].location != NSNotFound;
            if (injected) [dylibs addObject:full];
            else if (!IsHookingLibrary(rel.lastPathComponent)) [libs addObject:full];
        }
    }
    if (!dylibs.count) {
        [fm removeItemAtPath:dir error:nil];
        if (err) *err = SPErr(@"No tweak inside. Splice looks for .dylibs in Library/MobileSubstrate/DynamicLibraries - this package may be a theme, a Settings-only add-on or a SpringBoard tool.");
        return nil;
    }
    t.dylibs = dylibs; t.libraries = libs; t.frameworks = fws; t.bundles = bundles;
    t.packageID = control[@"Package"] ?: @"";
    t.name = control[@"Name"] ?: ([path.pathExtension.lowercaseString isEqualToString:@"dylib"]
                                  ? path.lastPathComponent.stringByDeletingPathExtension
                                  : (t.packageID.length ? t.packageID : path.lastPathComponent.stringByDeletingPathExtension));
    t.version = control[@"Version"] ?: @"";
    t.depends = control[@"Depends"] ?: @"";
    return t;
}

- (NSArray<NSString *> *)dylibsForApp:(SPApp *)app skipped:(NSArray<NSString *> **)skipped {
    NSMutableArray *use = [NSMutableArray array], *skip = [NSMutableArray array];
    NSSet *generic = [NSSet setWithArray:@[@"com.apple.UIKit", @"com.apple.Foundation", @"com.apple.CoreFoundation", @"com.apple.uikit"]];
    for (NSString *d in self.dylibs) {
        NSDictionary *plist = [NSDictionary dictionaryWithContentsOfFile:[d.stringByDeletingPathExtension stringByAppendingPathExtension:@"plist"]];
        NSDictionary *filter = plist[@"Filter"];
        if (![filter isKindOfClass:NSDictionary.class] || !app) { [use addObject:d]; continue; }
        NSArray *b = [filter[@"Bundles"] isKindOfClass:NSArray.class] ? filter[@"Bundles"] : @[];
        NSArray *x = [filter[@"Executables"] isKindOfClass:NSArray.class] ? filter[@"Executables"] : @[];
        if (!b.count && !x.count) { [use addObject:d]; continue; }
        BOOL hit = [b containsObject:app.bundleID] || [x containsObject:app.executable];
        for (NSString *s in b) if ([generic containsObject:s]) hit = YES;
        [(hit ? use : skip) addObject:d];
    }
    if (skipped) *skipped = skip;
    return use;
}

- (NSArray<NSString *> *)dependencyWarnings {
    // Packages listed in Depends that Splice can't bring along.
    NSSet *fine = [NSSet setWithArray:@[@"mobilesubstrate", @"firmware", @"preferenceloader", @"ellekit", @"cy+cpu.arm64",
                                        @"com.ex.substitute", @"org.coolstar.libhooker", @"libhooker", @"com.opa334.altlist",
                                        @"cy+model.iphone", @"cy+model.ipad", @"libroot", @"com.opa334.libroot",
                                        @"com.saurik.substrate.safemode", @"coreutils", @"bash", @"ws.hbang.common"]];
    NSMutableArray *out = [NSMutableArray array];
    for (NSString *part in [self.depends componentsSeparatedByCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@",|"]]) {
        NSString *pkg = [[part componentsSeparatedByString:@"("].firstObject stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        if (!pkg.length || [fine containsObject:pkg.lowercaseString] || [pkg hasPrefix:@"cy+"]) continue;
        [out addObject:pkg];
    }
    return out;
}

- (void)dealloc {
    if (_dir) [NSFileManager.defaultManager removeItemAtPath:_dir error:nil];
}

@end

@implementation SPBuildOptions
@end
@implementation SPBuildResult
@end

#pragma mark - Building

typedef struct {
    __unsafe_unretained NSDictionary *names;   // leaf name -> new path
    char buf[1024];
} MapCtx;

static NSString *const kFW = @"@executable_path/Frameworks";
static NSString *const kShim = @"@executable_path/Frameworks/CydiaSubstrate.framework/CydiaSubstrate";

static const char *MapDep(const char *dep, void *ctxp) {
    MapCtx *ctx = ctxp;
    NSString *d = @(dep);
    if (!d || [d hasPrefix:@"/System/"] || [d hasPrefix:@"/usr/lib/system/"] || [d hasPrefix:@"/usr/lib/swift/"]) return NULL;
    NSString *to = nil;
    if (IsHookingLibrary(d.lastPathComponent) || [d containsString:@"CydiaSubstrate.framework"]) to = kShim;
    else {
        // .../Name.framework/Name -> bundled framework
        NSRange fr = [d rangeOfString:@".framework/"];
        if (fr.location != NSNotFound) {
            NSString *fwName = [[d substringToIndex:fr.location].lastPathComponent stringByAppendingString:@".framework"];
            if (ctx->names[fwName]) to = [NSString stringWithFormat:@"%@/%@/%@", kFW, fwName, [d substringFromIndex:NSMaxRange(fr)]];
        } else if ([ctx->names[d.lastPathComponent] isKindOfClass:NSString.class]) {
            to = ctx->names[d.lastPathComponent];
        }
    }
    if (!to) return NULL;
    strlcpy(ctx->buf, to.UTF8String, sizeof ctx->buf);
    return ctx->buf;
}

static void CollectDep(const char *dep, void *ctx) {
    [(__bridge NSMutableArray *)ctx addObject:@(dep)];
}

static BOOL KnownMissing(NSString *dep, NSString *appPath) {
    if ([dep hasPrefix:@"@executable_path/"]) {
        NSString *rel = [dep substringFromIndex:@"@executable_path/".length];
        return ![NSFileManager.defaultManager fileExistsAtPath:[appPath stringByAppendingPathComponent:rel]];
    }
    if ([dep hasPrefix:@"/Library/"] || [dep hasPrefix:@"/var/jb/"] || [dep hasPrefix:@"/usr/local/"] || [dep hasPrefix:@"/private/preboot/"]) return YES;
    if ([dep hasPrefix:@"@rpath/"]) {
        NSString *rel = [dep substringFromIndex:7];
        return ![NSFileManager.defaultManager fileExistsAtPath:[[appPath stringByAppendingPathComponent:@"Frameworks"] stringByAppendingPathComponent:rel]];
    }
    NSArray *jbLibs = @[@"libcolorpicker", @"libCSColorPicker", @"libgcuniversal", @"libsparkapplist", @"libapplist", @"librocketbootstrap",
                        @"libactivator", @"libcephei", @"libpddokdo", @"libimagepicker", @"libSandy", @"libkrw", @"libjailbreak", @"libcrashreport"];
    for (NSString *n in jbLibs) if ([dep.lastPathComponent hasPrefix:n]) return YES;
    return NO;
}

static BOOL CopyReplacing(NSString *src, NSString *dst, NSError **err) {
    NSFileManager *fm = NSFileManager.defaultManager;
    [fm removeItemAtPath:dst error:nil];
    return [fm copyItemAtPath:src toPath:dst error:err];
}

static NSArray<NSString *> *MachOsIn(NSString *dir) {
    NSMutableArray *out = [NSMutableArray array];
    NSDirectoryEnumerator *en = [NSFileManager.defaultManager enumeratorAtPath:dir];
    for (NSString *rel in en) {
        NSString *full = [dir stringByAppendingPathComponent:rel];
        if ([en.fileAttributes[NSFileType] isEqual:NSFileTypeRegular] && [en.fileAttributes fileSize] > 4096 && mp_is_macho(full.fileSystemRepresentation)) [out addObject:full];
    }
    return out;
}

static BOOL WriteZip(NSString *root, NSString *out, BOOL compress, SPProgress progress, NSError **err) {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSMutableArray *items = [NSMutableArray array];
    uint64_t total = 0;
    NSDirectoryEnumerator *en = [fm enumeratorAtPath:root];
    for (NSString *rel in en) {
        [items addObject:rel];
        if ([en.fileAttributes[NSFileType] isEqual:NSFileTypeRegular]) total += en.fileAttributes.fileSize;
    }
    struct archive *a = archive_write_new();
    archive_write_set_format_zip(a);
    compress ? archive_write_zip_set_compression_deflate(a) : archive_write_zip_set_compression_store(a);
    [fm removeItemAtPath:out error:nil];
    if (archive_write_open_filename(a, out.fileSystemRepresentation) != ARCHIVE_OK) {
        if (err) *err = SPErr(@"Couldn't create the .ipa file.");
        archive_write_free(a);
        return NO;
    }
    char *buf = malloc(1 << 20);
    uint64_t done = 0;
    BOOL ok = YES;
    for (NSString *rel in items) {
        NSString *full = [root stringByAppendingPathComponent:rel];
        struct stat st;
        if (lstat(full.fileSystemRepresentation, &st) != 0) continue;
        struct archive_entry *e = archive_entry_new();
        archive_entry_set_mtime(e, st.st_mtime, 0);
        if (S_ISDIR(st.st_mode)) {
            archive_entry_set_pathname(e, [rel stringByAppendingString:@"/"].UTF8String);
            archive_entry_set_filetype(e, AE_IFDIR);
            archive_entry_set_perm(e, 0755);
            archive_entry_set_size(e, 0);
            archive_write_header(a, e);
        } else if (S_ISLNK(st.st_mode)) {
            char target[PATH_MAX] = {0};
            readlink(full.fileSystemRepresentation, target, sizeof target - 1);
            archive_entry_set_pathname(e, rel.UTF8String);
            archive_entry_set_filetype(e, AE_IFLNK);
            archive_entry_set_perm(e, 0755);
            archive_entry_set_symlink(e, target);
            archive_entry_set_size(e, 0);
            archive_write_header(a, e);
        } else if (S_ISREG(st.st_mode)) {
            archive_entry_set_pathname(e, rel.UTF8String);
            archive_entry_set_filetype(e, AE_IFREG);
            archive_entry_set_perm(e, (st.st_mode & 0111) ? 0755 : 0644);
            archive_entry_set_size(e, st.st_size);
            if (archive_write_header(a, e) != ARCHIVE_OK) { ok = NO; }
            FILE *f = ok ? fopen(full.fileSystemRepresentation, "rb") : NULL;
            size_t n;
            while (f && (n = fread(buf, 1, 1 << 20, f)) > 0) {
                if (archive_write_data(a, buf, n) < 0) { ok = NO; break; }
                done += n;
                if (progress && total) progress(@"Packing the .ipa", (double)done / (double)total);
            }
            if (f) fclose(f);
        }
        archive_write_finish_entry(a);
        archive_entry_free(e);
        if (!ok) break;
    }
    free(buf);
    if (archive_write_close(a) != ARCHIVE_OK) ok = NO;
    archive_write_free(a);
    if (!ok && err) *err = SPErr(@"Couldn't write the .ipa (out of space?).");
    return ok;
}

static NSString *SafeFileName(NSString *s) {
    NSCharacterSet *bad = [NSCharacterSet characterSetWithCharactersInString:@"/\\:*?\"<>|"];
    return [[s componentsSeparatedByCharactersInSet:bad] componentsJoinedByString:@"-"];
}

SPBuildResult *SPBuild(SPApp *app, NSArray<SPTweak *> *tweaks, SPBuildOptions *opts, SPProgress progress, NSError **err) {
    NSFileManager *fm = NSFileManager.defaultManager;
    if (app.encrypted) { if (err) *err = SPErr(@"This app is still encrypted. Decrypt it first (for example with TrollDecrypt)."); return nil; }
    progress(@"Copying the app", -1);
    NSString *stage = NewWorkDir(@"build");
    NSString *payload = [stage stringByAppendingPathComponent:@"Payload"];
    [fm createDirectoryAtPath:payload withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *appPath = [payload stringByAppendingPathComponent:app.appPath.lastPathComponent];
    if (![fm copyItemAtPath:app.appPath toPath:appPath error:err]) { [fm removeItemAtPath:stage error:nil]; return nil; }

    NSMutableArray *warnings = [NSMutableArray array], *injectedNames = [NSMutableArray array];
    NSString *fwDir = [appPath stringByAppendingPathComponent:@"Frameworks"];
    [fm createDirectoryAtPath:fwDir withIntermediateDirectories:YES attributes:nil error:nil];

    // 1. The substrate shim.
    progress(@"Adding the substrate shim", -1);
    NSString *shim = [NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"Shim/CydiaSubstrate.framework"];
    if (!CopyReplacing(shim, [fwDir stringByAppendingPathComponent:@"CydiaSubstrate.framework"], err)) { [fm removeItemAtPath:stage error:nil]; return nil; }

    // 2. Copy each tweak's pieces in.
    progress(@"Copying the tweaks in", -1);
    NSMutableDictionary *names = [NSMutableDictionary dictionary];   // leaf -> new path
    NSMutableArray *toPatch = [NSMutableArray array], *inject = [NSMutableArray array];
    for (SPTweak *t in tweaks) {
        NSArray *skipped = nil;
        NSArray *use = [t dylibsForApp:app skipped:&skipped];
        for (NSString *s in skipped)
            [warnings addObject:[NSString stringWithFormat:@"%@: skipped %@ (it's for other apps, not %@).", t.name, s.lastPathComponent, app.name]];
        if (!use.count) {
            [warnings addObject:[NSString stringWithFormat:@"%@ doesn't target %@, so nothing from it was added.", t.name, app.name]];
            continue;
        }
        for (NSString *d in use) {
            NSString *dst = [fwDir stringByAppendingPathComponent:d.lastPathComponent];
            if (!CopyReplacing(d, dst, err)) { [fm removeItemAtPath:stage error:nil]; return nil; }
            names[d.lastPathComponent] = [kFW stringByAppendingPathComponent:d.lastPathComponent];
            [toPatch addObject:dst];
            [inject addObject:names[d.lastPathComponent]];
            [injectedNames addObject:d.lastPathComponent];
        }
        for (NSString *l in t.libraries) {
            NSString *dst = [fwDir stringByAppendingPathComponent:l.lastPathComponent];
            if (!CopyReplacing(l, dst, err)) { [fm removeItemAtPath:stage error:nil]; return nil; }
            names[l.lastPathComponent] = [kFW stringByAppendingPathComponent:l.lastPathComponent];
            [toPatch addObject:dst];
        }
        for (NSString *f in t.frameworks) {
            NSString *dst = [fwDir stringByAppendingPathComponent:f.lastPathComponent];
            if (!CopyReplacing(f, dst, err)) { [fm removeItemAtPath:stage error:nil]; return nil; }
            names[f.lastPathComponent] = NSNull.null;   // marks a bundled framework
            [toPatch addObjectsFromArray:MachOsIn(dst)];
        }
        for (NSString *b in t.bundles) {
            if (!CopyReplacing(b, [appPath stringByAppendingPathComponent:b.lastPathComponent], err)) { [fm removeItemAtPath:stage error:nil]; return nil; }
        }
        for (NSString *dep in [t dependencyWarnings])
            [warnings addObject:[NSString stringWithFormat:@"%@ depends on %@. If the app crashes, add that package's .deb too.", t.name, dep]];
    }
    if (!inject.count) {
        [fm removeItemAtPath:stage error:nil];
        if (err) *err = SPErr([NSString stringWithFormat:@"None of these tweaks are made for %@ (their filters target other apps).", app.name]);
        return nil;
    }

    // 3. Point the tweaks at the shim and at each other.
    MapCtx ctx;
    ctx.names = names;
    char perr[256];
    for (NSUInteger i = 0; i < toPatch.count; i++) {
        NSString *p = toPatch[i];
        progress([NSString stringWithFormat:@"Patching %@", p.lastPathComponent], (double)i / toPatch.count);
        mp_opts o = {0};
        o.map = MapDep; o.ctx = &ctx;
        NSString *newID = [p.pathExtension isEqualToString:@"dylib"] ? [kFW stringByAppendingPathComponent:p.lastPathComponent] : nil;
        o.new_id = newID.UTF8String;
        perr[0] = 0;
        if (mp_patch(p.fileSystemRepresentation, &o, perr, sizeof perr) != 0) {
            [fm removeItemAtPath:stage error:nil];
            if (err) *err = SPErr([NSString stringWithFormat:@"Couldn't patch %@: %s.", p.lastPathComponent, perr]);
            return nil;
        }
        NSMutableArray *deps = [NSMutableArray array];
        mp_list_deps(p.fileSystemRepresentation, CollectDep, (__bridge void *)deps);
        for (NSString *d in deps)
            if (KnownMissing(d, appPath))
                [warnings addObject:[NSString stringWithFormat:@"%@ needs %@, which isn't included. Add the .deb that has it, or the app may crash on launch.", p.lastPathComponent, d.lastPathComponent]];
    }

    // 4. Load the tweaks from the app's main binary.
    progress(@"Injecting into the app", -1);
    NSString *exe = [appPath stringByAppendingPathComponent:app.executable];
    const char **add = calloc(inject.count, sizeof(char *));
    for (NSUInteger i = 0; i < inject.count; i++) add[i] = [inject[i] UTF8String];
    mp_opts mo = {0};
    mo.add = add; mo.nadd = (int)inject.count;
    perr[0] = 0;
    int rc = mp_patch(exe.fileSystemRepresentation, &mo, perr, sizeof perr);
    free(add);
    if (rc != 0) {
        [fm removeItemAtPath:stage error:nil];
        if (err) *err = SPErr([NSString stringWithFormat:@"Couldn't inject into %@: %s.", app.executable, perr]);
        return nil;
    }

    // 5. Info.plist + cleanup.
    progress(@"Finishing up", -1);
    NSString *infoPath = [appPath stringByAppendingPathComponent:@"Info.plist"];
    NSMutableDictionary *info = [NSMutableDictionary dictionaryWithContentsOfFile:infoPath];
    NSString *oldID = info[@"CFBundleIdentifier"];
    if (opts.displayName.length) { info[@"CFBundleDisplayName"] = opts.displayName; }
    if (opts.anyDevice) [info removeObjectForKey:@"UISupportedDevices"];
    if (opts.bundleID.length && ![opts.bundleID isEqualToString:oldID]) info[@"CFBundleIdentifier"] = opts.bundleID;
    [info writeToFile:infoPath atomically:YES];
    // Localized display names override CFBundleDisplayName.
    if (opts.displayName.length) {
        for (NSString *f in [fm contentsOfDirectoryAtPath:appPath error:nil]) {
            if (![f.pathExtension isEqualToString:@"lproj"]) continue;
            NSString *sp = [[appPath stringByAppendingPathComponent:f] stringByAppendingPathComponent:@"InfoPlist.strings"];
            NSMutableDictionary *s = [NSMutableDictionary dictionaryWithContentsOfFile:sp];
            if (!s) continue;
            if (s[@"CFBundleDisplayName"]) s[@"CFBundleDisplayName"] = opts.displayName;
            if (s[@"CFBundleName"]) s[@"CFBundleName"] = opts.displayName;
            [s writeToFile:sp atomically:YES];
        }
    }
    if (opts.removeExtensions) {
        [fm removeItemAtPath:[appPath stringByAppendingPathComponent:@"PlugIns"] error:nil];
        [fm removeItemAtPath:[appPath stringByAppendingPathComponent:@"Extensions"] error:nil];
    } else if (opts.bundleID.length && oldID.length && ![opts.bundleID isEqualToString:oldID]) {
        // Extensions must stay under the app's bundle ID.
        for (NSString *dir in @[@"PlugIns", @"Extensions"]) {
            NSString *pd = [appPath stringByAppendingPathComponent:dir];
            for (NSString *x in [fm contentsOfDirectoryAtPath:pd error:nil]) {
                NSString *xp = [[pd stringByAppendingPathComponent:x] stringByAppendingPathComponent:@"Info.plist"];
                NSMutableDictionary *xi = [NSMutableDictionary dictionaryWithContentsOfFile:xp];
                NSString *xid = xi[@"CFBundleIdentifier"];
                if ([xid hasPrefix:oldID]) {
                    xi[@"CFBundleIdentifier"] = [opts.bundleID stringByAppendingString:[xid substringFromIndex:oldID.length]];
                    [xi writeToFile:xp atomically:YES];
                }
            }
        }
    }
    if (opts.removeWatch) {
        [fm removeItemAtPath:[appPath stringByAppendingPathComponent:@"Watch"] error:nil];
        [fm removeItemAtPath:[appPath stringByAppendingPathComponent:@"com.apple.WatchPlaceholder"] error:nil];
    }
    [fm removeItemAtPath:[appPath stringByAppendingPathComponent:@"SC_Info"] error:nil];
    [fm removeItemAtPath:[appPath stringByAppendingPathComponent:@"iTunesMetadata.plist"] error:nil];

    // 6. Pack.
    NSString *name = opts.displayName.length ? opts.displayName : app.name;
    NSString *file = SafeFileName([NSString stringWithFormat:@"%@ %@ (modded).ipa", name, app.version]);
    NSString *outPath = [SPBuildsDir() stringByAppendingPathComponent:file];
    BOOL ok = WriteZip(stage, outPath, opts.compress, progress, err);
    [fm removeItemAtPath:stage error:nil];
    if (!ok) { [fm removeItemAtPath:outPath error:nil]; return nil; }

    SPBuildResult *res = [SPBuildResult new];
    res.ipaPath = outPath;
    res.injected = injectedNames;
    res.warnings = [NSOrderedSet orderedSetWithArray:warnings].array;
    return res;
}
