#!/bin/bash
# Signs the tabs extension through addons.mozilla.org so Firefox installs it
# permanently.
#
# Release Firefox only permanently installs signed extensions -- a temporary
# add-on loaded from about:debugging is dropped on the next restart, and
# xpinstall.signatures.required is ignored on release builds. Signing is
# therefore the only way to make tab support survive a reboot.
#
# The "unlisted" channel signs the add-on for self-distribution: it is not
# published on addons.mozilla.org and needs no review, it just comes back
# signed so Firefox will accept it.
#
# Get an API key and secret (free) at:
#   https://addons.mozilla.org/developers/addon/api/key/
set -euo pipefail

: "${AMO_JWT_ISSUER:?set AMO_JWT_ISSUER (the API key from addons.mozilla.org)}"
: "${AMO_JWT_SECRET:?set AMO_JWT_SECRET (the API secret from addons.mozilla.org)}"

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source_dir="$here/firefox-extension"
out_dir="$here/dist"

command -v npx >/dev/null 2>&1 || { echo "npx is required (install Node.js)" >&2; exit 1; }

version=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["version"])' "$source_dir/manifest.json")
echo "Signing extension version $version (unlisted channel)…"

mkdir -p "$out_dir"

# AMO rejects a version it has already signed, so a re-sign needs a version
# bump in firefox-extension/manifest.json.
npx --yes web-ext@latest sign \
  --source-dir "$source_dir" \
  --artifacts-dir "$out_dir" \
  --channel unlisted \
  --api-key "$AMO_JWT_ISSUER" \
  --api-secret "$AMO_JWT_SECRET"

xpi=$(find "$out_dir" -name '*.xpi' -newer "$source_dir/manifest.json" -print -quit)
[[ -n ${xpi:-} ]] || xpi=$(find "$out_dir" -name '*.xpi' -print -quit)

echo
echo "Signed: $xpi"
echo "Install it permanently with:"
echo "  firefox \"$xpi\""
