# Obtainium Catalog Website

A static, dependency-free catalogue of every app this builder produces. Each card
contains the same Obtainium deep link as the README build table, plus the latest
APK download. One button in the hero imports every built app into Obtainium at
once.

## Files

| File | Purpose |
| :--- | :--- |
| `index.html` | Page shell and copy |
| `style.css` | Dark/light theme, layout, cards and redirect page |
| `app.js` | Search, source filter, sorting, theme, copy-link, bulk import |
| `add-all.html` | Intermediate page that hands the bulk import to Obtainium |
| `add-all.js` | Builds the deep link from the URL fragment and offers fallbacks |
| `data.json` | Generated catalogue (do not edit by hand) |

## Local preview

```sh
# regenerate the catalogue from this checkout (add --offline to skip GitHub)
python3 scripts/generate_site.py

# serve the site
python3 -m http.server -d site 8000
# then open http://localhost:8000
```

`data.json` has to be fetched over HTTP; opening `index.html` directly with
`file://` will show a loading error in most browsers.

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
  "additionalSettings": "{\"apkFilterRegEx\":\"<app>-<brand>\",\"autoApkFilterByArch\":true}"
}
```

`apkFilterRegEx` scopes each link to that app's files so Obtainium does not pick
up another app from the same release.

## Bulk import

The hero button collects each built app's config and opens
`obtainium://apps/<url-encoded JSON array>`, the bulk deep link Obtainium
documents on its [wiki](https://wiki.obtainium.imranr.dev/deep_links/).

Obtainium keys apps by Android package ID, so variants of the same package
cannot coexist. The bulk import keeps one config per package — the most
recently built variant — while every variant remains available as its own card.

The payload is passed to `add-all.html` in the URL fragment rather than a query
string. Fragments are never sent to GitHub Pages, so the 60+ KB import is not
rejected by request URL length limits. That page attempts the deep link and, if
Obtainium is not installed or the browser blocks the handoff, offers the same
configs as a downloadable `revanced-builder-obtainium.json` for
**Settings → Import/export → Obtainium import**.
