# Config

The root `config.toml` holds only global settings and points at the app configs:

```toml
parallel-jobs = 5
dpi = "nodpi anydpi"
remove-rv-integrations-checks = false

app-configs = "configs"   # every *.toml in here gets merged in
# imports = ["some/other.toml"]   # extra files, merged in the listed order
```

Every `configs/*.toml` file holds the app tables of one patch author, so the app
config is split up per author instead of living in one huge file. Adding a new
author means adding a file to `configs/` — the root `config.toml` never needs to
change.

```
configs/
├── MorpheApp-morphe-patches.toml     # [YouTube-Morphe], [Reddit-Morphe], ...
├── byehi98-okish-morphe-patches.toml # 35 games
└── ...one file per patches-source
```

A file may set its own `app-configs`/`imports`; those are resolved relative to
that file, so `configs/` files can pull in shared configs of their own. Table
names must be unique across every file — a duplicate is a hard error rather than
a silent overwrite. Every app table is named `<App>-<rv-brand>` (e.g.
`[TradingView-hxreborn]`), so the same app can be built from more than one patch
source without colliding, and the brand is visible in the table name and release
filename. `./add-app.sh` creates tables in that shape automatically.

## Adding another revanced app

Find the file in `configs/` for that patches author (or create one), then add a
table named after the app and its `rv-brand`:
```toml
[Some-App-hxreborn]
# morphe-dlurl = "package.name" # opt-in: Morphe resolver for direct APKMirror / Uptodown variants
aptoide-dlurl = "package.name" # direct Aptoide API queries
apkeep-dlurl  = "package.name" # APKPure via apkeep + 1-hop direct signed CDN fallback
# or apkmirror-dlurl = "https://www.apkmirror.com/apk/inc/app"
# or uptodown-dlurl = "https://app.en.uptodown.com/android"
# or apkpure-dlurl = "https://apkpure.net/app-slug/package.name"
# or apkcombo-dlurl = "https://apkcombo.com/app-slug/package.name"
# or gplaydl-dlurl = "package.name"
```

Only the sources a table explicitly sets are used, and they are tried in the fixed
order `morphe → aptoide → apkeep → apkcombo → apkmirror → apkpure → archive → direct
→ gplaydl → uptodown`. Any source that cannot deliver the required version falls
through to the next *configured* source, so list as many as apply to make the build
resilient to a single site being down. No source is ever added implicitly: in
particular `aptoide` is not derived from `pkg-name`/`apkeep-dlurl`/`gplaydl-dlurl`,
and `morphe` is only used when the table sets `morphe-dlurl` (or the legacy
`morphe-helper-dlurl`), because those can return a differently packaged/signed APK.
In addition, `apkeep` and `apkpure` automatically attempt 1-hop signed CDN downloads (`d.apkpure.com`)
before falling back to slow web scraping or retries.

> [!WARNING]
> When a patch name itself contains a single quote, double it inside the string (e.g. 'Hide ''Get Music Premium''').

## More about other options:

There exists an example below with all defaults shown and all the keys explicitly set.  
**All keys are optional** (except download urls) and are assigned to their default values if not set explicitly.  

```toml
parallel-jobs = 1                    # amount of cores to use for parallel patching, if not set $(nproc) is used
compression-level = 9                # module zip compression level
remove-rv-integrations-checks = true # remove checks from the revanced integrations
dpi = "nodpi anydpi 120-640dpi"      # dpi packages to be searched in order. default: "nodpi anydpi"

patches-source = "revanced/revanced-patches" # where to fetch patches bundle from. default: "revanced/revanced-patches". Supports GitLab by prefixing with 'GitLab:' (e.g., 'GitLab:user/repo')
patches-sources = "revanced/revanced-patches" # alias for patches-source
cli-source = "ReVanced/revanced-cli"             # where to fetch cli from. default: "ReVanced/revanced-cli". Supports GitLab as well.
cli-sources = "ReVanced/revanced-cli"            # alias for cli-source
# options like cli-source can also set per app
rv-brand = "ReVanced Extended" # rebrand from 'ReVanced' to something different. default: "ReVanced"

patches-version = "v2.160.0" # 'latest', 'dev', or a version number. default: "latest"
cli-version = "v5.0.0"       # 'latest', 'dev', or a version number. default: "latest"

[Some-App-hxreborn]
app-name = "SomeApp" # if set, release name becomes SomeApp instead of the table name. default is the table name, which is 'Some-App-hxreborn' here.
enabled = true       # whether to build the app. default: true
build-mode = "apk"   # 'both', 'apk' or 'module'. default: apk

# 'auto' option gets the latest possible version supported by all the included patches
# 'latest' gets the latest stable without checking patches support. 'beta' gets the latest beta/alpha
# 'experiment' (or 'experimental') gets the latest experimental version supported by patches
version = "auto"     # 'auto', 'latest', 'beta', 'experiment' or a version number (e.g. '17.40.41'). default: auto

# optional args to be passed to cli. can be used to set patch options
# multiline strings in the config is supported
patcher-args = """\
  -OdarkThemeBackgroundColor=#FF0F0F0F \
  -Oanother-option=value \
  """

excluded-patches = """\
  'Some Patch' \
  'Some Other Patch' \
  """

included-patches = "'Some Patch'"                          # whitespace seperated list of non-default patches to include. default: ""
include-stock = "merged"                                   # 'merged', 'split' or 'disable'. default: merged
exclusive-patches = false                                  # exclude all patches by default. default: false

apkmirror-dlurl = "https://www.apkmirror.com/apk/inc/app"
uptodown-dlurl = "https://spotify.en.uptodown.com/android"
apkpure-dlurl = "https://apkpure.net/spotify-music/com.spotify.music"
# direct download url. the url must have point to an apk file with name format shown in this example
direct-dlurl = "https://website/com.google.android.youtube-20.40.45-all.apk"

module-prop-name = "some-app-module"                       # module prop name.
dpi = "360-480dpi"                                         # used to select apk variant from apkmirror. default: nodpi
arch = "arm64-v8a"                                         # 'arm64-v8a', 'arm-v7a', 'all', 'both'. 'both' downloads both arm64-v8a and arm-v7a. default: all
```

## Validating config changes

Run `python3 scripts/validate_configs.py` (or `make check`) before committing a
config change. It validates the merged `config.toml` + `configs/*.toml` tree for
unique and correctly named tables (`<App>-<rv-brand>`), known keys, valid
sources, package names, enums, and at least one download source per app.

## Signing

`ks.keystore` and `ks-p12.keystore` are public test keys, not production secrets.
The default alias is `jhc` and the default password is `123456789`. See
[`README.md`](README.md#signing-keys) for the full explanation and the
`RVB_KEYSTORE*` / `RVB_PATCHER_KEYSTORE` environment overrides.
