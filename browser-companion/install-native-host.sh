#!/usr/bin/env bash
set -euo pipefail

usage() {
  printf 'Usage: %s chromium <extension-id> | firefox\n' "$0" >&2
  exit 2
}

browser="${1:-}"
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
data_home="${XDG_DATA_HOME:-$HOME/.local/share}"
config_home="${XDG_CONFIG_HOME:-$HOME/.config}"
host_path="$data_home/omakhinsider/native-host.py"
manifest_path=""
extension_id="${2:-}"

case "$browser" in
  chromium)
    [[ "$extension_id" =~ ^[a-p]{32}$ ]] || usage
    manifest_path="$config_home/chromium/NativeMessagingHosts/org.omarchy.omakhinsider.json"
    ;;
  firefox)
    [[ $# -eq 1 ]] || usage
    manifest_path="$HOME/.mozilla/native-messaging-hosts/org.omarchy.omakhinsider.json"
    ;;
  *)
    usage
    ;;
esac

install -D -m 755 "$script_dir/native-host/omakhinsider_native_host.py" "$host_path"

write_manifest() {
  local destination="$1"
  local browser_name="$2"
  local extension_id="${3:-}"
  python3 - "$host_path" "$destination" "$browser_name" "$extension_id" <<'PY'
import json
import os
import sys

host_path, destination, browser_name, extension_id = sys.argv[1:]
manifest = {
    "name": "org.omarchy.omakhinsider",
    "description": "Sends KHInsider album URLs to OmaKhinsider",
    "path": host_path,
    "type": "stdio",
}
if browser_name == "chromium":
    manifest["allowed_origins"] = [f"chrome-extension://{extension_id}/"]
else:
    manifest["allowed_extensions"] = ["omakhinsider@kelmankenberg.github.io"]

os.makedirs(os.path.dirname(destination), exist_ok=True)
with open(destination, "w", encoding="utf-8") as output:
    json.dump(manifest, output, indent=2)
    output.write("\n")
PY
}

write_manifest "$manifest_path" "$browser" "$extension_id"

printf 'Installed the %s native messaging host registration.\n' "$browser"
