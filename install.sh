#!/bin/sh
# ConfigDeck installer — downloads the latest release and installs it to
# /Applications. curl-based downloads carry no quarantine attribute, so the
# app launches without the Gatekeeper popup unsigned apps normally trigger.
#
#   curl -fsSL https://raw.githubusercontent.com/sanghun0724/configdeck/main/install.sh | sh
set -eu

REPO="sanghun0724/configdeck"
APP="ConfigDeck.app"
DEST="/Applications/$APP"

major=$(sw_vers -productVersion | cut -d. -f1)
if [ "$major" -lt 14 ]; then
  echo "ConfigDeck requires macOS 14 (Sonoma) or later." >&2
  exit 1
fi

echo "Fetching latest release…"
# Resolve the latest tag from the /releases/latest redirect — no GitHub API,
# so no rate limits. Assets are named ConfigDeck-<version>.zip by convention.
tag=$(curl -fsSLI -o /dev/null -w '%{url_effective}' "https://github.com/$REPO/releases/latest" | sed 's#.*/tag/##')
if [ -z "$tag" ] || [ "$tag" = "latest" ]; then
  echo "Could not resolve the latest release. See https://github.com/$REPO/releases" >&2
  exit 1
fi
zip_url="https://github.com/$REPO/releases/download/$tag/ConfigDeck-${tag#v}.zip"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

echo "Downloading $zip_url"
curl -fSL --progress-bar "$zip_url" -o "$tmp/app.zip"
ditto -x -k "$tmp/app.zip" "$tmp"

if [ ! -d "$tmp/$APP" ]; then
  echo "Unexpected archive layout — $APP not found in zip." >&2
  exit 1
fi

if [ -d "$DEST" ]; then
  echo "Replacing existing $DEST"
  rm -rf "$DEST"
fi
ditto "$tmp/$APP" "$DEST"

# ponytail: belt-and-braces for managed Macs that quarantine anyway
xattr -cr "$DEST" 2>/dev/null || true

echo ""
echo "✓ ConfigDeck installed to $DEST"
echo "  open -a ConfigDeck"
