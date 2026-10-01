# ReVanced Magisk Module Builder

This project is an extensive ReVanced builder that can create Magisk modules and non-root APKs for various Android applications. It automates the process of fetching patches, the ReVanced CLI, and the target APKs, and then applying those patches.

## Tech Stack
- **Primary Language:** Bash
- **Environment Management:** Nix (`flake.nix`, `flake.lock`)
- **Key Dependencies:** OpenJDK 21, `jq`, `zip`, `curl`/`wget`, `aapt2`, `apksigner`, `apkeep`, `gplaydl`
- **Configuration:** TOML (`config.toml`)

## Project Structure
- `build.sh`: The main entry point for the build process.
- `utils.sh`: Contains common helper functions for configuration parsing, downloading, and patching.
- `config.toml`: The primary configuration file where users define which apps to build and which patches to include/exclude.
- `CONFIG.md`: Documentation for the configuration options available in `config.toml`.
- `bin/`: Contains pre-compiled binary utilities for different architectures and tools (`aapt2`, `htmlq`, `toml`, `apksigner.jar`, `apkprep.jar`, `ApkPrep.java`).
- `module/`: Template for the Magisk module structure.
- `ksu_profile/`: Source code for KernelSU profile integration.
- `temp/`: Directory used for temporary files during the build process.
- `build/`: Directory where final APKs and Magisk modules are placed.

## Core Workflows
### Build Process
1. **Environment Setup:** `build.sh` sources `utils.sh` and checks for required tools (`jq`, `java`, `zip`).
2. **Configuration Parsing:** The script parses `config.toml` to determine build parameters (compression, parallel jobs, etc.).
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
- `./build.sh clean`: Remove temporary and build directories.
- `./build.sh <config.toml> --config-update`: Update the configuration file.
- `bash build-termux.sh`: Specialized build script for Termux environments.
