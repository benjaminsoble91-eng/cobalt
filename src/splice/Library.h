// Splice shared library: decrypted apps published by the admin, offered to everyone.
// Storage: the "splice-library" GitHub release on the Cobalt repo holds the .ipa files and icons;
// splice/catalog.json on main lists them (served by GitHub Pages).
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface SPSharedApp : NSObject
@property (nonatomic, copy) NSString *entryID;     // bundleID-version
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) NSString *bundleID;
@property (nonatomic, copy) NSString *version;
@property (nonatomic) long long size;
@property (nonatomic, copy) NSString *url;
@property (nonatomic, copy, nullable) NSString *iconURL;
@property (nonatomic) long long assetID, iconAssetID;
@property (nonatomic, copy, nullable) NSString *added;
@property (nonatomic) BOOL isTweak;                  // a shared .deb/.dylib instead of an app
@property (nonatomic, copy, nullable) NSString *fileName;   // tweak's original file name
@property (nonatomic, copy, nullable) NSString *packageID;
@end

typedef void (^SPProgressBlock)(double fraction);

@interface SPLibrary : NSObject
+ (void)fetchCatalog:(void (^)(NSArray<SPSharedApp *> *_Nullable apps, NSArray<SPSharedApp *> *_Nullable tweaks, NSError *_Nullable err))done;   // main queue
+ (void)download:(SPSharedApp *)app progress:(SPProgressBlock)progress
      completion:(void (^)(NSString *_Nullable path, NSError *_Nullable err))done;                       // main queue
+ (void)loadIcon:(nullable NSString *)url into:(UIImageView *)view;
@end

@interface SPAdmin : NSObject
+ (BOOL)checkPassword:(NSString *)pw;
// Checks the password and unlocks the built-in token for this session.
+ (BOOL)unlock:(NSString *)pw;
+ (nullable NSString *)builtInToken;   // only after unlock
+ (BOOL)usingBuiltInToken;
+ (nullable NSString *)token;
+ (void)setToken:(nullable NSString *)token;
// Blocking - call off the main thread.
+ (nullable NSString *)validateToken:(NSString *)token;   // nil = OK, otherwise the problem
+ (nullable SPSharedApp *)publishIPA:(NSString *)path progress:(void (^)(NSString *step, double fraction))progress error:(NSError **)err;
+ (nullable SPSharedApp *)publishTweak:(NSString *)path progress:(void (^)(NSString *step, double fraction))progress error:(NSError **)err;
+ (BOOL)remove:(SPSharedApp *)app error:(NSError **)err;
@end

NS_ASSUME_NONNULL_END
