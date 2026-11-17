// tmsign - signs every Mach-O in an app bundle with the bundled fastPathSign tool
// (adhoc signature + CoreTrust bypass), so the app installs with no ldid and no TrollStore.
#import <Foundation/Foundation.h>
#import "tmsign.h"
#import "machopatch.h"
#import <spawn.h>
#import <sys/wait.h>
#import <sys/stat.h>
#import <signal.h>
#import <time.h>
#import <unistd.h>
#import <fcntl.h>

// The signer must run outside the app sandbox, or iOS kills it (signal 9) when it is spawned
// from inside the sandboxed Trollamine app. Spawning it with a root persona -- the same way the
// installer engine is spawned -- takes it out of the sandbox. (Declared in tmcommon.h; redeclared
// here because this file doesn't import it.)
#define POSIX_SPAWN_PERSONA_FLAGS_OVERRIDE 1
extern int posix_spawnattr_set_persona_np(const posix_spawnattr_t *__restrict, uid_t, uint32_t);
extern int posix_spawnattr_set_persona_uid_np(const posix_spawnattr_t *__restrict, uid_t);
extern int posix_spawnattr_set_persona_gid_np(const posix_spawnattr_t *__restrict, uid_t);

extern char **environ;

// A file is a Mach-O if it begins with a 64-bit or fat magic number.
static BOOL TMIsMacho(NSString *path) {
    FILE *f = fopen(path.fileSystemRepresentation, "rb");
    if (!f) return NO;
    uint8_t m[4] = {0};
    size_t n = fread(m, 1, 4, f);
    fclose(f);
    if (n != 4) return NO;
    uint32_t magic = (uint32_t)m[0] | ((uint32_t)m[1] << 8) | ((uint32_t)m[2] << 16) | ((uint32_t)m[3] << 24);
    return magic == 0xfeedfacf        // MH_MAGIC_64 (little-endian arm64)
        || magic == 0xcffaedfe        // MH_CIGAM_64
        || magic == 0xcafebabe        // FAT_MAGIC
        || magic == 0xbebafeca        // FAT_CIGAM
        || magic == 0xcafebabf        // FAT_MAGIC_64
        || magic == 0xbfbafeca;       // FAT_CIGAM_64
}

// Returns the Mach-O filetype (e.g. MH_EXECUTE 0x2, MH_DYLIB 0x6) of the file, or 0 if unknown.
// For a fat binary, reports the filetype of its first architecture slice.
static uint32_t TMMachoFiletype(NSString *path) {
    int fd = open(path.fileSystemRepresentation, O_RDONLY);
    if (fd < 0) return 0;
    uint32_t ft = 0;
    uint8_t h[8] = {0};
    if (pread(fd, h, sizeof(h), 0) == (ssize_t)sizeof(h)) {
        uint32_t magic = (uint32_t)h[0] | ((uint32_t)h[1] << 8) | ((uint32_t)h[2] << 16) | ((uint32_t)h[3] << 24);
        if (magic == 0xfeedfacf) {                      // thin arm64, little-endian: filetype at offset 12
            uint32_t v = 0;
            if (pread(fd, &v, 4, 12) == 4) ft = v;
        } else if (magic == 0xcafebabe || magic == 0xcafebabf || magic == 0xbebafeca || magic == 0xbfbafeca) {
            // fat header (stored big-endian; read little-endian above it shows as the byte-swapped value)
            BOOL is64 = (magic == 0xcafebabf || magic == 0xbfbafeca);
            off_t archOff = 8;                          // past fat_header (magic + nfat_arch)
            uint32_t offBE = 0;
            // fat_arch: cputype(0) cpusubtype(4) offset(8) ...  fat_arch_64: offset(8) is 64-bit
            if (pread(fd, &offBE, 4, archOff + 8) == 4) {
                uint64_t sliceOff = __builtin_bswap32(offBE);
                if (is64) {
                    uint32_t lo = 0;
                    if (pread(fd, &lo, 4, archOff + 12) == 4) sliceOff = ((uint64_t)sliceOff << 32) | __builtin_bswap32(lo);
                }
                uint8_t sh[16] = {0};
                if (pread(fd, sh, sizeof(sh), (off_t)sliceOff) == (ssize_t)sizeof(sh)) {
                    uint32_t smagic = (uint32_t)sh[0] | ((uint32_t)sh[1] << 8) | ((uint32_t)sh[2] << 16) | ((uint32_t)sh[3] << 24);
                    if (smagic == 0xfeedfacf) ft = (uint32_t)sh[12] | ((uint32_t)sh[13] << 8) | ((uint32_t)sh[14] << 16) | ((uint32_t)sh[15] << 24);
                }
            }
        }
    }
    close(fd);
    return ft;
}
#define TM_MH_DYLIB 0x6u

// Runs fastPathSign on one Mach-O. Uses explicitEntsPath if given, else the binary's own current entitlements.
static int TMSignOne(NSString *fastPathSign, NSString *machoPath, NSString *workDir, NSString *explicitEntsPath, NSString **log) {
    NSMutableArray<NSString *> *args = [NSMutableArray array];
    NSString *entsPath = nil;
    BOOL ownEnts = NO;
    if (explicitEntsPath && [[NSFileManager defaultManager] fileExistsAtPath:explicitEntsPath]) {
        [args addObject:@"--entitlements"];
        [args addObject:explicitEntsPath];
    }
    char *xml = (explicitEntsPath ? NULL : tm_read_entitlements(machoPath.fileSystemRepresentation));
    if (xml) {
        ownEnts = YES;
        NSData *data = [NSData dataWithBytes:xml length:strlen(xml)];
        free(xml);
        id check = [NSPropertyListSerialization propertyListWithData:data options:0 format:NULL error:nil];
        if ([check isKindOfClass:[NSDictionary class]] && [(NSDictionary *)check count] > 0) {
            entsPath = [workDir stringByAppendingPathComponent:[NSString stringWithFormat:@"ents-%@.plist", [NSUUID UUID].UUIDString]];
            if ([data writeToFile:entsPath atomically:NO]) {
                [args addObject:@"--entitlements"];
                [args addObject:entsPath];
            } else {
                entsPath = nil;
            }
        }
    }
    [args addObject:machoPath];

    NSMutableArray *all = [NSMutableArray arrayWithObject:fastPathSign];
    [all addObjectsFromArray:args];
    char **argv = calloc(all.count + 1, sizeof(char *));
    if (!argv) {
        if (ownEnts && entsPath) [[NSFileManager defaultManager] removeItemAtPath:entsPath error:nil];
        if (log) *log = @"out of memory (calloc)";
        return -1;
    }
    for (NSUInteger i = 0; i < all.count; i++) {
        argv[i] = strdup([all[i] fileSystemRepresentation]);
        if (!argv[i]) {
            for (NSUInteger j = 0; j < i; j++) free(argv[j]);
            free(argv);
            if (ownEnts && entsPath) [[NSFileManager defaultManager] removeItemAtPath:entsPath error:nil];
            if (log) *log = @"out of memory (strdup)";
            return -1;
        }
    }

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
    posix_spawnattr_t attr;
    posix_spawnattr_init(&attr);
    posix_spawnattr_set_persona_np(&attr, 99, POSIX_SPAWN_PERSONA_FLAGS_OVERRIDE);
    posix_spawnattr_set_persona_uid_np(&attr, 0);
    posix_spawnattr_set_persona_gid_np(&attr, 0);
    pid_t pid = 0;
    int rc = posix_spawn(&pid, argv[0], &actions, &attr, argv, environ);
    posix_spawnattr_destroy(&attr);
    posix_spawn_file_actions_destroy(&actions);
    for (NSUInteger i = 0; i < all.count; i++) free(argv[i]);
    free(argv);
    if (piped) close(fds[1]);
    if (rc != 0) {
        if (piped) close(fds[0]);
        if (entsPath) [[NSFileManager defaultManager] removeItemAtPath:entsPath error:nil];
        if (log) *log = [NSString stringWithFormat:@"couldn't start the signer (%s)", strerror(rc)];
        return -1;
    }
    NSMutableData *buf = [NSMutableData data];
    if (piped) {
        char tmp[2048];
        ssize_t r;
        while ((r = read(fds[0], tmp, sizeof(tmp))) > 0) if (buf.length < 16384) [buf appendBytes:tmp length:(NSUInteger)r];
        close(fds[0]);
    }
    int status = 0;
    // Poll with a 60-second wall-clock timeout so a hung signer doesn't block forever.
    {
        int reaped = 0;
        struct timespec start;
        clock_gettime(CLOCK_MONOTONIC, &start);
        while (1) {
            pid_t w = waitpid(pid, &status, WNOHANG);
            if (w > 0) { reaped = 1; break; }
            if (w < 0 && errno != EINTR) { reaped = 1; break; }
            struct timespec now;
            clock_gettime(CLOCK_MONOTONIC, &now);
            double secs = (now.tv_sec - start.tv_sec) + (now.tv_nsec - start.tv_nsec) / 1e9;
            if (secs >= 60.0) break;
            usleep(100000);
        }
        if (!reaped) {
            kill(pid, SIGKILL);
            while (waitpid(pid, &status, 0) < 0 && errno == EINTR) {}
            if (ownEnts && entsPath) [[NSFileManager defaultManager] removeItemAtPath:entsPath error:nil];
            if (log) *log = @"signer timed out";
            return -1;
        }
    }
    if (ownEnts && entsPath) [[NSFileManager defaultManager] removeItemAtPath:entsPath error:nil];
    NSString *text = [[NSString alloc] initWithData:buf encoding:NSUTF8StringEncoding] ?: @"";
    if (WIFSIGNALED(status)) text = [text stringByAppendingFormat:@" [signer was killed by signal %d]", WTERMSIG(status)];
    if (log) *log = text;
    return WIFEXITED(status) ? WEXITSTATUS(status) : 255;
}

int tm_sign_file(NSString *fastPathSign, NSString *machoPath, NSString *entsPath, NSString *workDir, NSString **log) {
    return TMSignOne(fastPathSign, machoPath, workDir, entsPath, log);
}

NSString *tm_sign_app_bundle_ents(NSString *appDir, NSString *fastPathSign, NSString *workDir, NSDictionary<NSString *, NSString *> *explicitEnts) {
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm isExecutableFileAtPath:fastPathSign]) {
        // Make sure it can run (it may have been copied without the execute bit).
        chmod(fastPathSign.fileSystemRepresentation, 0755);
        if (![fm fileExistsAtPath:fastPathSign]) return @"The signer tool is missing.";
    }

    // Collect every Mach-O in the bundle. Sign the main executable last so, if anything
    // fails partway, the main binary isn't left as the only signed file (which would fast-path
    // the installer past the others).
    NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:[appDir stringByAppendingPathComponent:@"Info.plist"]];
    NSString *mainExe = info[@"CFBundleExecutable"];
    NSString *mainPath = [mainExe isKindOfClass:[NSString class]] ? [appDir stringByAppendingPathComponent:mainExe] : nil;

    NSMutableArray<NSString *> *machos = [NSMutableArray array];
    NSDirectoryEnumerator *en = [fm enumeratorAtPath:appDir];
    for (NSString *rel in en) {
        NSString *full = [appDir stringByAppendingPathComponent:rel];
        NSDictionary *attrs = [en fileAttributes];
        if (![attrs.fileType isEqualToString:NSFileTypeRegular]) continue;
        if (mainPath && [full isEqualToString:mainPath]) continue; // main goes last
        if (TMIsMacho(full)) [machos addObject:full];
    }
    if (mainPath && TMIsMacho(mainPath)) [machos addObject:mainPath];
    if (machos.count == 0) return @"No program files were found to sign.";

    for (NSString *macho in machos) {
        NSString *log = nil;
        // Look up by path relative to appDir first (avoids collisions when two binaries share a filename),
        // then fall back to lastPathComponent for backward compatibility.
        NSString *relPath = [macho substringFromIndex:appDir.length + 1];
        NSString *ents = explicitEnts[relPath] ?: explicitEnts[macho.lastPathComponent];
        int code = TMSignOne(fastPathSign, macho, workDir, ents, &log);
        if (code != 0) {
            // Some bundled libraries (e.g. a jailbreak's libjailbreak.dylib) carry a special
            // signature the adhoc signer can't reproduce. Re-signing them isn't needed and would
            // break them, so leave such a library with its own signature and carry on. The main
            // executable and any other program file still fail hard -- those must be signed.
            BOOL isMain = (mainPath && [macho isEqualToString:mainPath]);
            if (!isMain && TMMachoFiletype(macho) == TM_MH_DYLIB) {
                NSLog(@"[Trollamine] leaving %@ with its own signature (signer code %d)", macho.lastPathComponent, code);
                continue;
            }
            NSString *tail = log.length > 160 ? [log substringFromIndex:log.length - 160] : (log ?: @"");
            return [NSString stringWithFormat:@"Signing failed on %@ (code %d). %@", macho.lastPathComponent, code, tail];
        }
    }
    return nil;
}

NSString *tm_sign_app_bundle(NSString *appDir, NSString *fastPathSign, NSString *workDir) {
    return tm_sign_app_bundle_ents(appDir, fastPathSign, workDir, nil);
}
