#!/usr/bin/env bash
# Optional: bake an absolute base URL into the APT index.
# The repo works in Sileo with relative paths out of the box; run this only if
# you want absolute Icon/Depiction URLs (better compatibility with Zebra/Cydia).
#
#   ./seturl.sh https://yourname.github.io/cobalt
#
set -e
BASE="${1%/}"
if [ -z "$BASE" ]; then
  echo "usage: ./seturl.sh https://yourname.github.io/cobalt"; exit 1
fi
cd "$(dirname "$0")"

# rebuild Packages from the pristine template, then make the two paths absolute.
# Rootful (iphoneos-arm) stanzas are written before rootless (iphoneos-arm64) ones for each
# package: Sileo 2.3 and older (Odyssey, Taurine, Chimera...) ignore Architecture and keep the
# FIRST stanza when two have the same version, then hand only that one to APT, so a rootless
# stanza first means "Unable to locate package" on rootful jailbreaks. Sileo 2.4+ filters by
# architecture, so this order is right for every version.
awk 'BEGIN { RS = ""; ORS = "\n\n" }
     { pkg = ""; arch = ""
       n = split($0, lines, "\n")
       for (i = 1; i <= n; i++) {
         if (lines[i] ~ /^Package: /) pkg = substr(lines[i], 10)
         if (lines[i] ~ /^Architecture: /) arch = substr(lines[i], 15)
       }
       if (!(pkg in seen)) { seen[pkg] = 1; order[++count] = pkg }
       if (arch == "iphoneos-arm") rootful[pkg] = rootful[pkg] $0 ORS
       else other[pkg] = other[pkg] $0 ORS }
     END { for (i = 1; i <= count; i++) printf "%s%s", rootful[order[i]], other[order[i]] }' Packages.in > Packages
# Icon:/Depiction:/SileoDepiction: lines currently hold relative paths -> prefix with BASE
sed -i.bak -E "s#^(Icon: )(assets/)#\\1${BASE//#/\\#}/\\2#; s#^((Sileo)?Depiction: )(depictions/)#\\1${BASE//#/\\#}/\\3#" Packages
rm -f Packages.bak

gzip -9kf Packages
bzip2 -9kf Packages

# portable hash helpers (Linux coreutils OR macOS/BSD)
_sha(){ if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'; else shasum -a 256 "$1" | awk '{print $1}'; fi; }
_md5(){ if command -v md5sum   >/dev/null 2>&1; then md5sum   "$1" | awk '{print $1}'; else md5 -q "$1"; fi; }
_sz(){  if stat -c%s "$1" >/dev/null 2>&1; then stat -c%s "$1"; else stat -f%z "$1"; fi; }

{
  printf 'Origin: Cobalt\nLabel: Cobalt\nSuite: stable\nVersion: 1.0\nCodename: cobalt\n'
  printf 'Date: %s\n' "$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S UTC')"
  printf 'Architectures: iphoneos-arm64 iphoneos-arm\nComponents: main\n'
  printf 'Description: Cobalt - a hand-built source for jailbreak tweaks and TrollStore apps.\n'
  printf 'MD5Sum:\n'
  for f in Packages Packages.gz Packages.bz2; do printf ' %s %s %s\n' "$(_md5 "$f")" "$(_sz "$f")" "$f"; done
  printf 'SHA256:\n'
  for f in Packages Packages.gz Packages.bz2; do printf ' %s %s %s\n' "$(_sha "$f")" "$(_sz "$f")" "$f"; done
} > Release

echo "Baked base URL: $BASE"
echo "Updated: Packages, Packages.gz, Packages.bz2, Release"
