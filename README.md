# Cobalt

A hand-built jailbreak source — Sileo tweaks and TrollStore apps in one place.

Everything is static files. Host the contents of this folder at any URL and it just works. The storefront (`index.html`) figures out its own address at runtime, so the **Add to Sileo** and **Get** buttons work wherever you put it — no editing required.

## What's inside

```
Release                 APT repo metadata
Packages(.gz/.bz2)      package index (relative paths — zero config)
CydiaIcon.png           source icon shown in Sileo
index.html              storefront / landing page
depictions/             in-Sileo info pages
debs/                   Sileo tweaks (installable from the source)
tipa/                   TrollStore apps (installable via Get buttons)
assets/                 icons + art
seturl.sh               optional: bake an absolute URL for Zebra/Cydia
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

> Tip: the three `Dopamine-*.tipa` copies are ~54 MB each. If you don't want them in the repo, delete them from `tipa/` and remove their cards from `index.html` — the rest stays tiny.

## Other hosts

Netlify / Vercel / any static host: drag the folder in, or point it at the repo. Same deal — the storefront self-locates.

## Optional: absolute URLs (Zebra / Cydia)

Sileo handles the relative paths fine. If you also want Zebra/Cydia to show the tweak icon and depiction, bake your real URL in once after deploying:

```
./seturl.sh https://YOURNAME.github.io/cobalt
```

Then commit and push the updated `Packages*` and `Release`.

## Adding a new package later

**Tweak (.deb):** drop it in `debs/`, then regenerate the index:
```
dpkg-scanpackages -m debs /dev/null > Packages
gzip -9kf Packages && bzip2 -9kf Packages
```
(or just ask me to rebuild it). Add an entry to `index.html` if you want it on the storefront.

**TrollStore app (.tipa):** drop it in `tipa/` and add a card to the `TIPA` list in `index.html`.
