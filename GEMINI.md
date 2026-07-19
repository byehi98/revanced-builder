# ReVanced Magisk Module Builder

This project is an extensive ReVanced builder that can create Magisk modules and non-root APKs for various Android applications. It automates the process of fetching patches, the ReVanced CLI, and the target APKs, and then applying those patches.

## Tech Stack
- **Primary Language:** Bash
- **Environment Management:** Nix (`flake.nix`, `flake.lock`)
- **Key Dependencies:** OpenJDK 17, `jq`, `zip`, `curl`/`wget`, `aapt2`, `apksigner`, `apkeep`
- **Configuration:** TOML (`config.toml`)

## Project Structure
- `build.sh`: The main entry point for the build process.
- `utils.sh`: Contains common helper functions for configuration parsing, downloading, and patching.
- `config.toml`: The primary configuration file where users define which apps to build and which patches to include/exclude.
- `CONFIG.md`: Documentation for the configuration options available in `config.toml`.
- `bin/`: Contains pre-compiled binary utilities for different architectures (aapt2, htmlq, toml).
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
    - Finds the correct APK version (from APKMirror, Uptodown, APKPure, APKeep, archive, or direct).
    - Downloads the APK.
    - Applies patches using ReVanced CLI.
    - Packages the result as an APK or Magisk module.

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
