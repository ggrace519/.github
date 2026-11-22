# Decisions

## ADR-001: The changelog is rolled by a bot commit on develop; the tag stays on the merge

Date: 2026-11-14. Status: partly superseded by ADR-002 (the roll-up is now a pull request, not a direct commit).

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

## ADR-002: The roll-up is a pull request, opened as a GitHub App when one is configured

Date: 2026-11-16. Status: accepted. Supersedes the direct commit of ADR-001.

### Context

Under ADR-001, `version` committed the rolled changelog straight to `develop`. That was the one commit to reach `develop` without a pull request, which the branch model does not allow. It also meant the commit made with `GITHUB_TOKEN` started no `push` workflow, and the `pull_request` runs GitHub holds for bot pull requests needed an approval click on every promotion (#20).

### Decision

- `version` builds the roll-up on `chore/roll-changelog` and opens or updates one pull request from it into `develop`. Merging it is the decision to release. The branch is owned by the workflow: each run rebuilds it as the head of `develop` plus one commit, and deletes it once nothing is left to roll.
- The commit is built on a scratch branch (`chore/roll-changelog-staging`) and the roll-up branch is moved onto it in one step. GitHub closes a pull request whose branch points at its base commit, even for a moment, so the branch is never reset to `develop` first. The staging branch is fresh, so `expectedHeadOid` no longer guards `develop`; the head is read again before the roll-up branch moves, and a run that `develop` overtook writes nothing.
- The branch name is fixed rather than carrying the version. A re-roll that turns a patch into a minor would otherwise leave a stale branch and pull request behind.
- `promote` runs only when `version` reports `promote: 'true'`: nothing left to roll, and `ref` still the head of `develop`. An empty `pull-request` alone would also be true for a run that `develop` overtook, which would refresh the promotion pull request from a stale commit. Merging the roll-up is a push by a person, so lint runs on it, `version` finds the pending section with nothing to roll, and `promote` opens the promotion pull request with the rolled changelog. The existing pending-section logic needs no change. Amended 2026-11-22: `promote` is `'true'` only when that pending section exists. With an empty `[Unreleased]` and the top version already tagged, a promotion carries no new version and `release` must fail it, so `version` reports `'false'` and a change merged without a changelog entry waits for the next release.
- Both workflows take an optional GitHub App, a dedicated one with only Contents and Pull requests access. Its pull requests run checks without approval. Without it they fall back to `GITHUB_TOKEN`; a configured app that cannot mint a token fails the run, so a broken setup is not hidden by the fallback. This reverses the 2026-11-07 decision to keep the click: there are now two bot pull requests per release instead of one.
- The rest of ADR-001 stands: the roll lands on `develop`, the version comes from the changelog categories, and the tag is created on `main`'s merge commit.

### Consequences

- This is a breaking change for callers of `version`. They need `pull-requests: write`, even for a dry run, and a gate on the new `promote` output in place of `rolled`; the `token` secret is gone.
- A release takes two merges by a person: the roll-up into `develop`, then the promotion into `main`.
- Without the app, each roll-up pull request costs one "Approve and run" click, as promotion pull requests do.
- A branch ruleset on `develop` that requires pull requests no longer gets in the way. A ruleset that covers `chore/` branches would.
