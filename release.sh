#!/bin/bash
# Cut a release with zero manual git: commit pending changes, bump the tag, push.
# Pushing a v* tag triggers .github/workflows/release.yml, which builds the app,
# zips it, and publishes a GitHub Release with InputStats.zip attached.
#
#   ./release.sh           # auto-increment patch (e.g. v0.1.0 -> v0.1.1)
#   ./release.sh 0.2.0     # explicit version
#   ./release.sh minor     # bump minor (v0.1.3 -> v0.2.0)
set -e
cd "$(dirname "$0")"

LATEST=$(git tag --list 'v*' --sort=-v:refname | head -1 | sed 's/^v//')

case "$1" in
    "")      # auto patch bump
        if [ -z "$LATEST" ]; then VERSION="0.1.0"; else
            IFS=. read -r MA MI PA <<< "$LATEST"; VERSION="$MA.$MI.$((PA + 1))"
        fi ;;
    minor)
        IFS=. read -r MA MI PA <<< "${LATEST:-0.0.0}"; VERSION="$MA.$((MI + 1)).0" ;;
    major)
        IFS=. read -r MA MI PA <<< "${LATEST:-0.0.0}"; VERSION="$((MA + 1)).0.0" ;;
    *)       VERSION="$1" ;;
esac
TAG="v$VERSION"

if git rev-parse "$TAG" >/dev/null 2>&1; then
    echo "Tag $TAG already exists — pass a new version: ./release.sh <version>"; exit 1
fi

echo "Releasing $TAG"

if ! git diff-index --quiet HEAD -- || [ -n "$(git ls-files --others --exclude-standard)" ]; then
    git add -A
    git commit -m "Release $TAG"
fi

git push origin HEAD
git tag "$TAG"
git push origin "$TAG"

echo ""
echo "Pushed $TAG — GitHub Actions is building the release now."
echo "  Progress: https://github.com/mewc/input-stats/actions"
echo "  Release:  https://github.com/mewc/input-stats/releases/tag/$TAG"
