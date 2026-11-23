#!/usr/bin/env python3
"""Give the Benstore binary the entitlements it needs outside an Apple ID signature.

Benstore.ipa ships ad-hoc signed with no entitlements: when Benstore is installed from the Mac
installer, the Apple ID signature adds application-identifier and keychain-access-groups from the
provisioning profile. Installed through TrollStore or as a jailbreak app there is no profile, and
without those two entitlements every keychain call fails (errSecMissingEntitlement), so Benstore
could never keep the Apple ID password it re-signs apps with.

This script, on the copy only:
  1. writes the entitlements to ents.plist (used by ldid on the device for the jailbreak copy),
  2. adds them as an entitlements blob to the existing code signature. TrollStore reads the
     entitlements from that blob and keeps them when it re-signs the app on install, so the
     CodeDirectory hashes don't need to match here.

usage: addents.py <Benstore.app> <ents.plist out>
"""
import plistlib
import struct
import sys

LC_SEGMENT_64 = 0x19
LC_CODE_SIGNATURE = 0x1D
CSMAGIC_EMBEDDED_SIGNATURE = 0xFADE0CC0
CSMAGIC_EMBEDDED_ENTITLEMENTS = 0xFADE7171
CSSLOT_ENTITLEMENTS = 5
PAGE = 0x4000

TEAM = "MYMCULTURE"  # placeholder team ID (10 chars); there's no real team without an Apple ID
BUNDLE = "com.mymculture.benstore"
ENTS = {
    "application-identifier": f"{TEAM}.{BUNDLE}",
    "com.apple.developer.team-identifier": TEAM,
    "keychain-access-groups": [f"{TEAM}.{BUNDLE}"],
    "get-task-allow": False,
}


def main(app, ents_out):
    exe = f"{app}/Benstore"
    d = bytearray(open(exe, "rb").read())
    if struct.unpack_from("<I", d, 0)[0] != 0xFEEDFACF:
        sys.exit("expected a thin arm64 Mach-O")
    ncmds = struct.unpack_from("<I", d, 16)[0]
    p = 32
    sig_cmd = linkedit = None
    for _ in range(ncmds):
        cmd, size = struct.unpack_from("<II", d, p)
        if cmd == LC_CODE_SIGNATURE:
            sig_cmd = p
        elif cmd == LC_SEGMENT_64 and bytes(d[p + 8:p + 24]).rstrip(b"\0") == b"__LINKEDIT":
            linkedit = p
        p += size
    if sig_cmd is None or linkedit is None:
        sys.exit("no code signature / __LINKEDIT")

    so, ss = struct.unpack_from("<II", d, sig_cmd + 8)
    le_fo, le_fs = struct.unpack_from("<QQ", d, linkedit + 40)
    if so + ss != len(d) or le_fo + le_fs != len(d):
        sys.exit("signature isn't at the end of the file; refusing to patch")

    magic, _, count = struct.unpack_from(">III", d, so)
    if magic != CSMAGIC_EMBEDDED_SIGNATURE:
        sys.exit("unexpected signature magic")
    blobs = []
    for j in range(count):
        typ, off = struct.unpack_from(">II", d, so + 12 + 8 * j)
        if typ == CSSLOT_ENTITLEMENTS:
            continue  # replace any existing entitlements
        _, length = struct.unpack_from(">II", d, so + off)
        blobs.append((typ, bytes(d[so + off:so + off + length])))

    xml = plistlib.dumps(ENTS)
    blobs.append((CSSLOT_ENTITLEMENTS, struct.pack(">II", CSMAGIC_EMBEDDED_ENTITLEMENTS, 8 + len(xml)) + xml))
    blobs.sort(key=lambda b: b[0])

    header = 12 + 8 * len(blobs)
    index, body, off = b"", b"", header
    for typ, blob in blobs:
        index += struct.pack(">II", typ, off)
        body += blob
        off += len(blob)
    sb = struct.pack(">III", CSMAGIC_EMBEDDED_SIGNATURE, off, len(blobs)) + index + body
    sb += b"\0" * ((-len(sb)) % 16)

    out = d[:so] + sb
    struct.pack_into("<I", out, sig_cmd + 12, len(sb))
    new_fs = len(out) - le_fo
    struct.pack_into("<Q", out, linkedit + 48, new_fs)                      # filesize
    vmsize = struct.unpack_from("<Q", out, linkedit + 32)[0]
    struct.pack_into("<Q", out, linkedit + 32, max(vmsize, (new_fs + PAGE - 1) // PAGE * PAGE))
    open(exe, "wb").write(out)
    open(ents_out, "wb").write(xml)
    print("added entitlements to", exe)


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
