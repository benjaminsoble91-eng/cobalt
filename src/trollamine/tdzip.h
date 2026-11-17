// Minimal zip writer (store only, keeps unix permissions and symlinks). Shared with TrollDuplicator.
#import <zlib.h>
#import <sys/stat.h>
#import <dirent.h>
#pragma mark - Zip writer (store only, keeps unix permissions and symlinks)

@interface TDZip : NSObject
@property (nonatomic, readonly) uint64_t bytesWritten;
@property (nonatomic, copy) NSString *errorMessage;
- (instancetype)initWithPath:(NSString *)path;
- (BOOL)addData:(NSData *)data name:(NSString *)name mode:(mode_t)mode;
- (BOOL)addFile:(NSString *)src name:(NSString *)name mode:(mode_t)mode;
- (BOOL)finish;
@end

// Zips a staging directory (containing Payload/) into a .tipa. Returns nil on success or an error.
NSString *tm_make_tipa(NSString *stagingDir, NSString *outPath);
