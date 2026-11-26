// Splice engine: unpack a decrypted .ipa, unpack tweaks, inject, repack.
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

NSString *SPWorkRoot(void);      // scratch space (cleared on launch)
NSString *SPBuildsDir(void);     // finished modded apps
// Copy a file the user picked (any app's Files storage, iCloud...) into our scratch space. Blocking.
NSString *_Nullable SPStashURL(NSURL *url, NSError *_Nullable *_Nullable err);

@interface SPApp : NSObject
@property (nonatomic, copy) NSString *dir;          // folder that holds Payload/
@property (nonatomic, copy) NSString *appPath;      // .../Payload/Name.app
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) NSString *bundleID;
@property (nonatomic, copy) NSString *version;
@property (nonatomic, copy) NSString *executable;
@property (nonatomic, strong, nullable) UIImage *icon;
@property (nonatomic) BOOL encrypted;
@property (nonatomic) NSUInteger existingTweaks;    // dylibs already in Frameworks that look injected
+ (nullable instancetype)importIPA:(NSString *)ipaPath error:(NSError **)err;
@end

@interface SPTweak : NSObject
@property (nonatomic, copy) NSString *dir;
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) NSString *packageID;
@property (nonatomic, copy) NSString *version;
@property (nonatomic, copy) NSString *depends;
@property (nonatomic, copy) NSString *fileName;
@property (nonatomic, strong) NSArray<NSString *> *dylibs;      // injected into the app
@property (nonatomic, strong) NSArray<NSString *> *libraries;   // support dylibs (usr/lib), bundled not injected
@property (nonatomic, strong) NSArray<NSString *> *frameworks;  // .framework folders
@property (nonatomic, strong) NSArray<NSString *> *bundles;     // resource .bundle folders
+ (nullable instancetype)importFile:(NSString *)path error:(NSError **)err;
// Dylibs whose filter plist targets this app (or have no filter).
- (NSArray<NSString *> *)dylibsForApp:(nullable SPApp *)app skipped:(NSArray<NSString *> *_Nullable *_Nullable)skipped;
- (NSArray<NSString *> *)dependencyWarnings;
@end

@interface SPBuildOptions : NSObject
@property (nonatomic, copy, nullable) NSString *displayName;
@property (nonatomic, copy, nullable) NSString *bundleID;
@property (nonatomic) BOOL removeExtensions;
@property (nonatomic) BOOL removeWatch;
@property (nonatomic) BOOL anyDevice;
@property (nonatomic) BOOL compress;
@end

typedef void (^SPProgress)(NSString *step, double fraction);   // fraction < 0 = indeterminate

@interface SPBuildResult : NSObject
@property (nonatomic, copy) NSString *ipaPath;
@property (nonatomic, strong) NSArray<NSString *> *injected;
@property (nonatomic, strong) NSArray<NSString *> *warnings;
@end

SPBuildResult *_Nullable SPBuild(SPApp *app, NSArray<SPTweak *> *tweaks, SPBuildOptions *opts, SPProgress progress, NSError *_Nullable *_Nullable err);

NS_ASSUME_NONNULL_END
