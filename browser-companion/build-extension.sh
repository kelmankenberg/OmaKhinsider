#!/usr/bin/env bash
set -euo pipefail

usage() {
  printf 'Usage: %s <chromium|firefox>\n' "$0" >&2
  exit 2
}

browser="${1:-}"
case "$browser" in
  chromium|firefox) ;;
  *) usage ;;
esac

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source_dir="$script_dir/extension"
output_dir="$script_dir/build/$browser"

mkdir -p "$output_dir"
cp "$source_dir/popup.html" "$source_dir/popup.css" "$source_dir/popup.js" \
  "$source_dir/background.js" "$source_dir/inspect.js" "$output_dir/"
cp "$source_dir/manifest.$browser.json" "$output_dir/manifest.json"
mkdir -p "$output_dir/icons"
cp "$source_dir/icons/"*.png "$output_dir/icons/"
printf 'Built %s extension at %s\n' "$browser" "$output_dir"
