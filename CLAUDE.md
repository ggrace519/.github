# ggrace519/.github

Shared reusable GitHub Actions workflows. This repo is public so that private repos can call them.

- Branch model: `develop` is the default and integration branch. `main` is promoted through a PR, and releases are tagged on main. Releases also move the major tag `v1`. Release tags (`v*`) are protected by the `protect-release-tags` ruleset, which only admins can bypass. Known callers pin a release commit SHA (`@<sha> # vX.Y.Z`), not `@v1`. A new release does not reach them until each caller's pin is bumped. To find callers, scan every repo's `.github/workflows` across ggrace519, 519lab and tric-it2750. Code search misses private repos.
- Lint: `actionlint` (CI: `.github/workflows/lint.yml`).
- `promote.yml` came from homelab-swarm's inline script. Keep the logic in sync here only. homelab-swarm now calls this workflow.
