# ggrace519/.github

Shared GitHub Actions workflows for repositories that use the `develop` → `main` branch model.

## promote

`.github/workflows/promote.yml` is a reusable workflow. It opens a single `develop` → `main` promotion pull request and rewrites that pull request's summary whenever `develop` moves again before the merge. It closes the pull request once `develop` has nothing that `main` lacks.

Add this caller to a repository as `.github/workflows/promote.yml`. Set `workflows:` to the `name:` of that repository's CI workflow:

```yaml
name: promote
on:
  workflow_run:
    workflows: [CI]
    types: [completed]
    branches: [develop]
  workflow_dispatch:
permissions:
  contents: read
  pull-requests: write
# Only push-triggered and manual runs share the group. A develop merge also re-runs lint on the
# open promotion PR; that run's promote job is skipped by `if`, but concurrency applies before
# `if`, so in a shared group it would cancel the push run that does the work (#17).
concurrency:
  group: >-
    ${{ (github.event_name == 'workflow_dispatch' || github.event.workflow_run.event == 'push')
        && 'promote-develop-to-main' || format('promote-skip-{0}', github.run_id) }}
  cancel-in-progress: true
jobs:
  promote:
    if: >-
      github.event_name == 'workflow_dispatch' ||
      (github.event.workflow_run.conclusion == 'success' &&
       github.event.workflow_run.event == 'push')
    uses: ggrace519/.github/.github/workflows/promote.yml@56da419a93d4eca7fe1771297dc734fbd9c39fb4 # v1.0.2
    with:
      ref: ${{ github.event.workflow_run.head_sha }}
      # merge-note: "What merging to main deploys, if anything."
      # base: master   # promotion target; defaults to main
      # runs-on: '["self-hosted","linux"]'   # label or JSON array; defaults to ubuntu-latest
      # app-client-id: ${{ vars.RELEASE_APP_CLIENT_ID }}   # open the PR as a GitHub App; see below
    # secrets:
    #   app-private-key: ${{ secrets.RELEASE_APP_PRIVATE_KEY }}
```

Requirements:
- The default branch must be `develop`. `workflow_run` only fires for workflows on the default branch.
- Turn on Settings → Actions → "Allow GitHub Actions to create and approve pull requests":
  `gh api -X PUT repos/OWNER/REPO/actions/permissions/workflow -f default_workflow_permissions=read -F can_approve_pull_request_reviews=true`
- The CI run fired by opening the promotion pull request is held for approval. GitHub puts `pull_request` runs on pull requests that `github-actions[bot]` created or updated into an approval-required state, whatever the fork-PR approval policy says (changelog of 2026-06-11, "Bot-created pull requests can run workflows if approved"). A new promotion pull request therefore shows no CI result until someone with write access clicks "Approve and run", or until the next push to `develop`, whose `synchronize` run is credited to the pushing user and runs on its own. In graphLM the held run later shows up as a red, zero-job "workflow file issue" failure once the pull request merges; that is the held run, not a real break (#20). A GitHub App removes the wait; see [Release app](#release-app).

Merge promotion pull requests with a merge commit, never a squash or rebase.

## version

`.github/workflows/version.yml` is a reusable workflow that rolls the changelog before a promotion, so nobody edits version headings by hand. Run it after CI passes on `develop` and ahead of `promote`. It moves the entries under `## [Unreleased]` into a dated `## [X.Y.Z] - YYYY-MM-DD` section and opens a roll-up pull request with that into `develop`. Merging the roll-up pull request is the decision to release. The run that merge starts has nothing left to roll, so `promote` opens the promotion pull request, which then already carries the changelog that `release` tags when it is merged. The tag itself is still created on `main` by the merge, never before it.

The version is the latest release bumped by the highest level the entries ask for:

| Entries since the last release | Bump |
| --- | --- |
| An entry that starts with `BREAKING` (`- BREAKING: ...`, bold or not), or a `### Breaking` heading | major |
| A `### Added` heading | minor |
| Anything else (`Changed`, `Fixed`, `Docs`, ...) | patch |

On `0.x` a major bump becomes a minor one, and a repository with no release yet starts from `0.0.0`. The `bump` input (`patch`, `minor`, `major`) overrides the level for one run.

A version section that has no tag and is not on `main` yet is pending. When `develop` moves again before the promotion is merged, the new entries are folded into the pending section category by category and its version is worked out again, so one promotion is one release. The version only moves up: edit the heading by hand (for example to `2.0.0`, or to a pre-release such as `1.3.0-rc.1`) and later runs keep it.

To add it, replace the `jobs:` block of the `promote` caller above with this one and change the caller's permissions to `contents: write` and `pull-requests: write`:

```yaml
jobs:
  version:
    if: >-
      github.event_name == 'workflow_dispatch' ||
      (github.event.workflow_run.conclusion == 'success' &&
       github.event.workflow_run.event == 'push')
    permissions:
      contents: write
      pull-requests: write
    uses: ggrace519/.github/.github/workflows/version.yml@<sha> # vX.Y.Z
    with:
      ref: ${{ github.event.workflow_run.head_sha }}
      app-client-id: ${{ vars.RELEASE_APP_CLIENT_ID }}   # optional; see Release app
      # bump: auto           # or patch, minor, major
      # branch: develop      # the roll-up pull request's base
      # base: main           # promotion target
      # changelog: CHANGELOG.md
      # tag-prefix: v
      # runs-on: '["self-hosted","linux"]'
    secrets:
      app-private-key: ${{ secrets.RELEASE_APP_PRIVATE_KEY }}
  promote:
    needs: version
    # Not while a roll-up pull request is open, nor for a commit develop has moved past.
    if: needs.version.outputs.promote == 'true'
    permissions:
      contents: read
      pull-requests: write
    uses: ggrace519/.github/.github/workflows/promote.yml@<sha> # vX.Y.Z
    with:
      ref: ${{ needs.version.outputs.sha }}
      app-client-id: ${{ vars.RELEASE_APP_CLIENT_ID }}
    secrets:
      app-private-key: ${{ secrets.RELEASE_APP_PRIVATE_KEY }}
```

Inputs: `ref`, `branch`, `base`, `changelog`, `tag-prefix`, `bump`, `dry-run`, `runs-on`, `app-client-id`; secret `app-private-key`. Outputs: `version`, `sha` (`ref`, the commit the run looked at), `pull-request` (the number of the roll-up pull request the run opened or updated, empty when there was nothing to roll) and `promote` (`'true'` when nothing is left to roll, the top version section is rolled but not yet released, and `ref` is still the head of `develop`). Run `promote` only when `promote` is `'true'`. While a roll-up pull request is open it would promote a `develop` whose `[Unreleased]` is not rolled yet, and the `release` check on the promotion pull request would fail; for a commit `develop` has moved past, the run for the newer commit decides.

Every caller grants the `version` job `pull-requests: write`, a `dry-run` one included: the workflow declares it, and a called workflow cannot get more than its caller grants.

Upgrading from v1: grant `pull-requests: write` to the `version` job, gate `promote` on the `promote` output as above, and replace the removed `token` secret and `rolled` output.

Notes:
- The roll-up pull request comes from `chore/roll-changelog` and is titled `chore(release): roll changelog into X.Y.Z`. The workflow owns that branch: every run rebuilds it as the head of `develop` plus one roll-up commit, so do not push to it. The commit is made through the API, so GitHub signs it. Merge it like any other pull request into `develop`.
- A feature branch that adds an entry under `[Unreleased]` can conflict in the changelog with a roll-up merged after it was cut. Resolve it by keeping the new entry under `[Unreleased]`; the next run rolls it.
- When `develop` moves before the roll-up is merged, the next run rebuilds the branch and updates the same pull request, with a new version in the title if the entries now ask for one.
- Once there is nothing left to roll, the run closes any open roll-up pull request with a comment and deletes `chore/roll-changelog` (and a `chore/roll-changelog-staging` left by a cancelled run). This also removes the branch after a merge in repositories that do not delete merged branches.
- Without an app, the pull request is opened with `GITHUB_TOKEN`, and its CI waits for "Approve and run" as on the promotion pull request. A branch ruleset that covers `chore/` branches refuses the commit; the run fails with an error that says so.
- When `develop` has moved past `ref`, before or during the run, the run writes nothing and `promote` is `'false'`. The run for the newer commit does the work.
- When `[Unreleased]` is empty and the top version is already released, `promote` is `'false'` and the run leaves a notice: a promotion would carry no new version, and the `release` check on it would fail. Changes merged without a changelog entry, such as internal docs, wait on `develop` and ride along with the next release.
- With `dry-run: true` no branch and no pull request are written, and the next version and its section go to the run summary. This repository runs that on every pull request into `develop`.
- `ref` must be a commit of `develop`. A manual run for a commit that is not on `develop` fails; one for an older commit of `develop` writes nothing, as above.
- Section headings must be `## [X.Y.Z] - YYYY-MM-DD`; a `## 1.2.0` heading without brackets fails the run. Headings inside fenced code blocks are left alone. CRLF line endings are kept.
- Empty categories are dropped. Link reference definitions (`[1.2.0]: https://...`) are not created or updated; ones found under `[Unreleased]` move to the end of the file.
- A promotion with no changelog entry at all is left alone and still fails the `release` check below.

## Release app

`version` and `promote` open their pull requests with `GITHUB_TOKEN` unless they are given a GitHub App. GitHub holds the CI run on a pull request that `github-actions[bot]` opened until someone clicks "Approve and run"; a pull request opened as an app runs its checks on its own. To use one:

1. Create a GitHub App under the account's Developer settings → GitHub Apps. It needs no webhook and no callback URL. Repository permissions: Contents read and write, Pull requests read and write (Metadata read is added on its own). Generate a private key.
2. Install it on every repository that calls these workflows.
3. In each of those repositories, add the app's client ID as the variable `RELEASE_APP_CLIENT_ID` and the whole `.pem` file as the secret `RELEASE_APP_PRIVATE_KEY`, then delete the downloaded key file. For example: `gh variable set RELEASE_APP_CLIENT_ID --body <client-id>` and `gh secret set RELEASE_APP_PRIVATE_KEY < app.pem`.

While the variable is empty the workflows use `GITHUB_TOKEN`. Once it is set, a token that cannot be minted, for example because the app is not installed on the repository, fails the run instead of falling back. The run summary of `version` names the token it used.

## release

`.github/workflows/release.yml` is a reusable workflow for repositories that keep a [Keep a Changelog](https://keepachangelog.com) `CHANGELOG.md` and semantic versions. On every push to `main` it reads the top `## [X.Y.Z] - YYYY-MM-DD` section. When that version has no tag yet, it creates the tag `vX.Y.Z` on the pushed commit and a GitHub release whose notes are that section. With `dry-run` it only validates, so the same workflow gates the promotion pull request: a promotion whose changelog is not ready fails its check before the merge. The `version` workflow above gets the changelog ready on its own.

It enforces, and fails with an `::error::` that names the fix:
- `[Unreleased]` has no entries left; they were rolled into a dated version section, by hand or by `version`.
- The top section is a semantic version with a date and at least one entry.
- That version is newer than the latest existing tag.
- If its tag already exists it points at this commit (a re-run, which is a no-op). Otherwise `main` moved without a new version.

Add this caller to a repository as `.github/workflows/release.yml`:

```yaml
name: release
on:
  push:
    branches: [main]
  pull_request:
    branches: [main]
permissions:
  contents: write
concurrency:
  group: release-${{ github.ref }}
  cancel-in-progress: false
jobs:
  release:
    uses: ggrace519/.github/.github/workflows/release.yml@<sha> # vX.Y.Z
    with:
      dry-run: ${{ github.event_name == 'pull_request' }}
      # major-tag: true      # also move v1 (for 1.x.y) to the release; see below
      # changelog: CHANGELOG.md
      # tag-prefix: v
      # runs-on: '["self-hosted","linux"]'   # label or JSON array; defaults to ubuntu-latest
    # secrets:
    #   token: ${{ secrets.RELEASE_TOKEN }}  # only to start tag-triggered workflows or bypass a tag ruleset
```

Inputs: `ref` (commit to release, default the triggering commit), `changelog`, `tag-prefix`, `major-tag`, `dry-run`, `runs-on`. Outputs: `version`, `tag`, `released` (`'true'` when this run created the release) and `url`.

Notes:
- A `1.2.0-rc.1` section makes a pre-release and does not move the major tag.
- Tags and releases created with `GITHUB_TOKEN` start no other workflow. A build that runs `on: push: tags` will not fire. Either chain the build in the same workflow (`needs: release`, `if: needs.release.outputs.released == 'true'`, tag in `needs.release.outputs.tag`) or pass a `token` secret (a fine-grained PAT with contents: write).
- `major-tag` moves an existing `vX` tag. A tag ruleset that blocks updates, like this repository's `protect-release-tags`, refuses that for `GITHUB_TOKEN`, and the run fails after the release was created. A re-run repairs the tag once the ruleset lets the workflow through. On a user-owned repository the `github-actions` app cannot be a bypass actor (the API answers "Actor GitHub Actions integration must be part of the ruleset source or owner organization"), so exclude the major tag from the ruleset instead. Release tags `vX.Y.Z` stay protected:
  ```sh
  id=$(gh api repos/OWNER/REPO/rulesets --jq '.[] | select(.name == "protect-release-tags") | .id')
  gh api -X PUT "repos/OWNER/REPO/rulesets/$id" --input - <<< '{"conditions": {"ref_name": {
    "include": ["refs/tags/v*"], "exclude": ["refs/tags/v[0-9]", "refs/tags/v[0-9][0-9]"]}}}'
  ```
  The alternative is a `token` secret holding a fine-grained PAT (contents: write) of a repository admin, who bypasses the ruleset.
- Adopting it in a repository whose `main` is already tagged at the changelog's top version is a no-op until the next version lands.

## Versioning

`self-promote.yml` runs `version` and `promote` after lint passes on `develop`: it opens a roll-up pull request that rolls `[Unreleased]` into the next version, and once that is merged it opens the promotion pull request. Releases are tagged `vX.Y.Z` on main by `self-release.yml`, which runs the `release` workflow above on every push to `main` and validates the changelog on the promotion pull request. `v1` is moved to the latest 1.x release by the same run; the tag ruleset excludes the major tag so that `GITHUB_TOKEN` may move it. Breaking changes ship as `v2`. A tag ruleset (`protect-release-tags`) blocks moving or deleting `v*` tags for everyone except repo admins.

Pin callers to a release's commit SHA, with the version in a comment, not to `@v1`. The workflow runs with write access to the caller's repo, often on self-hosted runners, so a moved tag would change that code without review. Bump the SHA in each caller on purpose when a new release ships.
