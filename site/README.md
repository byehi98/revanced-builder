# Obtainium Catalog Website

A static, dependency-free catalogue of every app this builder produces. Each card
contains the same Obtainium deep link as the README build table, plus the latest
APK download. The hero also offers a downloadable import file with one config
per built app.

## Files

| File | Purpose |
| :--- | :--- |
| `index.html` | Page shell and copy |
| `style.css` | Dark/light theme, layout, cards and redirect page |
| `app.js` | Search, source filter, sorting, theme, copy-link, import file |
| `data.json` | Generated catalogue (do not edit by hand) |
| `icons/*.png` | Committed 96×96 circular launcher icons (third-party artwork) |
| `icons/sources.json` | Generated provenance for each icon (do not edit by hand) |
| `apps/*.html` | Generated Obtainium HTML source pages for old builds (do not edit) |

## Local preview

```sh
# regenerate the catalogue from this checkout (add --offline to skip GitHub)
python3 scripts/generate_site.py

# serve the site
python3 -m http.server -d site 8000
# then open http://localhost:8000
```

`data.json` has to be fetched over HTTP; opening `index.html` directly with
`file://` will show a loading error in most browsers. The generator also writes
`site/apps/*.html`; they are git-ignored and rebuilt before each deployment.
Pass `--site-url http://localhost:8000/` when testing old-build links locally.

## Deployment

The site is published to GitHub Pages by
[`.github/workflows/deploy-site.yml`](../.github/workflows/deploy-site.yml).
It rebuilds automatically after each release, after the README build table is
updated, and on pushes that touch `site/` or the generator.

One-time setup: in **Settings → Pages**, set **Source** to **GitHub Actions**.
The expected URL is `https://<owner>.github.io/<repo>/`.

## How the catalogue is built

`scripts/generate_site.py` combines:

1. `config.toml` and `configs/*.toml` — enabled apps, patches sources, brand and
   the release filename prefix.
2. The generated README build-status table — package IDs, status and fallback
   download links.
3. The GitHub releases API — the newest asset for each app, with size, release
   tag, date and download count.
4. `update/build.md` — the current patch bundle version per source.

The Obtainium payload is identical to the README generator:

```json
{
  "id": "<package id>",
  "url": "https://github.com/<owner>/<repo>",
  "author": "<owner>",
  "name": "<app name>",
  "additionalSettings": "{\"apkFilterRegEx\":\"<app>-<brand>\",\"autoApkFilterByArch\":true,\"fallbackToOlderReleases\":true}"
}
```

`apkFilterRegEx` scopes each link to that app's files so Obtainium does not pick
up another app from the same release. `fallbackToOlderReleases` makes the import
scan the whole release page instead of only the newest release.

### Apps older than the newest 100 releases

Obtainium's GitHub source requests only `.../releases?per_page=100` and does not
paginate. A build older than that window can never be found, even with
`fallbackToOlderReleases` enabled. For those apps the generator writes a small
page under `apps/` and emits an Obtainium **HTML** source config instead:

```json
{
  "id": "<package id>",
  "url": "https://<owner>.github.io/<repo>/apps/<table>.html",
  "author": "<owner>",
  "name": "<app name>",
  "additionalSettings": "{\"apkFilterRegEx\":\"(?:/|-)<app>-<brand>-[^/]*$\",\"autoApkFilterByArch\":true,\"versionExtractWholePage\":true,\"versionExtractionRegEx\":\"name=\\\"obtainium-version\\\" content=\\\"([^\\\"]+)\\\"\",\"matchGroupToUse\":\"1\"}",
  "overrideSource": "HTML"
}
```

The page embeds the app version in a meta tag and links to the exact APK in the
old release, so Obtainium can still detect updates when the build is rebuilt.
The choice is automatic: apps on the first release page keep the native GitHub
source, and apps outside it move to HTML. No releases are deleted or rewritten.

## Launcher icons

Every card shows the app's real launcher icon, stored as
`site/icons/<package id>.png`. Icons are 96×96 PNGs cut to a circle, following
the approach used by
[`hxreborn/morphe-patches`](https://github.com/hxreborn/morphe-patches/tree/main/.github/assets/icons).

`scripts/fetch_icons.py` fills in missing icons:

1. It fetches the app's Google Play listing icon (`=s96-cc`), using an override
   for patched package IDs that do not exist on Play.
2. If Play has no listing, it extracts the launcher icon from the built APK with
   HTTP range requests (`scripts/apk_icons.py`), rendering adaptive layers,
   vector drawables and density-specific PNG/WebP icons with ImageMagick.

```sh
# fetch icons for apps that do not have one yet
python3 scripts/fetch_icons.py

# refresh everything (requires ImageMagick for APK fallbacks)
python3 scripts/fetch_icons.py --force
```

The icons are the property of their respective app developers. They are used
only to identify the app a build applies to, and are not covered by this
repository's licence. `icons/sources.json` records whether each file came from
Google Play or from an APK and which drawable was used.

## Bulk import

The hero offers a downloadable `revanced-builder-obtainium.json` containing one
config per built app. Import it from **Settings → Import/export → Obtainium
import**.

Obtainium keys apps by Android package ID, so variants of the same package
cannot coexist. The import file keeps one config per package — the most
recently built variant — while every variant remains available as its own card.
