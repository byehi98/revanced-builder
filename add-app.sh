#!/usr/bin/env bash
set -euo pipefail

CWD=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)
cd "$CWD"

if [ $# -lt 2 ] && [[ "${1:-}" != "--help" && "${1:-}" != "-h" && "${1:-}" != http* ]]; then
    cat <<'EOF'
Usage:
  ./add-app.sh <app-name> <patch-source> [package-name] [config-file]
  ./add-app.sh --link <morphe-add-source-url>
  ./add-app.sh --app <name> --source <owner/repo> [options]

Options:
  --link <url>         Morphe add-source URL (fills app, source and package)
  --package <pkg>      Android package name (otherwise resolved)
  --table <name>       exact config table name (default: canonical app name)
  --brand <name>       rv-brand override (default: file brand, then owner)
  --cli-source <repo>  cli-source override (default: MorpheApp/morphe-cli)
  --morphe             include morphe-dlurl (default: aptoide/apkeep only)
  --config-file <f>    destination config file
  --json               print one machine-readable JSON object
  --dry-run            show the proposed table without writing it
  --force              overwrite a conflicting table / uncomment managed keys
  --force-new          create a new table even if the app/source pair exists
  --verbose            explain each resolver step

Examples:
  ./add-app.sh --link "https://morphe.software/add-source?github=legendsciber/morphe-patches&app=com.kiloo.subwaysurf&appName=Subway%20Surfers"
  ./add-app.sh YouTube MorpheApp/morphe-patches
  ./add-app.sh Spotify MorpheApp/morphe-patches com.spotify.music
  ./add-app.sh --app TradingView --source hxreborn/morphe-patches --dry-run
  ./add-app.sh --app Firefox-Focus --source heval99/Heval-Morphe-Patches --json
EOF
    exit 1
fi

python3 "${CWD}/scripts/add_app.py" "$@"
