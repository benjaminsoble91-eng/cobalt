# Trollamine Installer — source

Source for **Trollamine Installer** (`com.mymculture.trollamineinstaller`), the app on Cobalt that
downloads the latest official Dopamine and builds **Trollamine** from it on the device: Dopamine with
the Trollamine theme and a TrollStore-style Apps panel.

This is the source for version 6.5.

## Files

| File | What it is |
| --- | --- |
| `main.m` | The installer app: downloads Dopamine, themes it, adds the add-on library, signs and installs it |
| `kit.m` | `TrollamineKit.dylib`, the add-on library loaded inside Trollamine (menu entry, Apps panel, settings) |
| `tmsign.m/.h` | Signs every program file in an app bundle with the bundled signer |
| `machopatch.c/.h` | Adds the add-on library to a program's load list and reads its entitlements |
| `tdzip.m/.h`, `tmzip.c/.h` | Unpacking and packaging of `.ipa` / `.tipa` files |
| `tmcommon.h` | Shared helpers (work folder, running the installer engine, alerts) |
| `ents.plist` | Entitlements for the installer app |
| `helper.entitlements`, `phelper.entitlements` | Entitlements given to the bundled helper tools |
| `build.sh` | Builds and signs the two programs |

## Building

```
SDK=/path/to/iPhoneOS16.5.sdk LDID=/path/to/ldid ./build.sh
```

This produces `out/TrollamineInstaller` and `out/TrollamineKit.dylib`.

## Not included here

A full installer package also contains things that are not part of this source:

- **Third-party tools**, bundled unchanged in the released `.deb`: `trollstorehelper` and
  `PersistenceHelper` (from [TrollStore](https://github.com/opa334/TrollStore)), `fastPathSign`
  (from [Dopamine](https://github.com/opa334/Dopamine)) and `ldid`
  (from [opa334/ldid](https://github.com/opa334/ldid)). They belong to their authors and keep their
  own licenses.
- **Artwork**: the icons, boot logos and background image.

To assemble a package, take those from the released `.deb` in `debs/` and replace the two programs
with the ones built here.
