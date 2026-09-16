#!/bin/bash
# One-command setup for browser-tab support.
#
# Registers the native messaging host, downloads the signed extension pinned
# below, verifies it, and hands it to Firefox to install. The user's only
# remaining step is accepting Firefox's install prompt.
#
# The download is bound to this commit: a fixed release tag and asset name, an
# expected SHA-256, and a check that the archive's code is exactly the
# extension source shipped next to this script. Publishing a new extension
# build therefore means updating all three constants in the same commit that
# changes browser/firefox-extension/.
set -euo pipefail

readonly XPI_TAG="v1.0.0"
readonly XPI_ASSET="a0b8b2c87a1b46e596b9-1.1.0.xpi"
readonly XPI_SHA256="56ff12b98bc92e1ac1f2b5b360d6612775192556000188da25f35304ad1b9037"
readonly XPI_URL="https://github.com/LosokosG/omarchy-window-gallery/releases/download/$XPI_TAG/$XPI_ASSET"
readonly XPI_MAX_BYTES=1048576
# GitHub serves release assets through a redirect to this host.
readonly XPI_ALLOWED_HOSTS="github.com release-assets.githubusercontent.com objects.githubusercontent.com"

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
cache="${XDG_CACHE_HOME:-$HOME/.cache}/omarchy-window-gallery"

die() { echo "error: $*" >&2; exit 1; }

for tool in firefox curl sha256sum unzip jq cmp; do
  command -v "$tool" >/dev/null 2>&1 || die "$tool is required"
done

echo "==> Registering the native messaging host"
"$here/native-host/install.sh" >/dev/null
echo "    done"

umask 077
mkdir -p "$cache"
[[ -d $cache && ! -L $cache && -O $cache ]] || die "$cache must be a directory owned by you"
chmod 700 "$cache"

tmp=$(mktemp "$cache/.download.XXXXXXXX")
trap 'rm -f "$tmp"' EXIT

echo "==> Downloading $XPI_ASSET ($XPI_TAG)"
# Anything unusual in the authority (userinfo, port) leaves a host string that
# is not on the allowlist, so it is refused rather than parsed.
host_of() {
  local rest=${1#https://}
  [[ $rest != "$1" ]] || return 0
  printf '%s\n' "${rest%%[/?#]*}"
}

# Redirects are followed by hand so every hop is checked against the allowlist
# before anything is requested from it.
url="$XPI_URL"
for hop in 0 1 2 3; do
  host=$(host_of "$url")
  [[ " $XPI_ALLOWED_HOSTS " == *" $host "* ]] || die "refusing to download from unexpected host: $host"
  result=$(curl --silent --show-error \
    --proto '=https' --max-redirs 0 \
    --connect-timeout 15 --max-time 60 \
    --max-filesize "$XPI_MAX_BYTES" \
    --output "$tmp" --write-out '%{http_code} %{redirect_url}' \
    "$url") || die "download failed"
  status=${result%% *}
  next=${result#* }
  case $status in
    200) break ;;
    301|302|303|307|308)
      [[ $next == https://* ]] || die "refusing non-HTTPS redirect"
      (( hop < 3 )) || die "too many redirects"
      url=$next ;;
    *) die "download failed with HTTP $status" ;;
  esac
done
[[ $status == 200 ]] || die "download failed"

size=$(stat -c %s "$tmp")
(( size > 0 && size <= XPI_MAX_BYTES )) || die "downloaded file has unexpected size: $size bytes"

echo "==> Verifying"
actual_sha=$(sha256sum "$tmp" | cut -d' ' -f1)
[[ $actual_sha == "$XPI_SHA256" ]] || die "checksum mismatch: expected $XPI_SHA256, got $actual_sha"

# The archive must contain the extension source from this checkout and nothing
# else besides Mozilla's signature files. AMO re-serializes manifest.json, so
# it is compared as normalized JSON; every other file must match byte for byte.
# Nothing in the archive is executed here.
src="$here/firefox-extension"
listing=$(unzip -Z1 "$tmp") || die "the download is not a valid extension archive"
packed=$(grep -v '/$' <<<"$listing" \
  | grep -vxE 'META-INF/(manifest\.mf|mozilla\.sf|mozilla\.rsa|cose\.manifest|cose\.sig)' \
  | sort || true)
expected=$(find "$src" -mindepth 1 -maxdepth 1 -type f -printf '%f\n' | sort)
[[ $packed == "$expected" ]] || die "the extension's files do not match the source in this checkout"
grep -qx 'META-INF/mozilla.rsa' <<<"$listing" && grep -qx 'META-INF/cose.sig' <<<"$listing" \
  || die "the extension archive is not signed"
while IFS= read -r name; do
  if [[ $name == manifest.json ]]; then
    [[ $(unzip -p "$tmp" manifest.json | jq -cS .) == "$(jq -cS . "$src/manifest.json")" ]] \
      || die "manifest.json differs from the source in this checkout"
  else
    unzip -p "$tmp" "$name" | cmp -s - "$src/$name" \
      || die "$name differs from the source in this checkout"
  fi
done <<<"$expected"
echo "    checksum and contents match this checkout"

# The verified file is kept: Firefox reads it asynchronously after this script
# exits, so deleting it here could break the install. It is private to the user
# and overwritten atomically on the next run.
target="$cache/better-alt-tab-tabs.xpi"
chmod 600 "$tmp"
mv -f "$tmp" "$target"
trap - EXIT

echo "==> Opening it in Firefox"
firefox "$target" >/dev/null 2>&1 &

cat <<'DONE'

Firefox will ask to add the extension -- accept it.

That is the last step: your tabs then show up in ALT+TAB alongside your
windows, searchable by title and URL. Re-run this script after updating the
plugin to install the extension build pinned by that version.
DONE
