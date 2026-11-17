#!/usr/bin/env bash
# Builds the three Cobalt tweaks as rootless (iphoneos-arm64) .debs.
set -euo pipefail
cd "$(dirname "$0")"
SDK=/home/claude/build/sdks/iPhoneOS15.6.sdk
OUT=$PWD/out; rm -rf "$OUT" stage; mkdir -p "$OUT"
CC="clang -target arm64-apple-ios14.0 -isysroot $SDK -fobjc-arc -fmodules -Os -Wall -Wno-unused-function -fuse-ld=lld -Wl,-adhoc_codesign"
FW="-framework UIKit -framework Foundation -framework CoreGraphics -framework CoreFoundation -framework QuartzCore"

build() { # dir Name id version section depends desc
  local dir=$1 name=$2 id=$3 ver=$4 section=$5 dep=$6 desc=$7
  local root=stage/$id; local jb=$root/var/jb
  mkdir -p $jb/Library/MobileSubstrate/DynamicLibraries $jb/Library/PreferenceLoader/Preferences $root/DEBIAN
  $CC -dynamiclib -install_name /var/jb/Library/MobileSubstrate/DynamicLibraries/$name.dylib $FW $dir/Tweak.m \
      -o $jb/Library/MobileSubstrate/DynamicLibraries/$name.dylib
  cp $dir/Filter.plist $jb/Library/MobileSubstrate/DynamicLibraries/$name.plist
  cp $dir/Prefs.plist $jb/Library/PreferenceLoader/Preferences/$name.plist
  if [ -f $dir/helper.c ]; then
    mkdir -p $jb/usr/libexec
    $CC $dir/helper.c -o $jb/usr/libexec/powerplus-helper
    chmod 4755 $jb/usr/libexec/powerplus-helper
  fi
  if [ -f $dir/postinst ]; then cp $dir/postinst $root/DEBIAN/postinst; fi
  cat > $root/DEBIAN/control <<CTL
Package: $id
Name: $name
Version: $ver
Architecture: iphoneos-arm64
Description: $desc
Maintainer: MYM Culture
Author: MYM Culture
Section: $section
Depends: $dep
CTL
  find $root -type d -exec chmod 755 {} +
  find $root -type f ! -name powerplus-helper ! -name '*.dylib' -exec chmod 644 {} +
  chmod 755 $jb/Library/MobileSubstrate/DynamicLibraries/$name.dylib
  [ -f $root/DEBIAN/postinst ] && chmod 755 $root/DEBIAN/postinst
  dpkg-deb --root-owner-group -Zgzip -b $root $OUT/${id}_${ver}_iphoneos-arm64.deb >/dev/null
}
D="mobilesubstrate (>= 0.9.5000), preferenceloader, firmware (>= 14.0)"
build iconswap  IconSwap  com.mymculture.iconswap  1.1 Tweaks "$D" "In jiggle mode, tap one app and then another to swap their positions."
build powerplus PowerPlus com.mymculture.powerplus 1.2 Tweaks "$D" "Adds slide to respring and slide to reboot userspace to the power-off screen."
build bartext   BarText   com.mymculture.bartext   1.0.1 Tweaks "$D" "Replace the carrier name, signal bars, Wi-Fi bars and network badge in the status bar with your own text."
ls -la $OUT
