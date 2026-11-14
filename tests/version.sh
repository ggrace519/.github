#!/usr/bin/env bash
# Tests for the `run:` scripts of version.yml and release.yml. The scripts are cut
# out of the workflow files and run against throwaway git repositories; `gh` is
# replaced by tests/bin/gh, which turns the roll-up commit into a real local one.
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
      PREFIX=v TARGET_BRANCH=develop BASE_BRANCH=main BUMP=auto DRY_RUN=false "$@" bash "$S/version.sh" ) > "$R/log" 2>&1
  rc=$?
  out_version=$(sed -n 's/^version=//p' "$o"); out_sha=$(sed -n 's/^sha=//p' "$o"); out_rolled=$(sed -n 's/^rolled=//p' "$o")
  summary=$(cat "$s")
  git -C "$W" pull -q --ff-only origin develop 2>/dev/null
}
# release_check: release.yml's own validation (dry run) must accept the rolled changelog.
release_check() {
  ( cd "$W" && env GITHUB_OUTPUT=/dev/null GITHUB_STEP_SUMMARY=/dev/null GITHUB_REPOSITORY=o/r CHANGELOG=CHANGELOG.md \
      PREFIX=v MAJOR_TAG=false DRY_RUN=true bash "$S/release.sh" ) > "$R/rlog" 2>&1
  eq "$1: release.yml dry-run accepts it" "$?" 0
}
today=$(date -u +%F)
RELEASED='# Changelog

## [Unreleased]

## [1.1.0] - 2026-11-07

### Added
- old feature'
unrel() { printf '# Changelog\n\n## [Unreleased]\n\n%s\n\n## [1.1.0] - 2026-11-07\n\n### Added\n- old feature\n' "$1"; }

echo "patch roll"; mkrepo v1.0.0 v1.1.0
new_changelog "$(unrel $'### Fixed\n- a fix')"; before=$(git -C "$W" rev-parse HEAD)
roll; eq rc "$rc" 0; eq version "$out_version" 1.1.1; eq rolled "$out_rolled" true
eq "sha is new head" "$out_sha" "$(git -C "$REMOTE" rev-parse develop)"
if [ "$out_sha" != "$before" ]; then ok "commit made"; else no "commit made"; fi
eq "file" "$(cat "$W/CHANGELOG.md")" "# Changelog

## [Unreleased]

## [1.1.1] - $today

### Fixed
- a fix

## [1.1.0] - 2026-11-07

### Added
- old feature"
eq "commit subject" "$(git -C "$W" log -1 --format=%s)" "chore(release): roll changelog into 1.1.1"
release_check patch

echo "second run is a no-op"
roll; eq rc "$rc" 0; eq rolled "$out_rolled" false; eq version "$out_version" 1.1.1; eq "sha unchanged" "$out_sha" "$(git -C "$W" rev-parse HEAD)"

echo "re-roll folds into the pending section and raises the version"
new_changelog "$(sed 's/^## \[Unreleased\]$/## [Unreleased]\n\n### Added\n- new thing\n\n### Fixed\n- second fix/' "$W/CHANGELOG.md")"
roll; eq rc "$rc" 0; eq version "$out_version" 1.2.0; eq rolled "$out_rolled" true
eq "file" "$(cat "$W/CHANGELOG.md")" "# Changelog

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

echo "entry merged straight into the pending section re-derives the version"; mkrepo v1.1.0
new_changelog "$(unrel $'### Fixed\n- a fix')"; roll; eq version "$out_version" 1.1.1
new_changelog "$(sed 's/^- a fix$/- a fix\n\n### Added\n- sneaked in/' "$W/CHANGELOG.md")"
roll; eq version "$out_version" 1.2.0; eq rolled "$out_rolled" true; release_check sneaked

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
if grep -q '^- new$' "$W/CHANGELOG.md" && grep -q '^- by hand$' "$W/CHANGELOG.md"; then ok "both entries kept"; else no "entries"; fi
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
eq "link definition moved to the end" "$(tail -n 1 "$W/CHANGELOG.md")" "[Unreleased]: https://example.com/compare"; release_check links
RELEASED=$RELEASED_SAVE

echo "untagged section already on the base branch is released, not pending"; mkrepo
new_changelog "$(unrel $'### Fixed\n- x')"; roll; eq version "$out_version" 1.1.1
eq "1.1.0 section intact" "$(grep -c '^## \[1.1.0\] - 2026-11-07$' "$W/CHANGELOG.md")" 1
eq "old entry stays in 1.1.0" "$(sed -n '/^## \[1.1.0\]/,$p' "$W/CHANGELOG.md" | grep -c 'old feature')" 1

echo "nothing to roll"; mkrepo v1.1.0; h=$(git -C "$W" rev-parse HEAD); roll; eq rc "$rc" 0; eq rolled "$out_rolled" false; eq sha "$out_sha" "$h"; eq version "$out_version" 1.1.0
echo "empty category headings only"; mkrepo v1.1.0; new_changelog "$(unrel $'### Added\n\n### Fixed')"; roll; eq rolled "$out_rolled" false

echo "dry run"; mkrepo v1.1.0; new_changelog "$(unrel $'### Added\n- x')"; h=$(git -C "$W" rev-parse HEAD)
roll DRY_RUN=true; eq version "$out_version" 1.2.0; eq rolled "$out_rolled" false; eq "no commit" "$(git -C "$REMOTE" rev-parse develop)" "$h"
case $summary in *"Next release: v1.2.0"*"A minor bump from v1.1.0."*"- x"*) ok summary;; *) no "summary: $summary";; esac

echo "branch moved"; mkrepo v1.1.0; new_changelog "$(unrel $'### Added\n- x')"
git clone -q -b develop "$REMOTE" "$R/other"; git -C "$R/other" commit -q --allow-empty -m later; git -C "$R/other" push -q origin develop
h=$(git -C "$W" rev-parse HEAD); roll; eq rc "$rc" 0; eq rolled "$out_rolled" false; eq sha "$out_sha" "$h"
if grep -q 'moved on' "$R/log"; then ok notice; else no notice; fi

echo "refused commit"; mkrepo v1.1.0; new_changelog "$(unrel $'### Added\n- x')"; roll STUB_REFUSE=1; eq rc "$rc" 1
if grep -q '::error::Committing the roll-up' "$R/log"; then ok "error names the fix"; else no "error: $(cat "$R/log")"; fi

echo "multi-line entries and loose text"; mkrepo v1.1.0
new_changelog "$(unrel $'Intro line.\n\n### Fixed\n- one\n  continued\n\n  ```sh\n  code\n  ```\n- two')"; roll; eq version "$out_version" 1.1.1
eq "section" "$(sed -n '/^## \[1.1.1\]/,/^## \[1.1.0\]/p' "$W/CHANGELOG.md" | sed '1d;$d')" $'\nIntro line.\n\n### Fixed\n- one\n  continued\n\n  ```sh\n  code\n  ```\n- two'
release_check multiline

echo "fenced code holding headings stays one entry"; mkrepo v1.1.0
new_changelog "$(unrel $'### Fixed\n- one\n\n```md\n## [9.9.9] - 2020-01-01\n### Added\n[x]: y\n```\n- two')"; roll; eq rc "$rc" 0; eq version "$out_version" 1.1.1
eq "section" "$(sed -n '/^## \[1.1.1\]/,/^## \[1.1.0\]/p' "$W/CHANGELOG.md" | sed '1d;$d')" $'\n### Fixed\n- one\n\n```md\n## [9.9.9] - 2020-01-01\n### Added\n[x]: y\n```\n- two'
release_check fenced
( cd "$W" && env GITHUB_OUTPUT=/dev/null GITHUB_STEP_SUMMARY="$R/notes" GITHUB_REPOSITORY=o/r CHANGELOG=CHANGELOG.md PREFIX=v MAJOR_TAG=false DRY_RUN=true bash "$S/release.sh" ) > /dev/null 2>&1
if grep -q '^- two$' "$R/notes" && grep -qF '## [9.9.9]' "$R/notes"; then ok "release notes keep the whole fenced entry"; else no "release notes: $(cat "$R/notes")"; fi

echo "unbracketed version heading is refused"; mkrepo v1.1.0
new_changelog $'# Changelog\n\n## [Unreleased]\n\n### Fixed\n- x\n\n## 1.1.0 - 2026-11-07\n\n- old'; h=$(git -C "$REMOTE" rev-parse develop)
roll; eq rc "$rc" 1; eq "no commit" "$(git -C "$REMOTE" rev-parse develop)" "$h"
if grep -q '::error::.*is not a `## \[X.Y.Z\]' "$R/log"; then ok "error names the heading"; else no "error: $(cat "$R/log")"; fi

echo "CRLF changelog keeps CRLF"; mkrepo v1.1.0
printf '%s\n' "$(unrel $'### Fixed\n- x')" | sed 's/$/\r/' > "$W/CHANGELOG.md"; git -C "$W" commit -qam crlf; git -C "$W" push -q origin develop
roll; eq version "$out_version" 1.1.1
eq "every line ends in CRLF" "$(grep -vc $'\r$' "$W/CHANGELOG.md")" 0
eq "no stray blank lines" "$(tr -d '\r' < "$W/CHANGELOG.md" | sed -n '3,7p')" $'## [Unreleased]\n\n## [1.1.1] - '"$today"$'\n\n### Fixed'

echo "branch head cannot be read"; mkrepo v1.1.0; new_changelog "$(unrel $'### Added\n- x')"; roll STUB_REF_FAIL=1; eq rc "$rc" 1
if grep -q '::error::Could not read the head of develop' "$R/log"; then ok "fails loudly"; else no "error: $(cat "$R/log")"; fi

echo "ref that is not on the branch"; mkrepo v1.1.0; new_changelog "$(unrel $'### Added\n- x')"
git -C "$W" switch -qc side; git -C "$W" commit -q --allow-empty -m side
( cd "$W" && env GITHUB_OUTPUT=/dev/null GITHUB_STEP_SUMMARY=/dev/null GITHUB_REPOSITORY=o/r CHANGELOG=CHANGELOG.md PREFIX=v TARGET_BRANCH=develop BASE_BRANCH=main BUMP=auto DRY_RUN=false bash "$S/version.sh" ) > "$R/log" 2>&1
eq rc "$?" 1
if grep -q '::error::.*is not on develop' "$R/log"; then ok "error names the branch"; else no "error: $(cat "$R/log")"; fi

echo "link definitions: one blank line ahead of them"; RELEASED=$'# Changelog\n\n## [Unreleased]'; mkrepo
new_changelog $'# Changelog\n\n## [Unreleased]\n\n### Fixed\n- x\n\n[Unreleased]: https://example.com/compare'; roll
eq "tail" "$(tail -n 3 "$W/CHANGELOG.md")" $'- x\n\n[Unreleased]: https://example.com/compare'

echo "this repository's changelog"; mkrepo
while read -r v; do git -C "$W" tag "v$v"; done < <(sed -n 's/^## \[\([0-9][^]]*\)\].*/\1/p' "$ROOT/CHANGELOG.md")
git -C "$W" push -q origin --tags
new_changelog "$(cat "$ROOT/CHANGELOG.md")"; roll DRY_RUN=true; eq rc "$rc" 0
if [ -n "${WANT_VERSION:-}" ]; then eq version "$out_version" "$WANT_VERSION"; fi
echo "  next version here: ${out_version:-none}"

echo; echo "passed $pass, failed $failed"; [ "$failed" -eq 0 ]
