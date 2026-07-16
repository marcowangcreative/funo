#!/usr/bin/env bash
# Cut an f/uno update end-to-end:
#   ./cut_release.sh 0.9.1
# Builds the signed+notarized DMG, drops it in site/updates/, and regenerates
# the Sparkle appcast (signing with the private key in your login Keychain).
# Then just review and push — Vercel serves the feed at funophoto.com/updates/.
set -euo pipefail

VERSION="${1:?usage: ./cut_release.sh <version>   e.g. ./cut_release.sh 0.9.1}"
ROOT="$(cd "$(dirname "$0")" && pwd)"
SPARKLE_BIN="$ROOT/.build/artifacts/sparkle/Sparkle/bin"
UPDATES="$ROOT/site/updates"
DMG="$ROOT/dist/Funo-$VERSION.dmg"

if [ ! -x "$SPARKLE_BIN/generate_appcast" ]; then
  echo "✗ generate_appcast not found — run 'swift build' once to fetch Sparkle." >&2
  exit 1
fi

echo "▸ [1/3] Building $VERSION (signed + notarized)…"
VERSION="$VERSION" "$ROOT/build_app.sh"

echo "▸ [2/3] Staging DMG into site/updates/…"
mkdir -p "$UPDATES"
cp "$DMG" "$UPDATES/"

echo "▸ [3/3] Regenerating appcast.xml…"
# --download-url-prefix makes the <enclosure> URLs absolute to your host.
"$SPARKLE_BIN/generate_appcast" \
  --download-url-prefix "https://www.funo.photo/updates/" \
  "$UPDATES"

echo
echo "✅ $VERSION released into site/updates/."
echo "   Review site/updates/appcast.xml, then:"
echo "     git add site/updates && git commit -m \"release $VERSION\" && git push"
echo "   Installed copies pick it up on their next update check."
