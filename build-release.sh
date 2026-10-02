#!/bin/bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PACKAGE_NAME="cumob-oneclick-installer"
ARCHIVE_PATH="$ROOT_DIR/dist/$PACKAGE_NAME.zip"
MANIFEST_PATH="$ROOT_DIR/MANIFEST.sha256"
BOOTSTRAP_DIR="$ROOT_DIR/dist/bootstrap-entry"

command -v zip >/dev/null 2>&1 || {
  printf '%s\n' "The zip command is required to build the release." >&2
  exit 1
}
command -v openssl >/dev/null 2>&1 || {
  printf '%s\n' "OpenSSL is required to generate SHA-256 checksums." >&2
  exit 1
}

python3 "$ROOT_DIR/scripts/validate-model-catalog.py" "$ROOT_DIR/payload/cumob-models.json"
bash "$ROOT_DIR/tests/test-install.sh"

(
  cd "$ROOT_DIR"
  find \
    SOURCE.json \
    README.md \
    README.en.md \
    LICENSE \
    install.sh \
    install.ps1 \
    install-macos.command \
    install-windows.cmd \
    payload \
    scripts \
    tests \
    -type f -print |
    LC_ALL=C sort |
    while IFS= read -r file; do
      hash="$(openssl dgst -sha256 "$file" | awk '{print $NF}')"
      printf '%s  %s\n' "$hash" "$file"
    done
) > "$MANIFEST_PATH"

mkdir -p "$ROOT_DIR/dist" "$BOOTSTRAP_DIR"
rm -f "$ARCHIVE_PATH" \
  "$ROOT_DIR/dist/install-macos.command" \
  "$ROOT_DIR/dist/install-windows.cmd" \
  "$ROOT_DIR/dist/bootstrap-entry.zip"

cp "$ROOT_DIR/install-macos.command" "$BOOTSTRAP_DIR/install-macos.command"
cp "$ROOT_DIR/install-windows.cmd" "$BOOTSTRAP_DIR/install-windows.cmd"
cp "$ROOT_DIR/install-macos.command" "$ROOT_DIR/dist/install-macos.command"
cp "$ROOT_DIR/install-windows.cmd" "$ROOT_DIR/dist/install-windows.cmd"

(
  cd "$(dirname "$ROOT_DIR")"
  zip -qr "$ARCHIVE_PATH" "$PACKAGE_NAME" \
    -x "$PACKAGE_NAME/dist/*" \
    -x "$PACKAGE_NAME/.DS_Store" \
    -x "$PACKAGE_NAME/**/.DS_Store" \
    -x "$PACKAGE_NAME/.git/*"
)

(
  cd "$BOOTSTRAP_DIR"
  zip -qr "$ROOT_DIR/dist/bootstrap-entry.zip" \
    install-macos.command \
    install-windows.cmd
)

archive_hash="$(openssl dgst -sha256 "$ARCHIVE_PATH" | awk '{print $NF}')"
bootstrap_hash="$(openssl dgst -sha256 "$ROOT_DIR/dist/bootstrap-entry.zip" | awk '{print $NF}')"
printf '%s\n' \
  "Release built:" \
  "  Full package: $ARCHIVE_PATH" \
  "  Full package SHA-256: $archive_hash" \
  "  Bootstrap entry ZIP: $ROOT_DIR/dist/bootstrap-entry.zip" \
  "  Bootstrap entry SHA-256: $bootstrap_hash" \
  "  Standalone entry scripts:" \
  "    $ROOT_DIR/dist/install-macos.command" \
  "    $ROOT_DIR/dist/install-windows.cmd"
