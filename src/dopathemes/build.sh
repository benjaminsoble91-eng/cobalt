#!/usr/bin/env bash
# Builds DopaThemes (rootless only - Dopamine is rootless). The package carries the themes plus
# dopathemes-patch, and its postinst writes them into the installed Dopamine apps (works without a
# jailbreak).
set -euo pipefail
cd "$(dirname "$0")"
ID=com.mymculture.dopathemes
VER=${VER:-2.1}
SDK=/home/claude/build/sdks/iPhoneOS15.6.sdk
CC="clang -target arm64-apple-ios15.0 -isysroot $SDK -fobjc-arc -fmodules -Os -Wall -fuse-ld=lld -Wl,-adhoc_codesign"
OUT=$PWD/out; rm -rf "$OUT" stage; mkdir -p "$OUT"
ARCH=iphoneos-arm64 PREFIX=/var/jb
root=stage/$ARCH; share=$root$PREFIX/Library/DopaThemes
mkdir -p "$share/icons" "$root$PREFIX/usr/libexec" "$root/DEBIAN"
cp res/Themes.plist res/dopathemes_*.jpg "$share/"
python3 makeicons.py res "$share/icons"
$CC -framework Foundation patch.m -o "$root$PREFIX/usr/libexec/dopathemes-patch"
sed "s|@PREFIX@|$PREFIX|" postinst.in > "$root/DEBIAN/postinst"
sed "s|@PREFIX@|$PREFIX|" prerm.in > "$root/DEBIAN/prerm"
cat > "$root/DEBIAN/control" <<CTL
Package: $ID
Name: DopaThemes
Version: $VER
Architecture: $ARCH
Description: Adds new themes to Dopamine, each with its own icon. Built into the app, so they stay without a jailbreak.
Maintainer: MYM Culture
Author: MYM Culture
Section: Themes
Depends: firmware (>= 15.0)
CTL
find "$root" -type d -exec chmod 755 {} +
find "$root" -type f -exec chmod 644 {} +
chmod 755 "$root/DEBIAN/postinst" "$root/DEBIAN/prerm" "$root$PREFIX/usr/libexec/dopathemes-patch"
dpkg-deb --root-owner-group -Zgzip -b "$root" "$OUT/${ID}_${VER}_${ARCH}.deb" >/dev/null
rm -rf stage
ls -la "$OUT"
