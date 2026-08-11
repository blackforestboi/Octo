# Octo Release Process

Releases are built for Apple Silicon (`arm64`), signed, notarized, stapled, and
packaged either through GitHub Actions or the local release command. Both paths
publish the GitHub Release and a signed Sparkle feed.

## GitHub-hosted release

Update and commit the marketing version, build number, and changelog, then push
the release commit and its tag:

```bash
git push origin main
git tag -a v2026.8.111 -m "Release v2026.8.111"
git push origin v2026.8.111
gh workflow run release.yml --ref main -f tag=v2026.8.111
```

The manual dispatch starts `.github/workflows/release.yml` from the Pages-approved
`main` branch while checking out the immutable tag for the build. It signs,
notarizes, packages, and publishes the release entirely on GitHub-hosted
infrastructure. The release workflow requires the repository's Apple signing,
App Store Connect API, and Sparkle private-key secrets.

## Local prerequisites

- A Developer ID Application identity for team `5YUPQC9D96` in the login Keychain.
- A validated `notarytool` Keychain profile named `AC_PASSWORD` (or another
  profile supplied through `NOTARY_PROFILE`).
- GitHub CLI authentication with write access: `gh auth login`.
- The Sparkle private Ed25519 key. Store it in the Keychain once, without putting
  it in the repository or shell history:

  ```bash
  read -s -p "Sparkle private key: " sparkle_key; echo
  security add-generic-password -U -a "$USER" -s "Octo Sparkle Private Key" -w "$sparkle_key"
  unset sparkle_key
  ```

  Alternatively, set `SPARKLE_PRIVATE_KEY_FILE` for an individual release.

## First-time setup

1. In **Settings → Pages**, select **GitHub Actions** as the source.
2. Push `docs/updates/appcast.xml` or manually run **Publish Initial Update Feed**. This serves the initial feed at <https://blackforestboi.github.io/Octo/appcast.xml>.
3. Confirm the feed returns an XML document before the first release. The
   `Publish Initial Update Feed` workflow remains responsible only for deploying
   this static feed.

## Publish a release

```bash
bun run release -- --local-build --tag v2026.7.162 --publish
```

Run the command only from a clean default branch after the release version is
committed. `--local-build` is the build-location switch: it makes the archive,
Developer ID signing, notarization, stapling, and packaging happen on this Mac.
All publishing steps remain in the same flow: it creates and pushes the tag if
needed, uploads the Apple Silicon-only notarized ZIP and DMG to GitHub Releases,
then signs and commits the appcast. The appcast commit triggers the lightweight
Pages deployment workflow; it does not start a macOS build.

`bun run release:local -- --tag v2026.7.162 --publish` remains as a convenience
alias for the same pipeline and supplies `--local-build` automatically.

Before the archive, the command checks that `CFBundleVersion` and every
`CURRENT_PROJECT_VERSION` agree. For a new tag, if the source build number is
not newer than either the live Pages feed or the committed feed, it increments
both sources, commits that metadata change, and pushes it before building. The
generated appcast and archived app are checked again before publishing.

The command refuses to publish unless `--publish` is provided. This prevents an
accidental build or GitHub release while preparing a release.

Release archives use the persistent, ignored `build/DerivedData-Release` cache.
The command fingerprints the SwiftPM manifests and lockfiles, Xcode project
package references, and the Xcode toolchain version. Version/build-number edits
are excluded from the project fingerprint, so version bumps do not clear the
dependency cache. It clears that cache only when dependency inputs or the
toolchain change; ordinary Swift source changes stay incremental.

Once it completes, open the appcast and confirm its newest item has a
`sparkle:edSignature` and points to the corresponding GitHub release asset.

The MIT license and Hex attribution remain in the repository; Octo's feed, signing key, bundle identifier, release assets, and GitHub links are independent from upstream Hex.
