#!/bin/sh
# Unisoc Tuner packaging - build.sh [outdir]
# The repo root already is the module layout, so the zip is a filtered file
# list: the install hooks and the payload, never the tests or the CI.
# usage: sh build.sh [outdir]
set -e

MOD=$(cd "$(dirname "$0")" && pwd)
OUT=${1:-$MOD/out}
FILES="module.prop service.sh action.sh uninstall.sh bin webroot"

VER=$(sed -n 's/^version=//p' "$MOD/module.prop")
[ -n "$VER" ] || { echo "module.prop has no version=" >&2; exit 1; }
NAME=unisoc-tuner-$VER.zip

cd "$MOD"
for f in $FILES; do
  [ -e "$f" ] || { echo "missing $f" >&2; exit 1; }
done

mkdir -p "$OUT"
rm -f "$OUT/$NAME"
zip -q -r "$OUT/$NAME" $FILES -x '*~' '*.bak' '*.orig'

chmod 644 "$OUT/$NAME"
echo "zip $OUT/$NAME"
unzip -l "$OUT/$NAME" | tail -1
