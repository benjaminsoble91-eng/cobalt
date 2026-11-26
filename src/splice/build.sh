#!/usr/bin/env bash
# Builds Splice:
#   out/Splice.tipa                                   TrollStore (and any sideloader - it's a normal app)
#   out/com.mymculture.splice_<ver>_iphoneos-arm64.deb  rootless jailbreak app (/var/jb/Applications)
#   out/com.mymculture.splice_<ver>_iphoneos-arm.deb    rootful jailbreak app (/Applications)
# The .deb app is signed on the device by its postinst (ldid), like TrollDuplicator Lite.
#   SDK=/path/to/iPhoneOS14.5.sdk ./build.sh
set -euo pipefail
cd "$(dirname "$0")"
ID=com.mymculture.splice
VER=${VER:-1.1}
SDK=${SDK:-/home/claude/build/sdks/iPhoneOS14.5.sdk}
OUT=$PWD/out; rm -rf "$OUT" stage; mkdir -p "$OUT"
CC="clang -isysroot $SDK -fobjc-arc -Os -Wall -Wno-unused-function -fuse-ld=lld -Wl,-adhoc_codesign"
FW="-framework UIKit -framework Foundation -framework CoreGraphics -framework QuartzCore -framework MobileCoreServices -framework Security -larchive"

# The substrate shim that goes into every modded app (iOS 12+ so it fits old apps too).
mkdir -p stage/shim/CydiaSubstrate.framework
$CC -target arm64-apple-ios12.0 -fvisibility=hidden -dynamiclib -framework Foundation \
    -install_name @executable_path/Frameworks/CydiaSubstrate.framework/CydiaSubstrate \
    -compatibility_version 1.0 -current_version 1.0 \
    shim/Shim.m -o stage/shim/CydiaSubstrate.framework/CydiaSubstrate
python3 - stage/shim/CydiaSubstrate.framework/Info.plist "$VER" <<'PY'
import plistlib, sys
plistlib.dump({"CFBundleExecutable": "CydiaSubstrate", "CFBundleIdentifier": "com.mymculture.splice.substrate",
    "CFBundleName": "CydiaSubstrate", "CFBundlePackageType": "FMWK", "CFBundleInfoDictionaryVersion": "6.0",
    "CFBundleShortVersionString": sys.argv[2], "CFBundleVersion": sys.argv[2], "MinimumOSVersion": "12.0",
    "CFBundleSupportedPlatforms": ["iPhoneOS"]}, open(sys.argv[1], "wb"), fmt=plistlib.FMT_BINARY)
PY

[ -f icons/AppIcon60x60@2x.png ] || python3 makeicons.py icons

make_app() { # dir jbroot
  local app=$1 jb=$2
  mkdir -p "$app/Shim"
  $CC -target arm64-apple-ios13.0 -DJBROOT=\"$jb\" $FW main.m Engine.m Library.m machopatch.c -o "$app/Splice"
  cp -R stage/shim/CydiaSubstrate.framework "$app/Shim/"
  cp icons/AppIcon*.png "$app/"
  python3 - "$app/Info.plist" "$ID" "$VER" <<'PY'
import plistlib, sys
path, bid, ver = sys.argv[1:4]
def utype(uti, desc, exts, conforms):
    return {"UTTypeIdentifier": uti, "UTTypeDescription": desc, "UTTypeConformsTo": conforms,
            "UTTypeTagSpecification": {"public.filename-extension": exts}}
plistlib.dump({
    "CFBundleDevelopmentRegion": "en",
    "CFBundleDisplayName": "Splice",
    "CFBundleName": "Splice",
    "CFBundleExecutable": "Splice",
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
    "UIFileSharingEnabled": True,
    "LSSupportsOpeningDocumentsInPlace": True,
    "CFBundleDocumentTypes": [
        {"CFBundleTypeName": "iOS App", "CFBundleTypeRole": "Viewer", "LSHandlerRank": "Alternate",
         "LSItemContentTypes": ["com.apple.itunes.ipa", "com.mymculture.splice.tipa"]},
        {"CFBundleTypeName": "Tweak", "CFBundleTypeRole": "Viewer", "LSHandlerRank": "Alternate",
         "LSItemContentTypes": ["org.debian.deb-archive", "com.apple.mach-o-dylib"]},
    ],
    "UTImportedTypeDeclarations": [
        utype("com.apple.itunes.ipa", "iOS App", ["ipa"], ["public.zip-archive", "public.data"]),
        utype("com.mymculture.splice.tipa", "TrollStore App", ["tipa"], ["public.zip-archive", "public.data"]),
        utype("org.debian.deb-archive", "Debian Package", ["deb"], ["public.archive", "public.data"]),
        utype("com.apple.mach-o-dylib", "Dynamic Library", ["dylib"], ["public.executable", "public.data"]),
    ],
}, open(path, "wb"), fmt=plistlib.FMT_BINARY)
PY
  printf 'APPL????' > "$app/PkgInfo"
}

# TrollStore / sideload build
make_app stage/tipa/Payload/Splice.app ""
(cd stage/tipa && find . -exec touch -h -d '2026-01-01 00:00:00' {} + && zip -qry -X "$OUT/Splice.tipa" Payload)

# Jailbreak .debs
build_deb() { # arch prefix
  local arch=$1 prefix=$2 root=stage/$1
  local app=$root$prefix/Applications/Splice.app share=$root$prefix/usr/share/splice
  make_app "$app" "$prefix"
  mkdir -p "$share" "$root/DEBIAN"
  cp ents.plist "$share/ents.plist"
  sed "s|@PREFIX@|$prefix|" postinst.in > "$root/DEBIAN/postinst"
  sed "s|@PREFIX@|$prefix|" prerm.in > "$root/DEBIAN/prerm"
  cat > "$root/DEBIAN/control" <<CTL
Package: $ID
Name: Splice
Version: $VER
Architecture: $arch
Description: Drop in a decrypted app and its tweaks, get the full modded app back as an .ipa you can install without a jailbreak.
Maintainer: MYM Culture
Author: MYM Culture
Section: Utilities
Depends: firmware (>= 13.0), ldid
CTL
  find "$root" -type d -exec chmod 755 {} +
  find "$root" -type f -exec chmod 644 {} +
  chmod 755 "$app/Splice" "$app/Shim/CydiaSubstrate.framework/CydiaSubstrate" "$root/DEBIAN/postinst" "$root/DEBIAN/prerm"
  dpkg-deb --root-owner-group -Zgzip -b "$root" "$OUT/${ID}_${VER}_${arch}.deb" >/dev/null
}
build_deb iphoneos-arm64 /var/jb
build_deb iphoneos-arm   ""
rm -rf stage
ls -la "$OUT"
