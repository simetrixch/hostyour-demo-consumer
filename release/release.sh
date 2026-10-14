#!/usr/bin/env bash
# ===========================================================================
# release.sh — put a release of this repo on ONE stage, or release a library,
# which deploys nothing. Lives in release/; copied here by the platform.
#
# USAGE (run from the repo root)
#   ./release/release.sh <x.y.z> <stable|beta|alpha> <dev|test|prod> [--existing] [--from <commit>]
#   ./release/release.sh <x.y.z> <stable|beta|alpha>     (a library)
#
# --existing puts a release that already stands on origin on the stage and
# mints nothing: the deploy ref is pushed at that release's own commit,
# whatever is checked out. It is how a unit goes back to an earlier release
# (hostyour-manager#299).
#
# --from mints the release on the commit it names instead of on HEAD: the
# version is stamped on top of that commit, the tag and the deploy ref are
# pushed, and no branch moves. It is how a release that stands on one channel
# reaches a stage of another with the same code. It leaves HEAD detached at the
# release commit, and it refuses to mint a version and channel that already
# have a tag.
#
# THE THREE INPUTS
#   version  — x.y.z; the third position is written with three digits,
#              leading zeros included (0.3.000, 0.3.001).
#   channel  — the maturity CEILING of the release: alpha may reach dev only,
#              beta dev and test, stable anywhere. The channel is part of the
#              release tag; the stage is NOT.
#   stage    — WHERE this run puts the release. One release, one image, any
#              number of stages. A library takes none; `none` says so where a
#              value has to be given, as in the Release workflow's form.
#
# WHAT IT DOES
#   1. Validates version, channel and stage.
#   2. Refuses a dirty worktree (a release must be a clean, pushed commit).
#   3. Reads deploy/platform.yaml: the unit `name` and the build names.
#   4. MINT-ONCE: exactly one release tag per (version, channel). The first run
#      stamps the version into package.json where the repo has one, mints
#      <x.y.z>-<channel>-<ts14> (ts14 = UTC yyyyMMddHHmmss) on HEAD and pushes
#      the commit + the tag (under --from, on the commit it names, the tag
#      alone). A later run for the SAME version+channel REUSES
#      that tag — that is how a release reaches a further stage without being
#      rebuilt: the same commit, the same image, one more stage. A VERSION
#      NAMES ONE COMMIT: a rerun whose tag stands on origin on a commit other
#      than HEAD is refused before any push, and the refusal names the next
#      number to mint (#173).
#   5. Deletes and re-pushes the deploy ref refs/tags/deploy/<stage>/<tag>.
#      The delivery branch deploy/<stage> - the branch the unit's Application
#      renders its chart off - is NOT moved here: the platform places it on the
#      release commit plus its pins once every image exists (hostyour-manager#293).
#      Pushing that ref is the ONLY build trigger. It is deleted first because
#      pushing a ref that already stands changes nothing and fires no webhook,
#      so a repeat of the same (release, stage) would do nothing at all. The
#      deletion itself fires a webhook too; the platform's trigger drops it.
#   6. Where the repository supplies deploy/after-release.sh: runs it last,
#      with the tag, the release commit and the stage (`none` for a library),
#      from the repository root. A failure turns the
#      release red; the release itself stands.
#
# THE TWO SHAPES THIS ONE SCRIPT SERVES, and what tells them apart
#   A UNIT, a manifest with builds, a chart or a tenant: block, is built and
#   pinned by the platform's build plane, which the deploy ref above reaches.
#   This script waits for no build and writes no pin: it needs no network
#   beyond its own origin.
#   A LIBRARY is a manifest with no builds, no chart and no tenant: block, the
#   one shape the release pipeline refuses as deploying nothing. No build plane
#   reads a deploy ref of it, so it takes no stage and step 5 does not run: the
#   tag is the release, and the build plane publishes its packages from it.
#
# The stage is never in the release tag — the same image reaches further stages
# by the deploy ref alone. The ceiling below is checked LOCALLY as a courtesy so
# a mistake is visible here, but it does NOT stop the push: the pipeline is the
# only thing that can write, and its refusal — naming channel, stage and the
# allowed stages — is the one that counts. Every property here is re-verified
# there; a hand-forged ref is handled identically.
# ===========================================================================
set -euo pipefail

# WHAT THIS SCRIPT PRINTS, AND WHO WRITES THE NEWLINE. Every line it composes is ASCII, a path it names
# is printed as UTF-8, and every line ends with the one \n written here, because neither is the
# host's to choose. Comments carry whatever characters they like; only what is PRINTED is bound.
line() { printf '%s\n' "$*"; }
say() { line "release: $*"; }
warn() { line "release: $*" >&2; }
die() { warn "$*"; exit 1; }

# THE COMMIT A TAG SITS ON DECLARES THE VERSION THE TAG NAMES. The build reads the version out of
# the tag, so a package.json still declaring an older number labels the artifact with a version
# nobody released. The write happens BEFORE the tag is created: a tag placed first would point at
# the commit that still carries the old number, and a release does not move a tag afterwards.
# EVERY package.json the repository tracks is stamped, in the one commit: a workspace publishes its
# packages at the numbers they declare, and a package left at an older number is skipped by a publish
# that finds that number already published.
# Only the FIRST "version" line of a file is touched. That is the manifest's own; a version further
# down belongs to a dependency and is not this release's to move. perl rewrites it, because it keeps
# the file's line endings and byte order mark as they are and runs the same on BSD and GNU systems,
# where `sed -i` differs. Paths come unquoted, so a name with a non-ASCII byte is the file itself.
# A repository with no package.json, or a file that declares no version, has nothing that could go
# stale — that is said out loud and the release continues, because a unit written in another
# language is the ordinary case here and not a broken one.
# EVERY package.json carries the version in the package manager's strict form: npm refuses to
# publish a version with a leading zero, and pnpm matches no workspace:* dependency to a package
# that declares one (pnpm deploy fails on it), so 0.3.000 is written 0.3.0 and 0.3.001 is written
# 0.3.1. The tag and the images keep the release version as it is.
# A beta or an alpha carries its channel as the prerelease part, 0.3.1-beta: mint-once allows one
# release per version AND channel, so a beta and a stable of one version are two commits, and a
# registry that holds 0.3.1 for the first would skip the second as published. A caret range never
# matches a prerelease, so a consumer on ^0.3.0 is not moved onto a beta.
stamp_manifest_version() {
  PACKAGE_VERSION="${VERSION%.*}.$((10#${VERSION##*.}))"
  [ "$CHANNEL" = "stable" ] || PACKAGE_VERSION="${PACKAGE_VERSION}-${CHANNEL}"
  manifests=$(git -c core.quotePath=false -C "$ROOT" ls-files -- 'package.json' '*/package.json')
  if [ -z "$manifests" ]; then
    say "this repository carries no package.json - no version manifest to stamp"
    return 0
  fi
  stamped=""
  versioned=""
  while IFS= read -r rel; do
    file="$ROOT/$rel"
    if ! grep -qE '^[[:space:]]*"version":[[:space:]]*"' "$file"; then
      say "$rel declares no version - nothing to stamp"
      continue
    fi
    versioned="$versioned$rel
"
    declared="$PACKAGE_VERSION"
    DECLARED="$declared" perl -0pi -e 's/^([ \t]*)"version":[ \t]*"[^"]*"/$1"version": "$ENV{DECLARED}"/m' "$file"
    git diff --quiet -- "$file" && continue
    # --force: the file is tracked (ls-files listed it), and git refuses to add a tracked file that
    # stands in a directory a .gitignore names, as packages/storage/ under a `storage/` rule.
    git add --force -- "$file" || die "the version bump to $VERSION could not be staged"
    stamped="$stamped$declared $rel
"
  done <<EOF
$manifests
EOF
  stamp_lockfile_version
  [ -z "$stamped$locked" ] && return 0
  git commit --quiet -m "release: $TAG" || die "the version bump to $VERSION could not be committed"
  printf '%s' "$stamped" | while IFS=' ' read -r declared rel; do say "$rel declares ${declared}"; done
  printf '%s' "$locked" | while IFS= read -r lock; do say "$lock declares ${PACKAGE_VERSION}"; done
}

# AN NPM LOCKFILE REPEATS EVERY VERSION THE STAMP WROTE: the "version" of its top-level object and
# of packages[""] repeat the package.json beside it, and packages["<dir>"] a workspace member's below
# it. They move in the release commit, or the next `npm install` carries the difference into an
# unrelated change. Each pattern stays inside the one object it names ([^{}] crosses no nested
# object), so a version of an installed package is never touched; an entry npm did not write is left
# as it is. Every package.json that declares a version counts, a changed one or not, so a lockfile
# an earlier install left behind is set right too. pnpm-lock.yaml records no package's own version.
stamp_lockfile_version() {
  locked=""
  [ -n "$versioned" ] || return 0
  locks=$(git -c core.quotePath=false -C "$ROOT" ls-files -- 'package-lock.json' '*/package-lock.json')
  [ -n "$locks" ] || return 0
  while IFS= read -r lock; do
    dir="${lock%package-lock.json}"
    file="$ROOT/$lock"
    printf '%s' "$versioned" | while IFS= read -r rel; do
      at="${rel%package.json}"
      if [ "$at" = "$dir" ]; then
        DECLARED="$PACKAGE_VERSION" perl -0pi -e 's/\A((?:\xEF\xBB\xBF)?\{[^{}]*?"version":\s*)"[^"]*"/$1"$ENV{DECLARED}"/; s/("packages":\s*\{\s*"":\s*\{[^{}]*?"version":\s*)"[^"]*"/$1"$ENV{DECLARED}"/' "$file"
        continue
      fi
      case "$at" in
        "$dir"?*)
          member="${at#"$dir"}"
          DECLARED="$PACKAGE_VERSION" MEMBER="${member%/}" perl -0pi -e 's/("\Q$ENV{MEMBER}\E":\s*\{[^{}]*?"version":\s*)"[^"]*"/$1"$ENV{DECLARED}"/' "$file"
          ;;
      esac
    done
    git diff --quiet -- "$file" && continue
    git add --force -- "$file" || die "the version bump to $VERSION could not be staged"
    locked="$locked$lock
"
  done <<EOF
$locks
EOF
}

USAGE="usage: release/release.sh <x.y.z> <stable|beta|alpha> [<dev|test|prod>] [--existing] [--from <commit>]"
VERSION="${1:-}"
CHANNEL="${2:-}"
STAGE=""
EXISTING_ONLY=""
FROM=""
# --existing stands before or after the stage, and a release without a stage has nothing to put
# before it. Guarded by the count because bash 3.2 calls an empty "$@"
# unbound under set -u.
if [ $# -gt 2 ]; then
  STAGE_GIVEN=""
  FROM_NEXT=""
  for arg in "${@:3}"; do
    if [ -n "$FROM_NEXT" ]; then FROM="$arg"; FROM_NEXT=""; continue; fi
    case "$arg" in
      --existing) EXISTING_ONLY=yes ;;
      --from) FROM_NEXT=yes ;;
      *) [ -z "$STAGE_GIVEN" ] || die "$USAGE"; STAGE="$arg"; STAGE_GIVEN=yes ;;
    esac
  done
  [ -z "$FROM_NEXT" ] || die "$USAGE"
fi
# `none` is how a form that must send a value says "no stage" (the Release workflow's choice input).
[ "$STAGE" = "none" ] && STAGE=""

[ -n "$VERSION" ] && [ -n "$CHANNEL" ] || die "$USAGE"
[[ "$VERSION" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.[0-9]{3}$ ]] \
  || die "version must be x.y.z, the third position three digits such as 000 (got '$VERSION')"
case "$CHANNEL" in stable|beta|alpha) ;; *) die "channel must be stable|beta|alpha (got '$CHANNEL')" ;; esac
case "$STAGE" in ""|dev|test|prod) ;; *) die "stage must be dev|test|prod, or none for a library (got '$STAGE')" ;; esac

# The courtesy ceiling check. It WARNS and continues on purpose — see the header. A release without
# a stage reaches none, so there is no ceiling to hold it against.
if [ -n "$STAGE" ]; then
  case "$CHANNEL" in
    alpha) ADMITS="dev" ;;
    beta) ADMITS="dev test" ;;
    stable) ADMITS="dev test prod" ;;
  esac
  case " $ADMITS " in
    *" $STAGE "*) ;;
    *) warn "WARNING - channel ${CHANNEL} admits only: ${ADMITS}. Stage ${STAGE} is above its ceiling, so the platform will refuse this run. Pushing anyway; the refusal comes from the pipeline." ;;
  esac
fi

git rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "not inside a git repository"
[ -z "$(git status --porcelain)" ] || die "worktree is dirty - commit or stash before releasing"

# --from NAMES THE COMMIT THE RELEASE IS MINTED ON, resolved now: the mint moves HEAD off it.
[ -z "$FROM" ] || [ -z "$EXISTING_ONLY" ] || die "--from mints a new release on the commit it names and --existing mints none - give one of them. Nothing was pushed."
FROM_SHA=""
if [ -n "$FROM" ]; then
  FROM_SHA="$(git rev-parse --verify --quiet "${FROM}^{commit}")" || die "--from ${FROM} names no commit of this repository. Nothing was pushed."
fi

# Anchor the manifest read at the repo root so it resolves whether the script is run from the
# repo root or from inside release/ (git tag/push are already repo-relative, not cwd-relative).
ROOT="$(git rev-parse --show-toplevel 2>/dev/null || echo .)"
MANIFEST="$ROOT/deploy/platform.yaml"

# Read with sed and not grep: `sed -n ... p` answers nothing and exits 0 where a key is absent, so
# a missing name stays a plain empty value under `set -o pipefail`, and the refusal below names it
# instead of a failed pipeline. The capture stops at the first space, which is also what drops a
# trailing YAML comment.
manifest_value() { sed -nE "s/^$1:[[:space:]]*([^[:space:]]+).*\$/\\1/p" "$MANIFEST" 2>/dev/null | head -1; }
NAME="$(manifest_value name || true)"
[ -n "$NAME" ] || die "the manifest ${MANIFEST} states no name - it is what the release line is written under"
# Is the top-level key $1 declared at all? A chart or a tenant block is a map, so its value stands on
# the lines below the key and manifest_value reads nothing for it.
manifest_has() { [ -n "$(sed -nE "/^$1:/p" "$MANIFEST" 2>/dev/null | head -1)" ]; }
# The build names of the top-level `builds:` block and of nothing else: a tenant block lists its
# members with `- name:` lines too, and those are no images. Read in block style, as every manifest
# writes the list.
BUILDS="$(awk '/^[^[:space:]#]/ { inside = ($0 ~ /^builds:/) } inside && /^[[:space:]]*-[[:space:]]*name:/ { sub(/^[[:space:]]*-[[:space:]]*name:[[:space:]]*/, ""); sub(/[[:space:]].*$/, ""); print }' "$MANIFEST" 2>/dev/null || true)"

# A LIBRARY DEPLOYS NOTHING, so it takes no stage, and everything else is put on one. The test is the
# release pipeline's own: a manifest with no builds, no chart and no tenant block deploys nothing.
# Both mismatches are refused here, before anything is minted or pushed.
LIBRARY=""
if [ -z "$BUILDS" ] && ! manifest_has chart && ! manifest_has tenant; then LIBRARY=yes; fi
if [ -n "$LIBRARY" ]; then
  [ -z "$STAGE" ] || die "${NAME} declares no builds, no chart and no tenant block, so a release of it deploys nothing and takes no stage - release it without one. Nothing was pushed."
  [ -z "$EXISTING_ONLY" ] || die "--existing puts a release that stands on origin on a stage again, and ${NAME} deploys nothing. Nothing was pushed."
else
  [ -n "$STAGE" ] || die "${NAME} declares builds, a chart or a tenant block, so a release of it is put on a stage - name dev, test or prod. Nothing was pushed."
fi

# THE REPOSITORY'S OWN STEP AFTER THE RELEASE. A repository that needs one more act after every release
# supplies deploy/after-release.sh. It stands outside release/, which a kit replace rewrites whole, so
# the replace never takes it away. The step runs last, with the tag, the release commit and the stage
# (`none` for a library), from the repository root. A failure turns the release red, and the release
# itself stands.
AFTER_RELEASE=""
if [ -f "${ROOT}/deploy/after-release.sh" ]; then
  AFTER_RELEASE="deploy/after-release.sh"
fi
after_release() {
  [ -n "$AFTER_RELEASE" ] || return 0
  say "running deploy/after-release ${TAG} ${SHA} ${STAGE:-none}"
  local status=0 released="is released"
  (cd "$ROOT" && bash "$AFTER_RELEASE" "$TAG" "$SHA" "${STAGE:-none}") || status=$?
  [ -n "$LIBRARY" ] || released="is released and its deploy ref is pushed"
  [ "$status" = "0" ] \
    || die "deploy/after-release failed with exit ${status} - ${TAG} ${released}; only the after-release step is missing: run it again once fixed"
}

# Remote view first: mint-once has to see the tags other people pushed, or a second machine would
# mint a second tag for the same version+channel instead of reusing the one that exists.
git fetch --tags --quiet origin 2>/dev/null || true

PREFIX="${VERSION}-${CHANNEL}-"
EXISTING="$(git tag -l "${PREFIX}*" | sort | tail -1)"
HEAD_SHA="$(git rev-parse --verify HEAD)"

# THE RELEASE COMMIT GOES WHERE THE BRANCH TRACKS. A bare `git push origin HEAD` pushes to the remote
# branch of the local branch's own name, so a branch that tracks origin/master under another name, as
# an issue worktree's does, would put the release commit on a new branch and never on master. A branch
# that tracks nothing on origin keeps its own name.
UPSTREAM="$(git rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>/dev/null || true)"
case "$UPSTREAM" in
  origin/*) RELEASE_PUSH="HEAD:refs/heads/${UPSTREAM#origin/}" ;;
  *) RELEASE_PUSH="HEAD" ;;
esac

# A TAG THAT NEVER REACHED ORIGIN AND NAMES ANOTHER COMMIT IS RESIDUE, and reusing it aims every
# retry at the commit a refused push left behind. The tag is minted before it is pushed, so a push
# the pre-push hook refuses leaves it standing here and nowhere else; the next run finds it, reuses
# it, and is refused again — for the same reason, printed as if it were about the new attempt.
#
# A TAG THAT IS ON ORIGIN IS LEFT EXACTLY AS IT STANDS, whatever commit it names. That is mint-once
# itself, and the reuse below relies on it: one release per version+channel, put on a further stage
# without rebuilding.
if [ -n "$EXISTING" ] \
  && ! git ls-remote --exit-code --tags origin "refs/tags/${EXISTING}" >/dev/null 2>&1 \
  && [ "$(git rev-parse --verify --quiet "${EXISTING}^{commit}")" != "$HEAD_SHA" ]; then
  say "${EXISTING} stands on this machine only and names $(git rev-parse --short=7 "${EXISTING}^{commit}"), not the commit being released. A run whose push was refused left it behind; it is dropped and cut again."
  git tag -d "$EXISTING" >/dev/null \
    || die "the leftover tag ${EXISTING} could not be dropped, and reusing it would release a commit nobody is releasing"
  EXISTING=""
fi

# --existing PUTS ONLY WHAT WAS RELEASED: the release has to stand on origin, because the deploy ref is
# pushed at its commit and a tag that never left this machine is no release anybody built.
if [ -n "$EXISTING_ONLY" ] \
  && { [ -z "$EXISTING" ] || ! git ls-remote --exit-code --tags origin "refs/tags/${EXISTING}" >/dev/null 2>&1; }; then
  die "no release ${VERSION}-${CHANNEL} stands on origin, so there is none to put on ${STAGE}. Nothing was pushed."
fi

# A MINT UNDER --from NEEDS A VERSION AND CHANNEL NOBODY HAS TAGGED: a tag that stands already is the
# release, and it names the commit it names.
if [ -n "$FROM_SHA" ] && [ -n "$EXISTING" ]; then
  die "${EXISTING} exists, so ${VERSION}-${CHANNEL} cannot be minted again on ${FROM}: a version names one commit. Nothing was pushed."
fi

# A VERSION NAMES ONE COMMIT. A tag that survived the residue rule and names a commit other than
# HEAD is on origin, and origin's tag is the release: what stands at HEAD is a different tree, and
# the version cannot name both. Reusing the tag would push its commit as the deploy ref from a
# checkout standing elsewhere - a push the organisation's pre-push hook refuses as "not what is
# checked out", after the tag was reused and in words about the deploy ref. So the refusal is
# here, before any push, and it names the next number: a commit that failed its own push is not
# repaired under its number but succeeded by the next one (#173). The next number is the patch
# plus one. This script reads no other repository, so where one sequence spans several, the person
# holds that the number is still free.
if [ -z "$EXISTING_ONLY" ] && [ -n "$EXISTING" ] && [ "$(git rev-parse --verify --quiet "${EXISTING}^{commit}")" != "$HEAD_SHA" ]; then
  # Base ten, because 008 is no octal number; three digits stay three digits.
  PATCH="${VERSION##*.}"
  NEXT_PATCH="$(( 10#${PATCH} + 1 ))"
  [ "$NEXT_PATCH" -le 999 ] || die "${VERSION} is burnt and its next patch exceeds three digits - choose another version. Nothing was pushed."
  NEXT_PATCH="$(printf '%03d' "${NEXT_PATCH}")"
  NEXT="${VERSION%.*}.${NEXT_PATCH}"
  die "${EXISTING} stands on origin at $(git rev-parse --short=7 "${EXISTING}^{commit}") and HEAD is $(git rev-parse --short=7 HEAD). A version names one commit, so ${VERSION} is burnt: release ${NEXT} instead. Nothing was pushed."
fi

if [ -n "$EXISTING" ]; then
  TAG="$EXISTING"
  # A TAG ON HEAD THAT NEVER REACHED ORIGIN IS THE RELEASE WITH ITS PUSH STILL OWED (#227): the mint
  # pushed HEAD and the run was cut before the tag's own push landed. Reusing it silently would fire
  # no build and pin nothing; it is pushed now, and the rest of the run proceeds as a reuse.
  if ! git ls-remote --exit-code --tags origin "refs/tags/${TAG}" >/dev/null 2>&1; then
    say "${TAG} stands on this machine only, on the commit being released - its push never reached origin; pushed now"
    git push origin "$RELEASE_PUSH" \
      || die "the release commit for ${TAG} could not be pushed - deploy/after-release was not run"
    git push origin "refs/tags/${TAG}" \
      || die "the release tag ${TAG} could not be pushed - deploy/after-release was not run"
  fi
  if [ -n "$LIBRARY" ]; then
    say "reusing the existing release ${TAG} - one release per version+channel, so nothing is minted"
  else
    say "reusing the existing release ${TAG} - one release per version+channel, so putting it on ${STAGE} rebuilds nothing"
  fi
else
  TS14="$(date -u +%Y%m%d%H%M%S)"
  TAG="${VERSION}-${CHANNEL}-${TS14}"
  # UNDER --from THE STAMP IS MADE ON THE COMMIT NAMED, and only the tag leaves this machine: the
  # stamp commit belongs to no branch, so the default branch does not move.
  if [ -n "$FROM_SHA" ]; then
    git checkout --quiet --detach "$FROM_SHA" || die "${FROM} could not be checked out - nothing was minted"
  fi
  stamp_manifest_version
  git tag -a "$TAG" -m "release $TAG" \
    || die "the release tag ${TAG} could not be created - nothing was pushed"
  if [ -z "$FROM_SHA" ]; then
    git push origin "$RELEASE_PUSH" \
      || die "the release commit for ${TAG} could not be pushed - deploy/after-release was not run"
  fi
  git push origin "refs/tags/${TAG}" \
    || die "the release tag ${TAG} could not be pushed - deploy/after-release was not run"
  say "minted ${TAG}"
fi

# The release COMMIT is the tag's. The rule above makes it HEAD as well, so every push below sends
# what is checked out - except under --existing, where the deploy ref names the release's own commit.
SHA="$(git rev-list -n 1 "$TAG")"
SHA7="${SHA:0:7}"

# A LIBRARY IS RELEASED BY ITS TAG. No build plane reads a deploy ref of it and nothing is pinned, so
# the run ends here; the build plane's publish pipeline reads the tag.
if [ -n "$LIBRARY" ]; then
  after_release
  say "${NAME} ${TAG} (commit ${SHA7}) is released; nothing is deployed"
  exit 0
fi

# THE DELIVERY BRANCH IS NOT MOVED HERE. The unit's Application follows `deploy/<stage>`, and the
# platform's release pipeline places it on the release commit plus the pin commit once every image of
# this release exists (hostyour-manager#293). Moved here, before the build, it let a cluster render
# the release tree with its placeholder tags, and a build that failed left them standing.

DEPLOY_REF="refs/tags/deploy/${STAGE}/${TAG}"
# Delete first (absent on a first deploy — that is the normal case, not an error), then push: the
# push is what the platform's webhook reacts to.
git push origin ":${DEPLOY_REF}" >/dev/null 2>&1 || true
git push origin "${SHA}:${DEPLOY_REF}" \
  || die "the deploy ref ${DEPLOY_REF} could not be pushed - ${TAG} is released; deploy/after-release was not run"

after_release
say "${NAME} ${TAG} (commit ${SHA7}) is on its way to ${STAGE}"
if [ -n "$BUILDS" ]; then
  say "the platform builds these image tags, or skips the build when they already exist:"
  printf '%s\n' "$BUILDS" | while read -r b; do line "    ${b}:${TAG}-${SHA7}"; done
fi
