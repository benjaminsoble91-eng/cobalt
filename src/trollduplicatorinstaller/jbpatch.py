#!/usr/bin/env python3
"""Make a copy of TrollDuplicator.app that a jailbreak can run without TrollStore, down to iOS 13.

TrollDuplicator is built for iOS 14 and hard-links UniformTypeIdentifiers.framework, which does
not exist on iOS 13, so dyld would refuse to launch it there. This script, on the copy only:
  1. turns the UniformTypeIdentifiers LC_LOAD_DYLIB into LC_LOAD_WEAK_DYLIB,
  2. marks its only import (_UTTypeImage) as a weak import, so it resolves to NULL on iOS 13,
  3. lowers LC_BUILD_VERSION minos and Info.plist MinimumOSVersion to 13.0,
  4. writes the app's entitlements to ents.plist.
The old code signature no longer matches after this, so the postinst re-signs the binary on the
device with ldid using ents.plist.

usage: jbpatch.py <TrollDuplicator.app> <ents.plist out>
"""
import plistlib
import struct
import sys

LC_LOAD_DYLIB = 0xC
LC_LOAD_WEAK_DYLIB = 0x80000018
LC_BUILD_VERSION = 0x32
LC_CODE_SIGNATURE = 0x1D
LC_DYLD_INFO_ONLY = 0x80000022
WEAK_FRAMEWORK = b"/System/Library/Frameworks/UniformTypeIdentifiers.framework/UniformTypeIdentifiers"
WEAK_SYMBOLS = [b"_UTTypeImage"]
MIN_OS = (13 << 16)  # 13.0.0


def main(app, ents_out):
    exe_path = f"{app}/TrollDuplicator"
    d = bytearray(open(exe_path, "rb").read())
    if struct.unpack_from("<I", d, 0)[0] != 0xFEEDFACF:
        sys.exit("expected a thin arm64 Mach-O")
    ncmds = struct.unpack_from("<I", d, 16)[0]
    p = 32
    weakened = minos_done = False
    bind = sig = None
    for _ in range(ncmds):
        cmd, size = struct.unpack_from("<II", d, p)
        if cmd in (LC_LOAD_DYLIB, LC_LOAD_WEAK_DYLIB):
            name_off = struct.unpack_from("<I", d, p + 8)[0]
            name = bytes(d[p + name_off:p + size]).split(b"\0", 1)[0]
            if name == WEAK_FRAMEWORK:
                struct.pack_into("<I", d, p, LC_LOAD_WEAK_DYLIB)
                weakened = True
        elif cmd == LC_BUILD_VERSION:
            struct.pack_into("<I", d, p + 12, MIN_OS)
            minos_done = True
        elif cmd == LC_DYLD_INFO_ONLY:
            bind = struct.unpack_from("<II", d, p + 16)  # bind_off, bind_size
        elif cmd == LC_CODE_SIGNATURE:
            sig = struct.unpack_from("<II", d, p + 8)
        p += size
    if not (weakened and minos_done and bind and sig):
        sys.exit(f"patch points not found (weak={weakened} minos={minos_done} bind={bind} sig={sig})")

    # Bind opcodes: BIND_OPCODE_SET_SYMBOL_TRAILING_FLAGS_IMM (0x40 | flags) is followed inline by
    # the symbol name. Setting flag 0x1 (BIND_SYMBOL_FLAGS_WEAK_IMPORT) lets it bind to NULL.
    off, size = bind
    region = bytes(d[off:off + size])
    for sym in WEAK_SYMBOLS:
        i = region.find(sym + b"\0")
        if i < 1 or (region[i - 1] & 0xF0) != 0x40:
            sys.exit(f"bind entry for {sym.decode()} not found")
        d[off + i - 1] |= 0x01

    # Pull the entitlements out of the existing signature (CSMAGIC_EMBEDDED_ENTITLEMENTS).
    so, _ = sig
    count = struct.unpack_from(">I", d, so + 8)[0]
    ents = None
    for j in range(count):
        _, o = struct.unpack_from(">II", d, so + 12 + 8 * j)
        magic, length = struct.unpack_from(">II", d, so + o)
        if magic == 0xFADE7171:
            ents = bytes(d[so + o + 8:so + o + length])
    if not ents:
        sys.exit("no entitlements in the signature")
    open(ents_out, "wb").write(ents)
    open(exe_path, "wb").write(d)

    info_path = f"{app}/Info.plist"
    info = plistlib.load(open(info_path, "rb"))
    info["MinimumOSVersion"] = "13.0"
    plistlib.dump(info, open(info_path, "wb"))
    print("patched", exe_path)


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
