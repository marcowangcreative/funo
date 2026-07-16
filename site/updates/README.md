# site/updates/

Sparkle's update feed. Served at `https://funophoto.com/updates/`.

- `appcast.xml` — the feed. **Generated**, not hand-edited. `cut_release.sh`
  runs `generate_appcast` over this folder, which signs each DMG with the
  private key in your login Keychain and rewrites this file.
- `Funo-<version>.dmg` — the update archives Sparkle downloads. `cut_release.sh`
  copies each new DMG here.

To publish an update: `./cut_release.sh 0.9.1` from the repo root, review the
regenerated `appcast.xml`, then `git add site/updates && git commit && git push`.
Vercel serves it and installed copies pick it up on their next check.
