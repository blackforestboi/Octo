# Octo update delivery

Octo's Sparkle feed is served from GitHub Pages at <https://blackforestboi.github.io/Octo/appcast.xml>. The app trusts only the public Ed25519 key in `Hex/Info.plist`, so an update from upstream Hex cannot be accepted.

The `release.yml` workflow publishes a signed DMG and ZIP to a GitHub release, then generates an appcast whose download URLs point at that release. It deploys the feed to GitHub Pages. Previous feed entries are fetched before generating the next one, so a release does not replace the update history.

One-time repository configuration:

1. Enable GitHub Pages with **GitHub Actions** as its source. The repository must use the workflow deployment source, not a branch source.
2. Add the `SPARKLE_PRIVATE_KEY` repository secret. It is the private counterpart of the public key in `Hex/Info.plist`; it is stored locally in the macOS Keychain under the `octo-updates` account.
3. Push `docs/updates/appcast.xml` or manually run **Publish Initial Update Feed** once to make the initial, empty feed available.

Never rotate the Sparkle key casually: every released Octo app trusts this public key. To verify a release, open the feed URL and check that its newest enclosure has a `sparkle:edSignature` and points to the matching GitHub release asset.
