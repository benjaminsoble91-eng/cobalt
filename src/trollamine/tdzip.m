// Zip writer implementation + tipa packager.
#import <Foundation/Foundation.h>
#import "tdzip.h"
#import <sys/stat.h>
#import <dirent.h>
#import <limits.h>


@implementation TDZip {
    FILE *_fp;
    NSMutableData *_central;
    uint64_t _offset;
    NSUInteger _count;
}

- (instancetype)initWithPath:(NSString *)path {
    if ((self = [super init])) {
        _fp = fopen(path.fileSystemRepresentation, "wb");
        _central = [NSMutableData data];
        if (!_fp) self.errorMessage = [NSString stringWithFormat:@"Can't create %@ (%s)", path, strerror(errno)];
    }
    return self;
}

- (uint64_t)bytesWritten { return _offset; }

static void put16(NSMutableData *d, uint16_t v) { [d appendBytes:&v length:2]; }
static void put32(NSMutableData *d, uint32_t v) { [d appendBytes:&v length:4]; }

- (BOOL)writeBytes:(const void *)b length:(size_t)n {
    if (n == 0) return YES;
    if (fwrite(b, 1, n, _fp) != n) {
        self.errorMessage = [NSString stringWithFormat:@"Write failed (%s). Out of storage?", strerror(errno)];
        return NO;
    }
    _offset += n;
    return YES;
}

- (BOOL)beginEntry:(NSString *)name mode:(mode_t)mode crc:(uint32_t)crc size:(uint64_t)size {
    if (!_fp) return NO;
    if (size > 0xFFFFFFF0ULL || _offset + size > 0xFFFFFFF0ULL || _count >= 65534) {
        self.errorMessage = @"This app is too large for this version (over 4 GB or 65,000 files).";
        return NO;
    }
    NSData *nameData = [name dataUsingEncoding:NSUTF8StringEncoding];
    NSMutableData *lh = [NSMutableData data];
    put32(lh, 0x04034b50); put16(lh, 20); put16(lh, 0x0800); put16(lh, 0);
    put16(lh, 0); put16(lh, 0x5821);
    put32(lh, crc); put32(lh, (uint32_t)size); put32(lh, (uint32_t)size);
    put16(lh, (uint16_t)nameData.length); put16(lh, 0);
    [lh appendData:nameData];

    put32(_central, 0x02014b50); put16(_central, (3 << 8) | 20); put16(_central, 20); put16(_central, 0x0800); put16(_central, 0);
    put16(_central, 0); put16(_central, 0x5821);
    put32(_central, crc); put32(_central, (uint32_t)size); put32(_central, (uint32_t)size);
    put16(_central, (uint16_t)nameData.length); put16(_central, 0); put16(_central, 0);
    put16(_central, 0); put16(_central, 0);
    put32(_central, ((uint32_t)mode) << 16);
    put32(_central, (uint32_t)_offset);
    [_central appendData:nameData];
    _count++;
    return [self writeBytes:lh.bytes length:lh.length];
}

- (BOOL)addData:(NSData *)data name:(NSString *)name mode:(mode_t)mode {
    uint32_t crc = (uint32_t)crc32(crc32(0L, Z_NULL, 0), data.bytes, (uInt)data.length);
    if (![self beginEntry:name mode:mode crc:crc size:data.length]) return NO;
    return [self writeBytes:data.bytes length:data.length];
}

- (BOOL)addFile:(NSString *)src name:(NSString *)name mode:(mode_t)mode {
    FILE *in = fopen(src.fileSystemRepresentation, "rb");
    if (!in) {
        self.errorMessage = [NSString stringWithFormat:@"Can't read %@ (%s)", name, strerror(errno)];
        return NO;
    }
    static const size_t kBuf = 1 << 20;
    uint8_t *buf = malloc(kBuf);
    if (!buf) {
        fclose(in);
        self.errorMessage = @"Out of memory";
        return NO;
    }
    uLong crc = crc32(0L, Z_NULL, 0);
    uint64_t size = 0;
    size_t n;
    while ((n = fread(buf, 1, kBuf, in)) > 0) { crc = crc32(crc, buf, (uInt)n); size += n; }
    rewind(in);
    BOOL ok = [self beginEntry:name mode:mode crc:(uint32_t)crc size:size];
    uint64_t copied = 0;
    while (ok && (n = fread(buf, 1, kBuf, in)) > 0) { ok = [self writeBytes:buf length:n]; copied += n; }
    if (ok && copied != size) { self.errorMessage = [NSString stringWithFormat:@"%@ changed while copying", name]; ok = NO; }
    free(buf);
    fclose(in);
    return ok;
}

- (BOOL)finish {
    if (!_fp) return NO;
    uint64_t cdOffset = _offset;
    BOOL ok = [self writeBytes:_central.bytes length:_central.length];
    NSMutableData *end = [NSMutableData data];
    put32(end, 0x06054b50); put16(end, 0); put16(end, 0);
    put16(end, (uint16_t)_count); put16(end, (uint16_t)_count);
    put32(end, (uint32_t)_central.length); put32(end, (uint32_t)cdOffset); put16(end, 0);
    ok = ok && [self writeBytes:end.bytes length:end.length];
    if (fclose(_fp) != 0) ok = NO;
    _fp = NULL;
    return ok;
}

- (void)dealloc { if (_fp) fclose(_fp); }
@end



static NSSet<NSString *> *TMZipSkip(void) {
    return [NSSet setWithObjects:@"PlugIns", @"Extensions", @"Watch", @"SC_Info", @"AppClips", nil];
}

static BOOL TMZipTree(TDZip *zip, NSString *srcDir, NSString *zipDir, BOOL top, NSSet<NSString *> *skip) {
    DIR *dir = opendir(srcDir.fileSystemRepresentation);
    if (!dir) { zip.errorMessage = [NSString stringWithFormat:@"Can't open %@", srcDir]; return NO; }
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
        // At the top level, skip directories that are unnecessary for install
        if (top && skip && [skip containsObject:n]) continue;
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
            if (!TMZipTree(zip, src, zname, NO, nil)) return NO;
        } else if (S_ISREG(st.st_mode)) {
            mode_t mode = S_IFREG | ((st.st_mode & 0111) ? 0755 : 0644);
            if (![zip addFile:src name:zname mode:mode]) return NO;
        }
    }
    return YES;
}

NSString *tm_make_tipa(NSString *stagingDir, NSString *outPath) {
    [[NSFileManager defaultManager] removeItemAtPath:outPath error:nil];
    TDZip *zip = [[TDZip alloc] initWithPath:outPath];
    if (zip.errorMessage) return zip.errorMessage;
    // stagingDir contains Payload/
    NSString *payload = [stagingDir stringByAppendingPathComponent:@"Payload"];
    NSSet<NSString *> *skip = TMZipSkip();
    BOOL ok = [zip addData:[NSData data] name:@"Payload/" mode:(S_IFDIR | 0755)] && TMZipTree(zip, payload, @"Payload", YES, skip);
    ok = [zip finish] && ok;
    if (!ok) { [[NSFileManager defaultManager] removeItemAtPath:outPath error:nil]; return zip.errorMessage ?: @"Packaging failed."; }
    return nil;
}
