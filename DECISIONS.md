# Decisions

## ADR-001: The changelog is rolled by a bot commit on develop; the tag stays on the merge

Date: 2026-11-14. Status: accepted.

### Context

`release.yml` tags the changelog's top `## [X.Y.Z]` section on every push to `main` and fails the promotion pull request while `[Unreleased]` still has entries. Rolling the entries and choosing the version was a hand edit before every promotion.

### Decision

`version.yml` does the roll after CI passes on `develop` and before `promote` opens or refreshes the promotion pull request. It commits the rolled changelog directly to `develop` through the GraphQL `createCommitOnBranch` mutation, as `github-actions[bot]`. `release.yml` is unchanged and still creates the tag on `main`'s merge commit.

- The commit goes on `develop` because nowhere else works in this branch model. A commit on `main`, or on a release branch that is merged to `main`, leaves `main` with history that `develop` lacks, and every later promotion then has to merge it back.
- The tag is not created before the merge. A release tag is protected and cannot be moved, the develop commit is not the commit `main` ends up on, and a promotion that is never merged would leave a release that never shipped.
- The API commit is signed by GitHub and guarded by `expectedHeadOid`, so the workflow needs no git identity or signing key and cannot overwrite a branch that moved.
- The version comes from the changelog categories, not from commit messages, because the changelog is what these repositories already keep for every observable change.
- A rolled section that is not tagged and not on `main` is pending and is re-derived on every run, so several develop pushes before one merge still make one release.

### Consequences

- The roll-up is the one commit that reaches `develop` without a pull request.
- A `GITHUB_TOKEN` commit starts no `push` workflow, and the `pull_request` run it causes on the promotion pull request waits for approval. Each roll-up costs one "Approve and run" click unless the caller passes a `token` secret.
- A branch ruleset on `develop` that requires pull requests blocks the roll-up for `GITHUB_TOKEN`; such a repository needs the `token` secret.
- The bump rule is mechanical. A release that needs another version takes the `bump` input or a hand-edited heading, which later runs keep.
