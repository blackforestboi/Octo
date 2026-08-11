# GitHub Actions Workflows for Octo

## Publish Initial Update Feed

`publish-update-feed.yml` deploys `docs/updates/appcast.xml` to GitHub Pages.
It runs when that file changes on `main` or when manually dispatched.

## Hosted release pipeline

`release.yml` builds, Developer ID-signs, notarizes, staples, and packages a
tagged release on a GitHub-hosted macOS runner. It publishes the GitHub Release,
generates the signed Sparkle appcast, and deploys the feed to GitHub Pages.

Pushing a `v*` tag starts the workflow. An existing tag can be retried through
the workflow's manual `tag` input.

## Local release pipeline

The production release pipeline runs on the local release machine:

```bash
bun run release -- --local-build --tag v<version> --publish
```

The `--local-build` switch makes the archive, Developer ID signing, notarization,
stapling, packaging, and validation happen locally. The rest of the flow is
unchanged: it uploads the completed ZIP and DMG through the GitHub API,
generates and signs the Sparkle appcast, and commits the feed. The resulting
appcast commit triggers the Pages-only workflow above.

`bun run release:local -- --tag v<version> --publish` is a convenience alias
that supplies `--local-build` automatically.

The local pipeline remains available when a release should be built on the
maintainer's Mac instead of GitHub Actions.
