#!/usr/bin/env bash
# Builds Benstore Installer as two .debs (rootless iphoneos-arm64 and rootful iphoneos-arm) and
# tipa/Benstore.tipa for TrollStore's Get button on the storefront.
#
# Takes the newest Benstore.ipa from the benstore repo (github.com/benjaminsoble91-eng/benstore),
# or the file given as the first argument, adds the entitlements Benstore needs outside an Apple ID
# signature (see addents.py), and packs it. The package version is Benstore's own version, so
# re-running this after a Benstore release gives Cobalt the matching installer.
#
#   ./build.sh                 # newest Benstore from the benstore repo
#   ./build.sh path/to/Benstore.ipa
set -euo pipefail
cd "$(dirname "$0")"
ID=com.mymculture.benstoreinstaller
OUT=$PWD/out; rm -rf "$OUT" stage work; mkdir -p "$OUT" work

if [ $# -ge 1 ]; then
  cp "$1" work/Benstore.ipa
else
  git clone -q --depth 1 https://github.com/benjaminsoble91-eng/benstore work/benstore
  cp work/benstore/Benstore.ipa work/Benstore.ipa
fi

(cd work && unzip -q Benstore.ipa)
APP=work/Payload/Benstore.app
VER=${VER:-$(python3 -c "import plistlib,sys;print(plistlib.load(open(sys.argv[1],'rb'))['CFBundleShortVersionString'])" "$APP/Info.plist")}
python3 addents.py "$APP" work/ents.plist

# TrollStore copy (also served as tipa/Benstore.tipa).
(cd work && rm -f Benstore.tipa && zip -qry -X Benstore.tipa Payload)
cp work/Benstore.tipa ../../tipa/Benstore.tipa

build() { # arch prefix
  local arch=$1 prefix=$2 root=stage/$1
  local share=$root$prefix/usr/share/benstoreinstaller
  mkdir -p "$share" "$root/DEBIAN"
  cp work/Benstore.tipa "$share/Benstore.tipa"
  cp -R "$APP" "$share/"
  cp work/ents.plist "$share/ents.plist"
  sed "s|@PREFIX@|$prefix|" postinst.in > "$root/DEBIAN/postinst"
  sed "s|@PREFIX@|$prefix|" prerm.in > "$root/DEBIAN/prerm"
  cat > "$root/DEBIAN/control" <<CTL
Package: $ID
Name: Benstore Installer
Version: $VER
Architecture: $arch
Description: Installs Benstore through TrollStore so it never expires, or as a jailbreak app when TrollStore is not installed.
Maintainer: MYM Culture
Author: MYM Culture
Section: Utilities
Depends: firmware (>= 14.0), ldid
CTL
  find "$root" -type d -exec chmod 755 {} +
  find "$root" -type f -exec chmod 644 {} +
  chmod 755 "$root/DEBIAN/postinst" "$root/DEBIAN/prerm" "$share/Benstore.app/Benstore"
  dpkg-deb --root-owner-group -Zgzip -b "$root" "$OUT/${ID}_${VER}_${arch}.deb" >/dev/null
}
build iphoneos-arm64 /var/jb
build iphoneos-arm   ""
rm -rf stage work
ls -la "$OUT"
