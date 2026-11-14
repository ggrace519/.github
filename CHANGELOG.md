# Changelog

## [Unreleased]

### Added
- Reusable `version` workflow. Before a promotion it works out the next semantic version from the entries under `[Unreleased]` (an entry that starts with `BREAKING` is a major bump, `### Added` a minor one, anything else a patch), rolls them into a dated version section and commits that to `develop`, so promotions no longer need a hand-edited changelog. Entries that land before the promotion is merged fold into the same version. The tag is still created on `main` by `release`. Existing callers are unaffected until they chain `version` ahead of `promote`.
- This repository promotes itself with `version` and `promote` (`self-promote.yml`), and every pull request into `develop` reports the release it would produce.

### Fixed
- The `release` workflow's step summary and dry-run log named the previous release twice over, as `v1.0.21.0.2`. They now read `v1.0.2`. Release notes and tags were never affected.

## [1.1.0] - 2026-11-07

### Changed
- All workflows pin `actions/checkout` to v7.0.1 (Node 24) instead of v4.4.0. Every run on GitHub-hosted runners warned that Node 20 is deprecated and was forced onto Node 24; the pin now matches the runtime actually used.

### Added
- A `SECURITY.md` with the default security policy, so that reports have a documented path (#24).
- Reusable `release` workflow for repositories that keep a changelog and semantic versions. On every push to `main` it tags the changelog's top `## [X.Y.Z]` version and publishes a GitHub release with that section as the notes, so releases stop being cut by hand and the notes match the changelog. `dry-run` validates the changelog on the promotion pull request, and `major-tag` moves `vX`. Callers get `version`, `tag`, `released` and `url` outputs to chain tag-triggered builds, because tags made with `GITHUB_TOKEN` start no workflows.
- This repository releases itself with that workflow (`self-release.yml`).

### Fixed
- The README no longer claims that CI runs on a newly opened promotion pull request. GitHub holds the `pull_request` run fired by a pull request that `github-actions[bot]` opened until someone approves it; only later pushes to `develop` run on their own. The earlier evidence (tetris-c #14) was a run after a manual approval. The README now says to approve the first run, and explains the red zero-job run that graphLM shows afterwards (#20).
- The README's caller template no longer lets a skipped promote run cancel the real one. A develop merge also re-runs lint on the open promotion PR, and that run's promote job is skipped. In the shared concurrency group it cancelled the push-triggered run, so the promotion PR wasn't refreshed. Only push and manual runs share the group now. Existing callers have to copy the new block; nothing in `promote.yml` itself changed (#17).

### Docs
- The README now tells callers to pin a release's commit SHA instead of `@v1`, and describes the tag protection on release tags.

## [1.0.2] - 2026-10-27

### Changed
- `promote` and the lint workflow pin `actions/checkout` to a commit SHA (v4.4.0) instead of the mutable `v4` tag, so a moved upstream tag can no longer change what runs on callers' runners, including self-hosted ones.

## [1.0.1] - 2026-10-25

### Added
- `promote` takes an optional `base` input (default `main`) for repos whose promotion branch has another name, such as `master`. Existing callers are unaffected.
- `promote` takes an optional `runs-on` input (a label or a JSON array of labels, default `ubuntu-latest`) so private callers can run the job on their self-hosted runners instead of spending GitHub-hosted minutes. Existing callers are unaffected.

### Docs
- Corrected the README: CI does run on the promotion pull request. The earlier text wrongly said required checks on `main` would never report.

## [1.0.0] - 2026-10-17

### Added
- Reusable `promote` workflow. It opens and maintains one `develop` → `main` promotion pull request after CI passes on `develop`. It is extracted from homelab-swarm, and the deploy note is now an optional `merge-note` input.
- actionlint CI for the workflows in this repository.
