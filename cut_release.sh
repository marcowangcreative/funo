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

# One version number = one build, FOREVER. Re-cutting a published version
# reuses its DMG filename, and browsers/CDNs serve their cached copy of the
# OLD bytes for an unchanged URL — "I downloaded the fix and the bug is
# still there." If the version already shipped, bump it. (Delete the DMG
# from site/updates first if you REALLY mean to re-cut.)
if [ -f "$UPDATES/$(basename "$DMG")" ]; then
  echo "✗ Funo-$VERSION.dmg already exists in site/updates/ — that version is published." >&2
  echo "  Bump the version instead: ./cut_release.sh <next-version>" >&2
  exit 1
fi

echo "▸ [1/3] Building $VERSION (signed + notarized)…"
VERSION="$VERSION" "$ROOT/build_app.sh"

echo "▸ [2/3] Staging DMG into site/updates/…"
mkdir -p "$UPDATES"
cp "$DMG" "$UPDATES/"

echo "▸ [2.5/3] Bumping version on site pages…"
# The download buttons and "beta X.Y.Z" strings live in hand-written HTML —
# without this they silently drift behind the feed (0.9.1 stayed on the site
# through two releases).
sed -i '' -E \
  -e "s/Funo-[0-9]+\.[0-9]+\.[0-9]+\.dmg/Funo-$VERSION.dmg/g" \
  -e "s/beta [0-9]+\.[0-9]+\.[0-9]+/beta $VERSION/g" \
  -e "s|uno [0-9]+\.[0-9]+\.[0-9]+|uno $VERSION|g" \
  "$ROOT/site/index.html" "$ROOT/site/features.html"

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
