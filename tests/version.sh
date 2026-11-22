#!/usr/bin/env bash
# Tests for the `run:` scripts of version.yml and release.yml. The scripts are cut
# out of the workflow files and run against throwaway git repositories; `gh` is
# replaced by tests/bin/gh, which turns the roll-up commit, its branch and its pull
# request into real local state.
# Usage: bash tests/version.sh
set -uo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
S=$(mktemp -d)
trap 'rm -rf "$S"' EXIT
# Both workflows end with their `run: |` step, indented ten spaces.
for wf in version release; do
  awk 'found { sub(/^          /, ""); print } /^        run: \|$/ { found = 1 }' \
    "$ROOT/.github/workflows/$wf.yml" > "$S/$wf.sh"
  [ -s "$S/$wf.sh" ] || { echo "could not extract the run script of $wf.yml" >&2; exit 2; }
done
export PATH="$ROOT/tests/bin:$PATH" GIT_CONFIG_COUNT=3 \
  GIT_CONFIG_KEY_0=commit.gpgsign GIT_CONFIG_VALUE_0=false \
  GIT_CONFIG_KEY_1=tag.gpgsign GIT_CONFIG_VALUE_1=false \
  GIT_CONFIG_KEY_2=init.defaultBranch GIT_CONFIG_VALUE_2=main
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com
pass=0; failed=0
ok() { pass=$((pass+1)); echo "  ok   $1"; }
no() { failed=$((failed+1)); echo "  FAIL $1"; }
eq() { if [ "$2" = "$3" ]; then ok "$1"; else no "$1: want [$3] got [$2]"; fi; }

# mkrepo <tags...>: main with a released changelog ($RELEASED), tags, integration branch = main.
mkrepo() {
  R=$(mktemp -d "$S/repo.XXXX"); export REMOTE="$R/remote.git"; W="$R/work"
  git init -q --bare "$REMOTE"; git clone -q "$REMOTE" "$W" 2>/dev/null
  printf '%s\n' "$RELEASED" > "$W/CHANGELOG.md"
  git -C "$W" add -A; git -C "$W" commit -qm init
  for t in "$@"; do git -C "$W" tag "$t"; done
  git -C "$W" push -q origin main --tags; git -C "$W" switch -qc develop; git -C "$W" push -q origin develop
}
# new_changelog <text>: record a new changelog on the fixture's integration branch and push.
new_changelog() { printf '%s\n' "$1" > "$W/CHANGELOG.md"; git -C "$W" commit -qam change; git -C "$W" push -q origin develop; }
# roll [VAR=val...]: run the script on the work tree; sets $out_* from GITHUB_OUTPUT.
roll() {
  local o s; o=$(mktemp); s=$(mktemp)
  ( cd "$W" && env GITHUB_OUTPUT="$o" GITHUB_STEP_SUMMARY="$s" GITHUB_REPOSITORY=o/r CHANGELOG=CHANGELOG.md \
      PREFIX=v TARGET_BRANCH=develop BASE_BRANCH=main BUMP=auto DRY_RUN=false TOKEN_SOURCE=GITHUB_TOKEN \
      "$@" bash "$S/version.sh" ) > "$R/log" 2>&1
  rc=$?
  out_version=$(sed -n 's/^version=//p' "$o"); out_sha=$(sed -n 's/^sha=//p' "$o"); out_pr=$(sed -n 's/^pull-request=//p' "$o"); out_promote=$(sed -n 's/^promote=//p' "$o")
  summary=$(cat "$s")
  git -C "$W" fetch -q --prune origin; git -C "$W" pull -q --ff-only origin develop 2>/dev/null
}
ROLL=chore/roll-changelog
has_ref() { git -C "$REMOTE" rev-parse -q --verify "refs/heads/$1" > /dev/null; }
# cl: the changelog on the roll-up branch.
cl() { git -C "$REMOTE" show "$ROLL:CHANGELOG.md"; }
# pr <jq>: query the stub's pull requests.
pr() { if [ -f "$REMOTE/prs.json" ]; then jq -r "$1" "$REMOTE/prs.json"; else jq -nr "[] | $1"; fi; }
# merge_roll: merge the roll-up pull request into develop with a merge commit, as a person would.
merge_roll() {
  git -C "$W" merge -q --no-ff -m "Merge roll-up" "origin/$ROLL"; git -C "$W" push -q origin develop
  jq --arg h "$ROLL" 'map(if .head == $h and .state == "open" then .state = "merged" else . end)' "$REMOTE/prs.json" > "$R/prs" && mv "$R/prs" "$REMOTE/prs.json"
}
# release_check: release.yml's own validation (dry run) must accept the rolled changelog.
release_check() {
  git -C "$W" checkout -q --detach "origin/$ROLL"
  ( cd "$W" && env GITHUB_OUTPUT=/dev/null GITHUB_STEP_SUMMARY=/dev/null GITHUB_REPOSITORY=o/r CHANGELOG=CHANGELOG.md \
      PREFIX=v MAJOR_TAG=false DRY_RUN=true bash "$S/release.sh" ) > "$R/rlog" 2>&1
  eq "$1: release.yml dry-run accepts it" "$?" 0
  git -C "$W" switch -q develop
}
today=$(date -u +%F)
RELEASED='# Changelog

## [Unreleased]

## [1.1.0] - 2026-11-07

### Added
- old feature'
unrel() { printf '# Changelog\n\n## [Unreleased]\n\n%s\n\n## [1.1.0] - 2026-11-07\n\n### Added\n- old feature\n' "$1"; }

echo "patch roll opens a pull request and leaves develop alone"; mkrepo v1.0.0 v1.1.0
new_changelog "$(unrel $'### Fixed\n- a fix')"; before=$(git -C "$W" rev-parse HEAD)
roll; eq rc "$rc" 0; eq version "$out_version" 1.1.1; eq pull-request "$out_pr" 1; eq promote "$out_promote" false; eq "sha is ref" "$out_sha" "$before"
eq "develop unchanged" "$(git -C "$REMOTE" rev-parse develop)" "$before"
eq "roll-up branch is develop plus one commit" "$(git -C "$REMOTE" rev-parse "$ROLL^")" "$before"
if has_ref "$ROLL-staging"; then no "staging branch deleted"; else ok "staging branch deleted"; fi
eq "file" "$(cl)" "# Changelog

## [Unreleased]

## [1.1.1] - $today

### Fixed
- a fix

## [1.1.0] - 2026-11-07

### Added
- old feature"
eq "commit subject" "$(git -C "$REMOTE" log -1 --format=%s "$ROLL")" "chore(release): roll changelog into 1.1.1"
eq "pull request" "$(pr '.[0] | "\(.head) -> \(.base) \(.state): \(.title)"')" "$ROLL -> develop open: chore(release): roll changelog into 1.1.1"
case $(pr '.[0].body') in *"into **v1.1.1**, a patch bump from v1.1.0."*"- a fix"*) ok "body has the section";; *) no "body: $(pr '.[0].body')";; esac
release_check patch

echo "a second run before the merge updates the same pull request"
roll; eq rc "$rc" 0; eq pull-request "$out_pr" 1; eq "one pull request" "$(pr length)" 1
eq "rebuilt on develop" "$(git -C "$REMOTE" rev-parse "$ROLL^")" "$before"

echo "after the merge there is nothing to roll and the branch is retired"
merge_roll; h=$(git -C "$W" rev-parse HEAD)
roll; eq rc "$rc" 0; eq pull-request "$out_pr" ""; eq promote "$out_promote" true; eq version "$out_version" 1.1.1; eq sha "$out_sha" "$h"
if has_ref "$ROLL"; then no "roll-up branch deleted"; else ok "roll-up branch deleted"; fi
eq "merged pull request not commented" "$(pr '.[0].state + " " + (.[0].comments | length | tostring)')" "merged 0"

echo "re-roll folds into the pending section and raises the version"
new_changelog "$(sed 's/^## \[Unreleased\]$/## [Unreleased]\n\n### Added\n- new thing\n\n### Fixed\n- second fix/' "$W/CHANGELOG.md")"
roll; eq rc "$rc" 0; eq version "$out_version" 1.2.0; eq pull-request "$out_pr" 2
eq "file" "$(cl)" "# Changelog

## [Unreleased]

## [1.2.0] - $today

### Fixed
- a fix
- second fix

### Added
- new thing

## [1.1.0] - 2026-11-07

### Added
- old feature"
release_check re-roll

echo "develop moving under an open roll-up rebuilds it and retitles the pull request"; mkrepo v1.1.0
new_changelog "$(unrel $'### Fixed\n- a fix')"; roll; eq pull-request "$out_pr" 1
new_changelog "$(unrel $'### Added\n- more\n\n### Fixed\n- a fix')"; h=$(git -C "$W" rev-parse HEAD)
roll; eq rc "$rc" 0; eq version "$out_version" 1.2.0; eq pull-request "$out_pr" 1; eq "one pull request" "$(pr length)" 1
eq "rebuilt on the new head" "$(git -C "$REMOTE" rev-parse "$ROLL^")" "$h"
eq title "$(pr '.[0].title')" "chore(release): roll changelog into 1.2.0"
release_check moved-under

echo "a roll made by hand retires the open roll-up"; mkrepo v1.1.0
new_changelog "$(unrel $'### Fixed\n- a fix')"; roll; eq pull-request "$out_pr" 1
new_changelog "$(cl)"; roll; eq rc "$rc" 0; eq pull-request "$out_pr" ""
eq "closed with a comment" "$(pr '.[0].state + " " + (.[0].comments | length | tostring)')" "closed 1"
if has_ref "$ROLL"; then no "roll-up branch deleted"; else ok "roll-up branch deleted"; fi

echo "a staging branch left by a cancelled run is cleaned up"; mkrepo v1.1.0
git -C "$REMOTE" update-ref "refs/heads/$ROLL-staging" "$(git -C "$REMOTE" rev-parse develop)"
roll; eq rc "$rc" 0; eq promote "$out_promote" false
if has_ref "$ROLL-staging"; then no "staging deleted"; else ok "staging deleted"; fi

echo "a branch that cannot be read is not taken for a missing one"; mkrepo v1.1.0
new_changelog "$(unrel $'### Fixed\n- a fix')"; roll; merge_roll; roll STUB_REF_502="$ROLL"; eq rc "$rc" 1
if grep -q "::error::Could not read the branch $ROLL" "$R/log"; then ok "fails loudly"; else no "error: $(cat "$R/log")"; fi
if has_ref "$ROLL"; then ok "branch kept"; else no "branch kept"; fi

echo "develop moving during the run leaves the pull request alone"; mkrepo v1.1.0
new_changelog "$(unrel $'### Fixed\n- a fix')"; roll STUB_MOVE=1; eq rc "$rc" 0; eq pull-request "$out_pr" ""; eq promote "$out_promote" false
if has_ref "$ROLL" || has_ref "$ROLL-staging" || [ "$(pr length)" != 0 ]; then no "nothing written"; else ok "nothing written"; fi

echo "a pull request opened by another run in the meantime is adopted"; mkrepo v1.1.0
new_changelog "$(unrel $'### Fixed\n- a fix')"; roll STUB_PR_RACE=1; eq rc "$rc" 0; eq pull-request "$out_pr" 1; eq "one pull request" "$(pr length)" 1

echo "entry merged straight into the pending section re-derives the version"; mkrepo v1.1.0
new_changelog "$(unrel $'### Fixed\n- a fix')"; roll; eq version "$out_version" 1.1.1; merge_roll
new_changelog "$(sed 's/^- a fix$/- a fix\n\n### Added\n- sneaked in/' "$W/CHANGELOG.md")"
roll; eq version "$out_version" 1.2.0; eq pull-request "$out_pr" 2; release_check sneaked

echo "levels"
for c in '### Changed|- x|1.1.1' '### Added|- x|1.2.0' '### Breaking|- x|2.0.0' '### Changed|- BREAKING: x|2.0.0' '### Changed|- **BREAKING** x|2.0.0' '### Changed|- x, see BREAKING notes|1.1.1' '### Added||1.1.1'; do
  IFS='|' read -r h e want <<<"$c"
  [ -n "$e" ] || e=$'\n### Docs\n- x'
  mkrepo v1.1.0; new_changelog "$(unrel "$h"$'\n'"$e")"; roll; eq "$h / ${e//$'\n'/ }" "$out_version" "$want"; release_check "$h"
done
echo "bump override"; mkrepo v1.1.0; new_changelog "$(unrel $'### Fixed\n- x')"; roll BUMP=major; eq "major forced" "$out_version" 2.0.0
mkrepo v1.1.0; new_changelog "$(unrel $'### Fixed\n- x')"; roll BUMP=bogus; eq "bad bump fails" "$rc" 1

echo "never lower: hand-edited pending heading stands"; mkrepo v1.1.0
new_changelog "$(unrel $'### Fixed\n- new')"; new_changelog "$(sed 's/^## \[1.1.0\].*/## [3.0.0] - 2026-01-01\n\n### Changed\n- by hand\n\n&/' "$W/CHANGELOG.md")"
roll; eq version "$out_version" 3.0.0
if cl | grep -q '^- new$' && cl | grep -q '^- by hand$'; then ok "both entries kept"; else no "entries"; fi
release_check never-lower

echo "hand-made pre-release heading is kept"; mkrepo v1.1.0
new_changelog "$(unrel $'### Added\n- new')"; new_changelog "$(sed 's/^## \[1.1.0\].*/## [2.0.0-rc.1] - 2026-01-01\n\n### Changed\n- rc\n\n&/' "$W/CHANGELOG.md")"
roll; eq version "$out_version" 2.0.0-rc.1; release_check prerelease

echo "tagged pre-release is a floor"; mkrepo v1.1.0 v2.0.0-rc.1
new_changelog "$(unrel $'### Fixed\n- x')"; roll; eq version "$out_version" 2.0.0; release_check floor

echo "0.x demotes major; no tags"; RELEASED_SAVE=$RELEASED
RELEASED=$'# Changelog\n\n## [Unreleased]'; mkrepo
new_changelog $'# Changelog\n\n## [Unreleased]\n\n### Breaking\n- x'; roll; eq "no tags, breaking" "$out_version" 0.1.0; release_check notags
mkrepo; new_changelog $'# Changelog\n\n## [Unreleased]\n\n### Fixed\n- x\n\n[Unreleased]: https://example.com/compare'; roll; eq "no tags, fix" "$out_version" 0.0.1
eq "link definition moved to the end" "$(cl | tail -n 1)" "[Unreleased]: https://example.com/compare"; release_check links
RELEASED=$RELEASED_SAVE

echo "untagged section already on the base branch is released, not pending"; mkrepo
new_changelog "$(unrel $'### Fixed\n- x')"; roll; eq version "$out_version" 1.1.1
eq "1.1.0 section intact" "$(cl | grep -c '^## \[1.1.0\] - 2026-11-07$')" 1
eq "old entry stays in 1.1.0" "$(cl | sed -n '/^## \[1.1.0\]/,$p' | grep -c 'old feature')" 1

echo "nothing to roll and the top version released: no promotion"; mkrepo v1.1.0; h=$(git -C "$W" rev-parse HEAD); roll; eq rc "$rc" 0; eq pull-request "$out_pr" ""; eq promote "$out_promote" false; eq sha "$out_sha" "$h"; eq version "$out_version" 1.1.0
roll DRY_RUN=true; eq "dry run never promotes" "$out_promote" false
if has_ref "$ROLL"; then no "no roll-up branch"; else ok "no roll-up branch"; fi
echo "a change with no changelog entry after a release is not promoted"; mkrepo v1.1.0
echo docs > "$W/NOTES.md"; git -C "$W" add NOTES.md; git -C "$W" commit -qm docs; git -C "$W" push -q origin develop
roll; eq rc "$rc" 0; eq promote "$out_promote" false; eq pull-request "$out_pr" ""
if grep -q '::notice::develop has no changelog entries after v1.1.0, so there is nothing to promote' "$R/log"; then ok notice; else no "notice: $(cat "$R/log")"; fi
echo "empty category headings only"; mkrepo v1.1.0; new_changelog "$(unrel $'### Added\n\n### Fixed')"; roll; eq pull-request "$out_pr" ""

echo "dry run"; mkrepo v1.1.0; new_changelog "$(unrel $'### Added\n- x')"; h=$(git -C "$W" rev-parse HEAD)
roll DRY_RUN=true; eq version "$out_version" 1.2.0; eq pull-request "$out_pr" ""; eq "no commit" "$(git -C "$REMOTE" rev-parse develop)" "$h"
if has_ref "$ROLL" || has_ref "$ROLL-staging" || [ "$(pr length)" != 0 ]; then no "no branch, no pull request"; else ok "no branch, no pull request"; fi
case $summary in *"Next release: v1.2.0"*"A minor bump from v1.1.0."*"- x"*) ok summary;; *) no "summary: $summary";; esac

echo "branch moved"; mkrepo v1.1.0; new_changelog "$(unrel $'### Added\n- x')"
git clone -q -b develop "$REMOTE" "$R/other"; git -C "$R/other" commit -q --allow-empty -m later; git -C "$R/other" push -q origin develop
h=$(git -C "$W" rev-parse HEAD); roll; eq rc "$rc" 0; eq pull-request "$out_pr" ""; eq "superseded run does not promote" "$out_promote" false; eq sha "$out_sha" "$h"
if grep -q 'moved on' "$R/log"; then ok notice; else no notice; fi
echo "superseded run with nothing to roll does not promote either"; mkrepo v1.1.0
git clone -q -b develop "$REMOTE" "$R/other"; git -C "$R/other" commit -q --allow-empty -m later; git -C "$R/other" push -q origin develop
roll; eq rc "$rc" 0; eq promote "$out_promote" false
if has_ref "$ROLL"; then no "no roll-up branch"; else ok "no roll-up branch"; fi

echo "refused commit"; mkrepo v1.1.0; new_changelog "$(unrel $'### Added\n- x')"; roll STUB_REFUSE=1; eq rc "$rc" 1
if grep -q '::error::Committing the roll-up' "$R/log"; then ok "error names the fix"; else no "error: $(cat "$R/log")"; fi
if has_ref "$ROLL-staging" || has_ref "$ROLL" || [ "$(pr length)" != 0 ]; then no "nothing left behind"; else ok "nothing left behind"; fi

echo "multi-line entries and loose text"; mkrepo v1.1.0
new_changelog "$(unrel $'Intro line.\n\n### Fixed\n- one\n  continued\n\n  ```sh\n  code\n  ```\n- two')"; roll; eq version "$out_version" 1.1.1
eq "section" "$(cl | sed -n '/^## \[1.1.1\]/,/^## \[1.1.0\]/p' | sed '1d;$d')" $'\nIntro line.\n\n### Fixed\n- one\n  continued\n\n  ```sh\n  code\n  ```\n- two'
release_check multiline

echo "fenced code holding headings stays one entry"; mkrepo v1.1.0
new_changelog "$(unrel $'### Fixed\n- one\n\n```md\n## [9.9.9] - 2020-01-01\n### Added\n[x]: y\n```\n- two')"; roll; eq rc "$rc" 0; eq version "$out_version" 1.1.1
eq "section" "$(cl | sed -n '/^## \[1.1.1\]/,/^## \[1.1.0\]/p' | sed '1d;$d')" $'\n### Fixed\n- one\n\n```md\n## [9.9.9] - 2020-01-01\n### Added\n[x]: y\n```\n- two'
release_check fenced
git -C "$W" checkout -q --detach "origin/$ROLL"
( cd "$W" && env GITHUB_OUTPUT=/dev/null GITHUB_STEP_SUMMARY="$R/notes" GITHUB_REPOSITORY=o/r CHANGELOG=CHANGELOG.md PREFIX=v MAJOR_TAG=false DRY_RUN=true bash "$S/release.sh" ) > /dev/null 2>&1
git -C "$W" switch -q develop
if grep -q '^- two$' "$R/notes" && grep -qF '## [9.9.9]' "$R/notes"; then ok "release notes keep the whole fenced entry"; else no "release notes: $(cat "$R/notes")"; fi

echo "unbracketed version heading is refused"; mkrepo v1.1.0
new_changelog $'# Changelog\n\n## [Unreleased]\n\n### Fixed\n- x\n\n## 1.1.0 - 2026-11-07\n\n- old'; h=$(git -C "$REMOTE" rev-parse develop)
roll; eq rc "$rc" 1; eq "no commit" "$(git -C "$REMOTE" rev-parse develop)" "$h"
if has_ref "$ROLL"; then no "no roll-up branch"; else ok "no roll-up branch"; fi
if grep -q '::error::.*is not a `## \[X.Y.Z\]' "$R/log"; then ok "error names the heading"; else no "error: $(cat "$R/log")"; fi

echo "CRLF changelog keeps CRLF"; mkrepo v1.1.0
printf '%s\n' "$(unrel $'### Fixed\n- x')" | sed 's/$/\r/' > "$W/CHANGELOG.md"; git -C "$W" commit -qam crlf; git -C "$W" push -q origin develop
roll; eq version "$out_version" 1.1.1
eq "every line ends in CRLF" "$(cl | grep -vc $'\r$')" 0
eq "no stray blank lines" "$(cl | tr -d '\r' | sed -n '3,7p')" $'## [Unreleased]\n\n## [1.1.1] - '"$today"$'\n\n### Fixed'

echo "branch head cannot be read"; mkrepo v1.1.0; new_changelog "$(unrel $'### Added\n- x')"; roll STUB_REF_FAIL=1; eq rc "$rc" 1
if grep -q '::error::Could not read the head of develop' "$R/log"; then ok "fails loudly"; else no "error: $(cat "$R/log")"; fi

echo "ref that is not on the branch"; mkrepo v1.1.0; new_changelog "$(unrel $'### Added\n- x')"
git -C "$W" switch -qc side; git -C "$W" commit -q --allow-empty -m side
( cd "$W" && env GITHUB_OUTPUT=/dev/null GITHUB_STEP_SUMMARY=/dev/null GITHUB_REPOSITORY=o/r CHANGELOG=CHANGELOG.md PREFIX=v TARGET_BRANCH=develop BASE_BRANCH=main BUMP=auto DRY_RUN=false TOKEN_SOURCE=GITHUB_TOKEN bash "$S/version.sh" ) > "$R/log" 2>&1
eq rc "$?" 1
if grep -q '::error::.*is not on develop' "$R/log"; then ok "error names the branch"; else no "error: $(cat "$R/log")"; fi

echo "link definitions: one blank line ahead of them"; RELEASED=$'# Changelog\n\n## [Unreleased]'; mkrepo
new_changelog $'# Changelog\n\n## [Unreleased]\n\n### Fixed\n- x\n\n[Unreleased]: https://example.com/compare'; roll
eq "tail" "$(cl | tail -n 3)" $'- x\n\n[Unreleased]: https://example.com/compare'

echo "this repository's changelog"; mkrepo
while read -r v; do git -C "$W" tag "v$v"; done < <(sed -n 's/^## \[\([0-9][^]]*\)\].*/\1/p' "$ROOT/CHANGELOG.md")
git -C "$W" push -q origin --tags
new_changelog "$(cat "$ROOT/CHANGELOG.md")"; roll DRY_RUN=true; eq rc "$rc" 0
if [ -n "${WANT_VERSION:-}" ]; then eq version "$out_version" "$WANT_VERSION"; fi
echo "  next version here: ${out_version:-none}"

echo; echo "passed $pass, failed $failed"; [ "$failed" -eq 0 ]
