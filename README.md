# Cobalt

A hand-built jailbreak source — Sileo tweaks and TrollStore apps in one place.

Everything is static files. Host the contents of this folder at any URL and it just works. The storefront (`index.html`) figures out its own address at runtime, so the **Add to Sileo** and **Get** buttons work wherever you put it — no editing required.

## What's inside

```
Release                 APT repo metadata
Packages(.gz/.bz2)      package index (relative paths — zero config)
CydiaIcon.png           source icon shown in Sileo
index.html              storefront / landing page
depictions/             info pages (HTML for Zebra/Cydia and the web)
depictions/native/      native Sileo depictions (JSON: Details + Changelog tabs)
sileo-featured.json     featured banners at the top of the source in Sileo
debs/                   Sileo tweaks (installable from the source)
tipa/                   TrollStore apps (installable via Get buttons)
assets/                 icons + art
seturl.sh               optional: bake an absolute URL for Zebra/Cydia
src/                    source for the tweaks (IconSwap, PowerPlus, BarText, DoubleDose, PanicButton, RootRun) + build.sh
src/trollamine/         source for Trollamine Installer (installer app + add-on library) + build.sh
src/trollduplicatorinstaller/  TrollDuplicator Installer (.deb that installs TrollDuplicator via TrollStore, then removes itself)
```

## Host it on GitHub Pages (recommended)

1. Create a new **public** repo, e.g. `cobalt`.
2. Put everything in this folder at the repo root and push:
   ```
   git init
   git add .
   git commit -m "Cobalt source"
   git branch -M main
   git remote add origin https://github.com/YOURNAME/cobalt.git
   git push -u origin main
   ```
3. Repo → **Settings → Pages** → Source: `main` / root → Save.
4. After a minute your source is live at:
   ```
   https://YOURNAME.github.io/cobalt/
   ```

Open that URL on your device and tap **Add to Sileo**. Done.

## Other hosts

Netlify / Vercel / any static host: drag the folder in, or point it at the repo. Same deal — the storefront self-locates.

## Optional: absolute URLs (Zebra / Cydia)

Sileo handles the relative paths fine. If you also want Zebra/Cydia to show the tweak icon and depiction, bake your real URL in once after deploying:

```
./seturl.sh https://YOURNAME.github.io/cobalt
```

Then commit and push the updated `Packages*` and `Release`.

Note: `SileoDepiction` and `sileo-featured.json` need absolute URLs, so run `seturl.sh` after any change to `Packages.in`, and edit the URLs in `sileo-featured.json` if the source ever moves.

## Adding a new package later

**Tweak (.deb):** drop it in `debs/`, then regenerate the index:
```
dpkg-scanpackages -m debs /dev/null > Packages
gzip -9kf Packages && bzip2 -9kf Packages
```
(or just ask me to rebuild it). Add an entry to `index.html` if you want it on the storefront.

**TrollStore app (.tipa):** drop it in `tipa/` and add a card to the `TIPA` list in `index.html`.
