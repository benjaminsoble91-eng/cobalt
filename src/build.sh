#!/usr/bin/env bash
# Builds the Cobalt tweaks as rootless (iphoneos-arm64) and rootful (iphoneos-arm) .debs.
# Rootless installs under /var/jb; rootful installs at /. DoubleDose is rootless-only (Dopamine).
set -euo pipefail
cd "$(dirname "$0")"
SDK=/home/claude/build/sdks/iPhoneOS15.6.sdk
OUT=$PWD/out; rm -rf "$OUT" stage; mkdir -p "$OUT"
CC="clang -target arm64-apple-ios14.0 -isysroot $SDK -fobjc-arc -fmodules -Os -Wall -Wno-unused-function -fuse-ld=lld -Wl,-adhoc_codesign"
FW="-framework UIKit -framework Foundation -framework CoreGraphics -framework CoreFoundation -framework QuartzCore"

ARCH=iphoneos-arm64; JB=/var/jb   # current variant, switched below
build() { # dir Name id version section depends desc
  local dir=$1 name=$2 id=$3 ver=$4 section=$5 dep=$6 desc=$7
  local root=stage/$ARCH/$id; local jb=$root$JB
  mkdir -p $jb/Library/MobileSubstrate/DynamicLibraries $jb/Library/PreferenceLoader/Preferences $root/DEBIAN
  $CC -DJBROOT=\"$JB\" -dynamiclib -install_name $JB/Library/MobileSubstrate/DynamicLibraries/$name.dylib $FW $dir/Tweak.m \
      -o $jb/Library/MobileSubstrate/DynamicLibraries/$name.dylib
  cp $dir/Filter.plist $jb/Library/MobileSubstrate/DynamicLibraries/$name.plist
  cp $dir/Prefs.plist $jb/Library/PreferenceLoader/Preferences/$name.plist
  if [ -f $dir/helper.c ]; then
    local helper_name=${name,,}-helper   # lowercase Name + -helper
    mkdir -p $jb/usr/libexec
    $CC $dir/helper.c -o $jb/usr/libexec/$helper_name
    chmod 4755 $jb/usr/libexec/$helper_name
  fi
  if [ -f $dir/postinst ]; then sed "s|@SH@|$JB/bin/sh|" $dir/postinst > $root/DEBIAN/postinst; fi
  cat > $root/DEBIAN/control <<CTL
Package: $id
Name: $name
Version: $ver
Architecture: $ARCH
Description: $desc
Maintainer: MYM Culture
Author: MYM Culture
Section: $section
Depends: $dep
CTL
  find $root -type d -exec chmod 755 {} +
  find $root -type f ! -name '*-helper' ! -name '*.dylib' -exec chmod 644 {} +
  chmod 755 $jb/Library/MobileSubstrate/DynamicLibraries/$name.dylib
  [ -f $root/DEBIAN/postinst ] && chmod 755 $root/DEBIAN/postinst
  dpkg-deb --root-owner-group -Zgzip -b $root $OUT/${id}_${ver}_$ARCH.deb >/dev/null
}
D="mobilesubstrate (>= 0.9.5000), preferenceloader, firmware (>= 14.0)"
for variant in "iphoneos-arm64 /var/jb" "iphoneos-arm "; do
  read -r ARCH JB <<<"$variant"; JB=${JB:-}
  build iconswap  IconSwap  com.mymculture.iconswap  1.1 Tweaks "$D" "In jiggle mode, tap one app and then another to swap their positions."
  build powerplus PowerPlus com.mymculture.powerplus 1.2.1 Tweaks "$D" "Adds slide to respring and slide to reboot userspace to the power-off screen."
  build bartext   BarText   com.mymculture.bartext   1.0.2 Tweaks "$D" "Replace the carrier name, signal bars, Wi-Fi bars and network badge in the status bar with your own text."
  [ "$ARCH" = iphoneos-arm64 ] && build doubledose DoubleDose com.mymculture.doubledose 1.0.1 Tweaks "$D" "Unlocks the Jailbreak button in a duplicated Dopamine while already jailbroken."
  build panicbutton PanicButton com.mymculture.panicbutton 1.0.1 Tweaks "$D" "Triggers a true kernel panic for testing. Produces a panic-full log."
  build rootrun    RootRun    com.mymculture.rootrun    1.0.1 Tweaks "$D" "Make the apps you choose launch as root."
  build gridsize   GridSize   com.mymculture.gridsize   1.1   Tweaks "$D" "Choose how many apps go in each Home Screen row. Icons and widgets resize to fit."
done
ls -la $OUT

# Print the APT fields for each freshly built .deb so you can paste them into Packages.in
# (and copy the .deb into ../debs/). Covers the TODO placeholders on new packages like RootRun.
echo; echo "== Packages.in fields =="
for f in "$OUT"/*.deb; do
  sz=$(stat -c%s "$f" 2>/dev/null || stat -f%z "$f")
  md5=$( (md5sum "$f" 2>/dev/null || md5 -q "$f") | awk '{print $1}')
  sha1=$( (sha1sum "$f" 2>/dev/null || shasum -a 1 "$f") | awk '{print $1}')
  sha256=$( (sha256sum "$f" 2>/dev/null || shasum -a 256 "$f") | awk '{print $1}')
  echo "--- $(basename "$f")"
  echo "Size: $sz"; echo "MD5sum: $md5"; echo "SHA1: $sha1"; echo "SHA256: $sha256"
done
