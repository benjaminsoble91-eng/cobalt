#!/usr/bin/env bash
# Builds BlobKeeper as two .debs: rootless (iphoneos-arm64, /var/jb) and rootful (iphoneos-arm, /).
# The app and its root helper are signed with their entitlements on the device by the postinst (ldid).
#   SDK=/path/to/iPhoneOS15.6.sdk ./build.sh
set -euo pipefail
cd "$(dirname "$0")"
ID=com.mymculture.blobkeeper
VER=${VER:-1.0}
SDK=${SDK:-/home/claude/build/sdks/iPhoneOS15.6.sdk}
OUT=$PWD/out; rm -rf "$OUT" stage; mkdir -p "$OUT"
CC="clang -target arm64-apple-ios14.0 -isysroot $SDK -Os -Wall -Wno-unused-function -fuse-ld=lld -Wl,-adhoc_codesign"
FW="-framework UIKit -framework Foundation -framework CoreFoundation -framework CoreGraphics -framework QuartzCore"

build() { # arch prefix
  local arch=$1 prefix=$2 root=stage/$1
  local app=$root$prefix/Applications/BlobKeeper.app
  local share=$root$prefix/usr/share/blobkeeper
  mkdir -p "$app" "$share" "$root$prefix/usr/libexec" "$root/DEBIAN"
  $CC -fobjc-arc -DJBROOT=\"$prefix\" $FW main.m -o "$app/BlobKeeper"
  $CC -framework CoreFoundation -framework IOKit helper.c -o "$root$prefix/usr/libexec/blobkeeper-helper"
  cp icons/*.png "$app/"
  cp ents.plist "$share/ents.plist"
  cp helper-ents.plist "$share/helper-ents.plist"
  python3 - "$app/Info.plist" "$ID" "$VER" <<'PY'
import plistlib, sys
path, bid, ver = sys.argv[1:4]
plistlib.dump({
    "CFBundleDevelopmentRegion": "en",
    "CFBundleDisplayName": "BlobKeeper",
    "CFBundleName": "BlobKeeper",
    "CFBundleExecutable": "BlobKeeper",
    "CFBundleIdentifier": bid,
    "CFBundleInfoDictionaryVersion": "6.0",
    "CFBundlePackageType": "APPL",
    "CFBundleShortVersionString": ver,
    "CFBundleVersion": ver,
    "CFBundleSupportedPlatforms": ["iPhoneOS"],
    "CFBundleIcons": {"CFBundlePrimaryIcon": {"CFBundleIconFiles": ["AppIcon29x29", "AppIcon40x40", "AppIcon60x60"]}},
    "CFBundleIcons~ipad": {"CFBundlePrimaryIcon": {"CFBundleIconFiles": ["AppIcon29x29", "AppIcon40x40", "AppIcon60x60", "AppIcon76x76", "AppIcon83.5x83.5"]}},
    "LSRequiresIPhoneOS": True,
    "MinimumOSVersion": "14.0",
    "UIDeviceFamily": [1, 2],
    "UILaunchScreen": {},
    "UIRequiredDeviceCapabilities": ["arm64"],
    "UIStatusBarStyle": "UIStatusBarStyleLightContent",
    "UIViewControllerBasedStatusBarAppearance": True,
    "UIFileSharingEnabled": True,
    "UISupportedInterfaceOrientations": ["UIInterfaceOrientationPortrait"],
    "UISupportedInterfaceOrientations~ipad": ["UIInterfaceOrientationPortrait", "UIInterfaceOrientationPortraitUpsideDown",
                                             "UIInterfaceOrientationLandscapeLeft", "UIInterfaceOrientationLandscapeRight"],
}, open(path, "wb"), fmt=plistlib.FMT_BINARY)
PY
  printf 'APPL????' > "$app/PkgInfo"
  sed "s|@PREFIX@|$prefix|" postinst.in > "$root/DEBIAN/postinst"
  sed "s|@PREFIX@|$prefix|" prerm.in > "$root/DEBIAN/prerm"
  cat > "$root/DEBIAN/control" <<CTL
Package: $ID
Name: BlobKeeper
Version: $VER
Architecture: $arch
Description: Save your device's onboard blob in one tap. Finds the ticket from your last restore or update, reads the generator, and saves a .shsh2 you can share or keep in Files.
Maintainer: MYM Culture
Author: MYM Culture
Section: Utilities
Depends: firmware (>= 14.0), ldid
CTL
  find "$root" -type d -exec chmod 755 {} +
  find "$root" -type f -exec chmod 644 {} +
  chmod 755 "$app/BlobKeeper" "$root/DEBIAN/postinst" "$root/DEBIAN/prerm"
  chmod 4755 "$root$prefix/usr/libexec/blobkeeper-helper"
  dpkg-deb --root-owner-group -Zgzip -b "$root" "$OUT/${ID}_${VER}_${arch}.deb" >/dev/null
}
build iphoneos-arm64 /var/jb
build iphoneos-arm   ""
rm -rf stage
ls -la "$OUT"
