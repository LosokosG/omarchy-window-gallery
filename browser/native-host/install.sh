#!/bin/bash
# Registers the native messaging host with Firefox. Run once.
set -euo pipefail

host_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
host_script="$host_dir/omarchy-window-gallery-host.py"
manifest_dir="$HOME/.mozilla/native-messaging-hosts"
manifest="$manifest_dir/omarchy_window_gallery.json"

[[ -f $host_script ]] || { echo "missing $host_script" >&2; exit 1; }
chmod +x "$host_script"
mkdir -p "$manifest_dir"

# allowed_extensions must match the id in firefox-extension/manifest.json, or
# Firefox refuses the connection without a visible error.
cat > "$manifest" <<JSON
{
  "name": "omarchy_window_gallery",
  "description": "Publishes Firefox tabs to the Omarchy window gallery",
  "path": "$host_script",
  "type": "stdio",
  "allowed_extensions": ["window-gallery@losokos"]
}
JSON

echo "Registered native host at $manifest"
echo
echo "Next: install the signed extension so it survives restarts."
echo "  Download the .xpi from the project's releases, then: firefox <file>.xpi"
echo
echo "For development only (dropped on every Firefox restart):"
echo "  about:debugging#/runtime/this-firefox -> Load Temporary Add-on"
echo "  -> $host_dir/../firefox-extension/manifest.json"
