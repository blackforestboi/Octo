# GitHub Actions Workflows for Octo

## Publish Initial Update Feed

`publish-update-feed.yml` deploys `docs/updates/appcast.xml` to GitHub Pages.
It runs when that file changes on `main` or when manually dispatched.

## Local release pipeline

The production release pipeline runs on the local release machine:

```bash
bun run release:local -- --tag v<version> --publish
```

It builds, Developer ID-signs, notarizes, staples, packages, and validates the
app locally. It then uploads the completed ZIP and DMG through the GitHub API,
generates and signs the Sparkle appcast, and commits the feed. The resulting
appcast commit triggers the Pages-only workflow above.

No GitHub Actions workflow builds or notarizes a release.
