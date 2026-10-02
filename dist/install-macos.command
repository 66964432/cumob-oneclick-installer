#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DEFAULT_INSTALLER_URL="https://github.com/66964432/cumob-oneclick-installer/archive/refs/heads/main.zip"

run_local() {
  bash "$SCRIPT_DIR/install.sh" "$@"
}

bootstrap_from_github() {
  command -v curl >/dev/null 2>&1 || {
    printf '%s\n' "curl is required to download the installer from GitHub." >&2
    return 1
  }
  command -v unzip >/dev/null 2>&1 || {
    printf '%s\n' "unzip is required to extract the installer from GitHub." >&2
    return 1
  }

  local installer_url="${CUMOB_INSTALLER_URL:-$DEFAULT_INSTALLER_URL}"
  local work_dir
  work_dir="$(mktemp -d "${TMPDIR:-/tmp}/cumob-bootstrap.XXXXXX")"
  local archive="$work_dir/installer.zip"
  local extract_dir="$work_dir/extracted"
  mkdir -p "$extract_dir"

  printf 'Downloading latest installer from %s\n' "$installer_url"
  curl -fsSL --retry 3 --retry-delay 2 -o "$archive" "$installer_url"
  unzip -q "$archive" -d "$extract_dir"

  local installer_root=""
  local candidate
  for candidate in "$extract_dir"/*; do
    if [ -d "$candidate" ] && [ -f "$candidate/install.sh" ]; then
      installer_root="$candidate"
      break
    fi
  done

  if [ -z "$installer_root" ]; then
    printf '%s\n' "Downloaded installer archive is invalid." >&2
    rm -rf "$work_dir"
    return 1
  fi

  bash "$installer_root/install.sh" "$@"
  local status=$?
  rm -rf "$work_dir"
  return "$status"
}

status=0
if [ -f "$SCRIPT_DIR/install.sh" ] && [ -f "$SCRIPT_DIR/payload/cumob-models.json" ]; then
  run_local "$@" || status=$?
else
  bootstrap_from_github "$@" || status=$?
fi

printf '\n'
if [ "$status" -eq 0 ]; then
  printf '%s\n' "Installation finished. Press Return to close this window."
else
  printf 'Installation failed with exit code %s. Press Return to close this window.\n' "$status"
fi
IFS= read -r _
exit "$status"
