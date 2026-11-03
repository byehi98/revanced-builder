#!/usr/bin/env bash
set -euo pipefail

CWD=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)
cd "$CWD"

if [ $# -lt 2 ]; then
    echo "Usage: ./add-app.sh <app-name> <patch-source> [package-name] [config-file]"
    echo ""
    echo "Examples:"
    echo "  ./add-app.sh YouTube MorpheApp/morphe-patches"
    echo "  ./add-app.sh Spotify MorpheApp/morphe-patches com.spotify.music"
    echo "  ./add-app.sh Firefox-Focus heval99/Heval-Morphe-Patches"
    exit 1
fi

python3 "${CWD}/scripts/add_app.py" "$@"
