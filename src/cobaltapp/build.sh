#!/usr/bin/env bash
# Builds Cobalt.ipa: a normal, unsigned-for-distribution app (ad-hoc signed, no special entitlements)
# that any sideloader re-signs — AltStore, SideStore, Sideloadly, Benstore, TrollStore, etc.
#   SDK=/path/to/iPhoneOS14.5.sdk VER=1.0 ./build.sh
set -euo pipefail
cd "$(dirname "$0")"
ID=com.mymculture.cobalt
VER=${VER:-1.0}
SDK=${SDK:-/home/claude/build/sdks/iPhoneOS14.5.sdk}
OUT=$PWD/out; rm -rf "$OUT" stage; mkdir -p "$OUT"
APP=stage/Payload/Cobalt.app
mkdir -p "$APP"

clang -target arm64-apple-ios13.0 -isysroot "$SDK" -fobjc-arc -fmodules -Os -Wall -Wno-unused-function \
      -fuse-ld=lld -Wl,-adhoc_codesign -Wl,-dead_strip \
      -framework UIKit -framework Foundation -framework CoreGraphics -framework QuartzCore \
      main.m -o "$APP/Cobalt"

python3 makeicons.py ../../assets/cobalt-icon.png "$APP" >/dev/null

python3 - "$APP/Info.plist" "$ID" "$VER" <<'PY'
import plistlib, sys
path, bid, ver = sys.argv[1:4]
iphone = ["AppIcon20x20", "AppIcon29x29", "AppIcon40x40", "AppIcon60x60"]
ipad = ["AppIcon20x20", "AppIcon29x29", "AppIcon40x40", "AppIcon76x76", "AppIcon83.5x83.5"]
plistlib.dump({
    "CFBundleDevelopmentRegion": "en",
    "CFBundleDisplayName": "Cobalt",
    "CFBundleName": "Cobalt",
    "CFBundleExecutable": "Cobalt",
    "CFBundleIdentifier": bid,
    "CFBundleInfoDictionaryVersion": "6.0",
    "CFBundlePackageType": "APPL",
    "CFBundleShortVersionString": ver,
    "CFBundleVersion": ver,
    "CFBundleSupportedPlatforms": ["iPhoneOS"],
    "CFBundleIcons": {"CFBundlePrimaryIcon": {"CFBundleIconFiles": iphone, "CFBundleIconName": "AppIcon"}},
    "CFBundleIcons~ipad": {"CFBundlePrimaryIcon": {"CFBundleIconFiles": ipad, "CFBundleIconName": "AppIcon"}},
    "DTPlatformName": "iphoneos",
    "DTSDKName": "iphoneos14.5",
    "DTPlatformVersion": "14.5",
    "LSRequiresIPhoneOS": True,
    "LSApplicationQueriesSchemes": ["sileo", "zbra", "cydia", "apple-magnifier", "filza"],
    "MinimumOSVersion": "13.0",
    "UIDeviceFamily": [1, 2],
    "UILaunchScreen": {},
    "UIRequiredDeviceCapabilities": ["arm64"],
    "UIStatusBarStyle": "UIStatusBarStyleDefault",
    "UISupportedInterfaceOrientations": ["UIInterfaceOrientationPortrait"],
    "UISupportedInterfaceOrientations~ipad": ["UIInterfaceOrientationPortrait", "UIInterfaceOrientationPortraitUpsideDown",
                                             "UIInterfaceOrientationLandscapeLeft", "UIInterfaceOrientationLandscapeRight"],
    "ITSAppUsesNonExemptEncryption": False,
}, open(path, "wb"), fmt=plistlib.FMT_BINARY)
PY
printf 'APPL????' > "$APP/PkgInfo"
find stage -type d -exec chmod 755 {} +
find stage -type f -exec chmod 644 {} +
chmod 755 "$APP/Cobalt"
(cd stage && zip -qry -X "$OUT/Cobalt.ipa" Payload)
rm -rf stage
ls -la "$OUT"
