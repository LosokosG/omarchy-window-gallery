#!/bin/bash
# One-command setup for browser-tab support.
#
# Registers the native messaging host, fetches the signed extension from the
# project's latest release, and hands it to Firefox to install. The user's
# only remaining step is accepting Firefox's install prompt.
set -euo pipefail

REPO="${OMARCHY_WINDOW_GALLERY_REPO:-LosokosG/omarchy-window-gallery}"
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
cache="${XDG_CACHE_HOME:-$HOME/.cache}/omarchy-window-gallery"

command -v firefox >/dev/null 2>&1 || { echo "firefox not found on PATH" >&2; exit 1; }
command -v curl >/dev/null 2>&1 || { echo "curl is required" >&2; exit 1; }

echo "==> Registering the native messaging host"
"$here/native-host/install.sh" >/dev/null
echo "    done"

echo "==> Looking for a signed extension in the latest release"
release_json=$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" 2>/dev/null || true)
xpi_url=$(printf '%s' "$release_json" | python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(0)
for asset in data.get("assets", []):
    if asset.get("name", "").endswith(".xpi"):
        print(asset["browser_download_url"])
        break
' 2>/dev/null || true)

if [[ -z ${xpi_url:-} ]]; then
  cat >&2 <<'NOTE'

No signed extension is published yet.

Tab support needs a signed build, because Firefox drops a temporary add-on on
every restart. Either:

  * sign your own:  ./browser/sign-extension.sh   (see README), or
  * load it temporarily for this session only:
      about:debugging#/runtime/this-firefox -> Load Temporary Add-on

The window gallery itself is already working; only browser tabs need this.
NOTE
  exit 1
fi

mkdir -p "$cache"
echo "==> Downloading $(basename "$xpi_url")"
curl -fsSL -o "$cache/tabs.xpi" "$xpi_url"

echo "==> Opening it in Firefox"
firefox "$cache/tabs.xpi" >/dev/null 2>&1 &

cat <<'DONE'

Firefox will ask to add the extension -- accept it.

That is the last step: your tabs then show up in ALT+TAB alongside your
windows, searchable by title and URL. Re-run this script to update the
extension after a new release.
DONE
