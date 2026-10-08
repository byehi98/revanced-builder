# ReVanced Magisk Module Builder

This project is an extensive ReVanced builder that can create Magisk modules and non-root APKs for various Android applications. It automates the process of fetching patches, the ReVanced CLI, and the target APKs, and then applying those patches.

## Tech Stack
- **Primary Language:** Bash
- **Environment Management:** Nix (`flake.nix`, `flake.lock`)
- **Key Dependencies:** OpenJDK 21, `jq`, `zip`, `curl`/`wget`, `aapt2`, `apksigner`, `apkeep`, `gplaydl`
- **apkeep:** pinned in `flake.nix` to a specific upstream release binary, because nixpkgs-unstable still carries 0.18.0. Only apkeep's `apk-pure` source is used — Google Play is deliberately not, since it is unusable here (anonymous requests are rejected on apkeep >= 1.0.0, and authenticated ones exit 0 while downloading nothing). `apk-pure` needs `-o acknowledge_dangers=true` or apkeep >= 1.1.0 refuses to run, and it exits 0 even when a version is unavailable, so `dl_apkeep` checks for a downloaded file rather than trusting the exit code.
- **Configuration:** TOML (`config.toml`)

## Project Structure
- `build.sh`: The main entry point for the build process.
- `utils.sh`: Contains common helper functions for configuration parsing, downloading, and patching.
- `config.toml`: The root config — global settings plus a pointer to the app config directory.
- `configs/`: One TOML file per patch author, each holding that author's app tables. All of them are merged into the root config by `toml_prep`.
- `CONFIG.md`: Documentation for the configuration options available in `config.toml` and the per-author files.
- `bin/`: Contains pre-compiled binary utilities for different architectures and tools (`aapt2`, `htmlq`, `toml`, `apksigner.jar`, `apkprep.jar`, `ApkPrep.java`).
- `module/`: Template for the Magisk module structure.
- `ksu_profile/`: Source code for KernelSU profile integration.
- `temp/`: Directory used for temporary files during the build process.
- `build/`: Directory where final APKs and Magisk modules are placed.

## Configuration Layout
`toml_prep` accepts a single TOML file but merges an include tree into it:

- `app-configs = "configs"` — merge every `*.toml` in that directory, sorted by name.
- `imports = ["a.toml", "b.toml"]` — merge those files in the listed order (a bare string is also accepted).

Paths are resolved relative to the directory of the file that names them, and each file may declare its own `app-configs`/`imports`. `toml_merge` keeps a set of already-merged files, so an import cycle terminates rather than recursing forever, and it errors out on a duplicate app table name instead of letting one app silently shadow another. Both keys are stripped from the result, so a merged config is indistinguishable from a single-file one — `toml_prep` output matches what the old one big `config.toml` produced.

`toml_get_table_main` treats every non-object value as a global setting, so new globals can be added to the root config freely.

## Core Workflows
### Build Process
1. **Environment Setup:** `build.sh` sources `utils.sh` and checks for required tools (`jq`, `java`, `zip`).
2. **Configuration Parsing:** The script parses the root config, merging in every file under `app-configs`/`imports`, to determine build parameters (compression, parallel jobs, etc.).
3. **Prebuilt Acquisition:** Fetches the latest (or specified) ReVanced CLI and patches JARs from GitHub or GitLab.
4. **App Processing:** For each enabled app in `config.toml`:
    - Finds the correct APK version (from APKeep, APKCombo, APKMirror, APKPure, archive, direct, gplaydl, or Uptodown — see `DL_SRCS` in `utils.sh`).
    - Downloads the APK, walking the sources in `DL_SRCS` order and falling through to the next one whenever the current source cannot serve the required version.
    - Applies patches using ReVanced CLI.
    - Packages the result as an APK or Magisk module.

### Download Source Fallbacks
An app table may declare several `<source>-dlurl` keys at once. Every key that is present takes part in the fallback chain, so listing more sources makes a build more resilient to a single site being down, rate-limited or missing a version. Every table needs at least one of them or `build.sh` aborts.

Only keep sources that actually work for a given package. `apkpure` in particular scrapes `<url>/versions`, and APKPure returns `410` for apps it has no version history for — a dead entry there is just a wasted request, so omit it rather than shipping a URL that can never resolve.

### Development Conventions
- **Error Handling:** Use `abort "message"` to terminate the script with an error message and cleanup.
- **Logging:** Use `pr` for success/info messages, `epr` for errors, and `wpr` for warnings.
- **Shell Hygiene:** Scripts should start with `set -euo pipefail`.
- **Binary Utilities:** Architecture-specific binaries are located in `bin/` and used as needed (e.g., `aapt2`, `toml`).

## Command Reference
- `./build.sh`: Run the full build process.
- `./build.sh [--app <table>]`: Build only the named app table(s). `--app` may be repeated, and a bare table name works in its place (`./build.sh Google-Photos-Akash-Sriram`). An explicit `--app` also builds an app whose table has `enabled = false`.
- `./build.sh --list-apps`: Print every app table name found in the config.
- `./build.sh clean`: Remove temporary and build directories.
- `./build.sh <config.toml> --config-update`: Update the configuration file.
- `bash build-termux.sh`: Specialized build script for Termux environments.
