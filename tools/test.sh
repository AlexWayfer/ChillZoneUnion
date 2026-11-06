#!/bin/sh
set -eu
repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
staging=$(mktemp -d)
trap 'rm -f "$staging/ChillZoneUnion"; rmdir "$staging"' EXIT HUP INT TERM
ln -s "$repo" "$staging/ChillZoneUnion"
cd "$staging"
if [ "$#" -eq 0 ]; then set -- simulation security; fi
for suite in "$@"; do
    lua5.1 "ChillZoneUnion/Tests/$suite.lua"
done
