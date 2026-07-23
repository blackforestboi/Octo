# Octo Release Process

Releases are created by pushing a `v*` tag. The GitHub Actions workflow signs and notarizes Octo, publishes an `Octo-{version}.dmg` and `Octo-{version}.zip` GitHub release, then generates and deploys the signed Sparkle feed.

## Required repository secrets

- `MACOS_CERTIFICATE` and `MACOS_CERTIFICATE_PWD` — Developer ID certificate used to sign the app.
- `APPLE_API_KEY`, `APPLE_API_KEY_ID`, and `APPLE_API_ISSUER` — App Store Connect credentials used for notarization.
- `SPARKLE_PRIVATE_KEY` — the private Ed25519 Sparkle signing key. It signs the update feed and must match `SUPublicEDKey` in `Hex/Info.plist`.

## First-time setup

1. In **Settings → Pages**, select **GitHub Actions** as the source.
2. Push `docs/updates/appcast.xml` or manually run **Publish Initial Update Feed**. This serves the initial feed at <https://blackforestboi.github.io/Octo/appcast.xml>.
3. Confirm the feed returns an XML document before the first release.

## Publish a release

```bash
git tag v2026.7.162
git push origin v2026.7.162
```

The tag must match `CFBundleShortVersionString`. Once the release job succeeds, open the appcast and confirm its newest item has a `sparkle:edSignature` and points to the corresponding GitHub release asset.

The MIT license and Hex attribution remain in the repository; Octo's feed, signing key, bundle identifier, release assets, and GitHub links are independent from upstream Hex.
