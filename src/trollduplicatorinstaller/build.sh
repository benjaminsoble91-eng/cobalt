#!/usr/bin/env bash
# Builds TrollDuplicator Installer as two .debs (rootless iphoneos-arm64 and rootful iphoneos-arm).
# The package carries tipa/TrollDuplicator.tipa plus a patched TrollDuplicator.app (see jbpatch.py).
# Its postinst installs the .tipa through TrollStore and then removes the package itself, or, when
# TrollStore isn't installed, signs the patched app with ldid and installs it as a jailbreak app.
set -euo pipefail
cd "$(dirname "$0")"
ID=com.mymculture.trollduplicatorinstaller
VER=${VER:-1.2}
TIPA=../../tipa/TrollDuplicator.tipa
OUT=$PWD/out; rm -rf "$OUT" stage jbapp; mkdir -p "$OUT"

# Jailbreak-app copy: unpack the .tipa and patch it to run without TrollStore, down to iOS 13.
mkdir -p jbapp && (cd jbapp && unzip -q "../$TIPA")
python3 jbpatch.py jbapp/Payload/TrollDuplicator.app jbapp/ents.plist

build() { # arch prefix
  local arch=$1 prefix=$2 root=stage/$1
  mkdir -p "$root$prefix/usr/share/trollduplicatorinstaller" "$root/DEBIAN"
  cp "$TIPA" "$root$prefix/usr/share/trollduplicatorinstaller/TrollDuplicator.tipa"
  cp -R jbapp/Payload/TrollDuplicator.app "$root$prefix/usr/share/trollduplicatorinstaller/"
  cp jbapp/ents.plist "$root$prefix/usr/share/trollduplicatorinstaller/ents.plist"
  sed "s|@PREFIX@|$prefix|" postinst.in > "$root/DEBIAN/postinst"
  sed "s|@PREFIX@|$prefix|" prerm.in > "$root/DEBIAN/prerm"
  cat > "$root/DEBIAN/control" <<CTL
Package: $ID
Name: TrollDuplicator Installer
Version: $VER
Architecture: $arch
Description: Installs TrollDuplicator through TrollStore, or as a jailbreak app when TrollStore is not installed.
Maintainer: MYM Culture
Author: MYM Culture
Section: Utilities
Depends: firmware (>= 13.0), ldid
CTL
  find "$root" -type d -exec chmod 755 {} +
  find "$root" -type f -exec chmod 644 {} +
  chmod 755 "$root/DEBIAN/postinst" "$root/DEBIAN/prerm"
  chmod 755 "$root$prefix/usr/share/trollduplicatorinstaller/TrollDuplicator.app/TrollDuplicator"
  dpkg-deb --root-owner-group -Zgzip -b "$root" "$OUT/${ID}_${VER}_${arch}.deb" >/dev/null
}
build iphoneos-arm64 /var/jb
build iphoneos-arm   ""
rm -rf stage jbapp
ls -la "$OUT"
