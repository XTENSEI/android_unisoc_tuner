#!/bin/sh
# Unisoc Tuner release notes - reads the commit log between tags so a release
# says what changed instead of pointing at a diff.
# usage: sh tools/notes.sh <tag> [previous-tag]
set -e

TAG=${1:-}
[ -n "$TAG" ] || { echo "usage: notes.sh <tag> [previous-tag]" >&2; exit 1; }

MOD=$(cd "$(dirname "$0")/.." && pwd)
PREV=${2:-}

if [ -z "$PREV" ]; then
  PREV=$(git tag --sort=-v:refname | grep -v "^$TAG\$" | head -1 || true)
fi
if [ -n "$PREV" ]; then RANGE="$PREV..$TAG"; else RANGE="$TAG"; fi

VER=$(sed -n 's/^version=//p' "$MOD/module.prop" 2>/dev/null || true)
[ -n "$VER" ] || VER=$TAG

echo "## Unisoc Tuner $VER"
echo
if [ -n "$PREV" ]; then
  echo "Changes since \`$PREV\`:"
else
  echo "First published build."
fi
echo
git log --no-merges --format='- %s (`%h`)' "$RANGE"
echo
echo "### Install"
echo
echo "Flash \`unisoc-tuner-$VER.zip\` in KernelSU or Magisk, then reboot."
echo
echo "### Tests"
echo
echo "The same gate CI runs: \`sh tests/selfcheck.sh\`."
