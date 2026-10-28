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
concurrency:
  group: promote-develop-to-main
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
```

Requirements:
- The default branch must be `develop`. `workflow_run` only fires for workflows on the default branch.
- Turn on Settings → Actions → "Allow GitHub Actions to create and approve pull requests":
  `gh api -X PUT repos/OWNER/REPO/actions/permissions/workflow -f default_workflow_permissions=read -F can_approve_pull_request_reviews=true`
- CI does run on the promotion pull request. Because this workflow starts from a `workflow_run` chain, GitHub credits the `pull_request` runs to the user whose push began the chain, not to `GITHUB_TOKEN`. tetris-c #14 showed this, with `triggering_actor` set to the pushing user. Required status checks on `main` therefore report as usual.

Merge promotion pull requests with a merge commit, never a squash or rebase.

## Versioning

Releases are tagged `vX.Y.Z` on main, and `v1` is moved to the latest 1.x release. Breaking changes ship as `v2`. A tag ruleset (`protect-release-tags`) blocks moving or deleting `v*` tags for everyone except repo admins.

Pin callers to a release's commit SHA, with the version in a comment, not to `@v1`. The workflow runs with write access to the caller's repo, often on self-hosted runners, so a moved tag would change that code without review. Bump the SHA in each caller on purpose when a new release ships.
