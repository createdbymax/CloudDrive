#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
backend="${CLOUDDRIVE_BACKEND:-$PWD/build/backend/rclone}"
if [[ ! -x "$backend" ]]; then
    print -u2 'The patched backend has not been built. Run: python3 scripts/build-rclone-allocation.py'
    exit 1
fi
python3 scripts/signing.py preflight
build_options=(-c release)
if [[ -n "${CLOUDDRIVE_BUILD_PATH:-}" ]]; then
    build_options+=(--scratch-path "$CLOUDDRIVE_BUILD_PATH")
fi
swift build "${build_options[@]}"
binary_directory="$(swift build "${build_options[@]}" --show-bin-path)"
app="${CLOUDDRIVE_APP_OUTPUT:-$PWD/build/CloudDrive.app}"
python3 scripts/package-app.py "$app" "$binary_directory" "$backend"
