#!/usr/bin/env bash
# Builds TrollDuplicator Installer as two .debs (rootless iphoneos-arm64 and rootful iphoneos-arm).
# The package carries tipa/TrollDuplicator.tipa; its postinst installs it through TrollStore
# and then removes the package itself.
set -euo pipefail
cd "$(dirname "$0")"
ID=com.mymculture.trollduplicatorinstaller
VER=${VER:-1.0}
TIPA=../../tipa/TrollDuplicator.tipa
OUT=$PWD/out; rm -rf "$OUT" stage; mkdir -p "$OUT"

build() { # arch prefix
  local arch=$1 prefix=$2 root=stage/$1
  mkdir -p "$root$prefix/usr/share/trollduplicatorinstaller" "$root/DEBIAN"
  cp "$TIPA" "$root$prefix/usr/share/trollduplicatorinstaller/TrollDuplicator.tipa"
  sed "s|@PREFIX@|$prefix|" postinst.in > "$root/DEBIAN/postinst"
  cat > "$root/DEBIAN/control" <<CTL
Package: $ID
Name: TrollDuplicator Installer
Version: $VER
Architecture: $arch
Description: Installs TrollDuplicator through TrollStore, then removes itself so only TrollDuplicator is left.
Maintainer: MYM Culture
Author: MYM Culture
Section: Utilities
Depends: firmware (>= 14.0)
CTL
  find "$root" -type d -exec chmod 755 {} +
  find "$root" -type f -exec chmod 644 {} +
  chmod 755 "$root/DEBIAN/postinst"
  dpkg-deb --root-owner-group -Zgzip -b "$root" "$OUT/${ID}_${VER}_${arch}.deb" >/dev/null
}
build iphoneos-arm64 /var/jb
build iphoneos-arm   ""
rm -rf stage
ls -la "$OUT"
