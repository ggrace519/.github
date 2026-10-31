# Changelog

## [Unreleased]

### Fixed
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
