#!/usr/bin/env bash
# Builds meowbrek2 Installer (rootless iphoneos-arm64 only — meowbrek2 needs rootless palera1n).
# The package carries TrollStore.tar (opa334/TrollStore release, MIT) so it can install TrollStore
# without the Safari/TrollHelperOTA method. If tipa/meowbrek2.tipa exists it is bundled too;
# otherwise the postinst downloads dora2ios' official meowbrek2 1.1.7 build on the device.
#
#   ./build.sh                      (downloads TrollStore.tar from GitHub if not cached)
#   TSTAR=/path/TrollStore.tar ./build.sh
set -euo pipefail
cd "$(dirname "$0")"
ID=com.mymculture.meowbrek2installer
VER=${VER:-1.0}
TS_VER=${TS_VER:-2.1.1}
TSTAR=${TSTAR:-cache/TrollStore.tar}
MBTIPA=../../tipa/meowbrek2.tipa
OUT=$PWD/out; rm -rf "$OUT" stage; mkdir -p "$OUT"

if [ ! -f "$TSTAR" ]; then
  mkdir -p cache
  curl -fsSL -o "$TSTAR" "https://github.com/opa334/TrollStore/releases/download/$TS_VER/TrollStore.tar"
fi

arch=iphoneos-arm64; prefix=/var/jb; root=stage/$arch
share="$root$prefix/usr/share/meowbrek2installer"
mkdir -p "$share" "$root/DEBIAN"
cp "$TSTAR" "$share/TrollStore.tar"
[ -f "$MBTIPA" ] && cp "$MBTIPA" "$share/meowbrek2.tipa"
sed "s|@PREFIX@|$prefix|" postinst.in > "$root/DEBIAN/postinst"
cat > "$root/DEBIAN/control" <<CTL
Package: $ID
Name: meowbrek2 Installer
Version: $VER
Architecture: $arch
Description: Installs TrollStore (if needed) and meowbrek2, so rootless palera1n can re-jailbreak without a computer.
Maintainer: MYM Culture
Author: MYM Culture
Section: Utilities
Depends: firmware (>= 15.0), firmware (<< 16.0), curl
CTL
find "$root" -type d -exec chmod 755 {} +
find "$root" -type f -exec chmod 644 {} +
chmod 755 "$root/DEBIAN/postinst"
dpkg-deb --root-owner-group -Zgzip -b "$root" "$OUT/${ID}_${VER}_${arch}.deb" >/dev/null
rm -rf stage
ls -la "$OUT"
