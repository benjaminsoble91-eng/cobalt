#ifndef TM_SIGN_H
#define TM_SIGN_H
#import <Foundation/Foundation.h>
// Signs every Mach-O in an app bundle with fastPathSign (adhoc + CoreTrust bypass).
// Returns nil on success, or an error message. workDir is a writable scratch dir.
NSString *tm_sign_app_bundle(NSString *appDir, NSString *fastPathSign, NSString *workDir);
// Same, but map of Mach-O filename -> entitlements plist path for binaries needing specific entitlements.
NSString *tm_sign_app_bundle_ents(NSString *appDir, NSString *fastPathSign, NSString *workDir, NSDictionary<NSString *, NSString *> *explicitEnts);
// Sign a single Mach-O with explicit entitlements (entsPath may be nil to preserve its own). Returns 0 on success.
int tm_sign_file(NSString *fastPathSign, NSString *machoPath, NSString *entsPath, NSString *workDir, NSString **log);
#endif
