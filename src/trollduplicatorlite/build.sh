#!/usr/bin/env bash
# Builds TrollDuplicator Lite as two .debs: rootless (iphoneos-arm64, /var/jb/Applications) and
# rootful (iphoneos-arm, /Applications). The app is signed with its entitlements on the device by
# the postinst (ldid), because those entitlements only work on a jailbreak anyway.
#   SDK=/path/to/iPhoneOS14.5.sdk ./build.sh
set -euo pipefail
cd "$(dirname "$0")"
ID=com.mymculture.trollduplicatorlite
VER=${VER:-1.3}
SDK=${SDK:-/home/claude/build/sdks/iPhoneOS14.5.sdk}
OUT=$PWD/out; rm -rf "$OUT" stage; mkdir -p "$OUT"
CC="clang -target arm64-apple-ios13.0 -isysroot $SDK -fobjc-arc -Os -Wall -Wno-unused-function -fuse-ld=lld -Wl,-adhoc_codesign"
FW="-framework UIKit -framework Foundation -framework CoreFoundation -lz"

build() { # arch prefix
  local arch=$1 prefix=$2 root=stage/$1
  local app=$root$prefix/Applications/TrollDuplicatorLite.app
  local share=$root$prefix/usr/share/trollduplicatorlite
  mkdir -p "$app" "$share" "$root/DEBIAN"
  $CC -DJBROOT=\"$prefix\" $FW main.m -o "$app/TrollDuplicatorLite"
  cp icons/*.png "$app/"
  cp ents.plist "$share/ents.plist"
  python3 - "$app/Info.plist" "$ID" "$VER" <<'PY'
import plistlib, sys
path, bid, ver = sys.argv[1:4]
plistlib.dump({
    "CFBundleDevelopmentRegion": "en",
    "CFBundleDisplayName": "TD Lite",
    "CFBundleName": "TrollDuplicator Lite",
    "CFBundleExecutable": "TrollDuplicatorLite",
    "CFBundleIdentifier": bid,
    "CFBundleInfoDictionaryVersion": "6.0",
    "CFBundlePackageType": "APPL",
    "CFBundleShortVersionString": ver,
    "CFBundleVersion": ver,
    "CFBundleSupportedPlatforms": ["iPhoneOS"],
    "CFBundleIcons": {"CFBundlePrimaryIcon": {"CFBundleIconFiles": ["AppIcon29x29", "AppIcon40x40", "AppIcon60x60"]}},
    "CFBundleIcons~ipad": {"CFBundlePrimaryIcon": {"CFBundleIconFiles": ["AppIcon29x29", "AppIcon40x40", "AppIcon60x60", "AppIcon76x76", "AppIcon83.5x83.5"]}},
    "LSRequiresIPhoneOS": True,
    "MinimumOSVersion": "13.0",
    "UIDeviceFamily": [1, 2],
    "UILaunchScreen": {},
    "UIRequiredDeviceCapabilities": ["arm64"],
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
Name: TrollDuplicator Lite
Version: $VER
Architecture: $arch
Description: Duplicate your apps through TrollStore Lite. Copies get their own name and data. No AppSync needed.
Maintainer: MYM Culture
Author: MYM Culture
Section: Utilities
Depends: firmware (>= 14.0), ldid, com.opa334.trollstorelite
CTL
  find "$root" -type d -exec chmod 755 {} +
  find "$root" -type f -exec chmod 644 {} +
  chmod 755 "$app/TrollDuplicatorLite" "$root/DEBIAN/postinst" "$root/DEBIAN/prerm"
  dpkg-deb --root-owner-group -Zgzip -b "$root" "$OUT/${ID}_${VER}_${arch}.deb" >/dev/null
}
build iphoneos-arm64 /var/jb
build iphoneos-arm   ""
rm -rf stage
ls -la "$OUT"
