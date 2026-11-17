#!/usr/bin/env bash
# Builds the two Trollamine Installer programs for iOS (arm64):
#   out/TrollamineInstaller   - the installer app's main program
#   out/TrollamineKit.dylib   - the add-on library the installer builds into Trollamine
# Needs: clang + lld, an iPhoneOS SDK (15 or newer), and ldid to sign the results.
#   SDK=/path/to/iPhoneOS16.5.sdk LDID=/path/to/ldid ./build.sh
set -euo pipefail
cd "$(dirname "$0")"
SDK=${SDK:-/home/claude/build/sdks/iPhoneOS15.6.sdk}
LDID=${LDID:-ldid}
OUT=$PWD/out; rm -rf "$OUT"; mkdir -p "$OUT"
CC="clang -target arm64-apple-ios14.0 -isysroot $SDK -fobjc-arc -O2 -Wall -Wno-deprecated-declarations -Wno-unused-variable -Wno-unused-function -Wno-arc-performSelector-leaks -Wno-unguarded-availability-new -fuse-ld=lld -Wl,-adhoc_codesign"
FW="-framework UIKit -framework Foundation -framework CoreFoundation -framework UniformTypeIdentifiers -lz"
SHARED="tmsign.m tdzip.m tmzip.c machopatch.c"

$CC $FW -o "$OUT/TrollamineInstaller" main.m $SHARED
$CC -dynamiclib -install_name @executable_path/TrollamineKit.dylib $FW -o "$OUT/TrollamineKit.dylib" kit.m $SHARED

# The installer needs its entitlements; the library is signed without any.
"$LDID" -Sents.plist "$OUT/TrollamineInstaller"
"$LDID" -S "$OUT/TrollamineKit.dylib"
echo "Built: $OUT/TrollamineInstaller  $OUT/TrollamineKit.dylib"
