#!/usr/bin/env bash
# Download every conda-forge package that our built packages need at runtime,
# so they can be uploaded next to them and the channel installs on its own.
# Usage: ci/fetch-deps.sh <dest-dir> <package-dir>...
set -euo pipefail

dest=$(realpath -m "$1"); shift
work=$(mktemp -d)
mkdir -p "$dest"

# Turn the built packages into a local channel.
names=()
for f in $(find "$@" -name '*.conda'); do
  subdir=$(basename "$(dirname "$f")")
  mkdir -p "$work/channel/$subdir"
  cp "$f" "$work/channel/$subdir/"
  names+=("$(basename "$f" | sed -E 's/-[^-]+-[^-]+\.conda$//')")
done
mkdir -p "$work/channel/noarch"
pixi exec rattler-index fs "$work/channel" >/dev/null

# Solve all of them together against conda-forge.
{
  echo '[workspace]'
  echo 'name = "deps"'
  echo "channels = [\"file://$work/channel\", \"conda-forge\"]"
  echo 'platforms = ["linux-64"]'
  echo '[dependencies]'
  for n in $(printf '%s\n' "${names[@]}" | sort -u); do echo "$n = \"*\""; done
} > "$work/pixi.toml"
pixi lock --manifest-path "$work/pixi.toml" >/dev/null

grep -oE 'https://conda\.anaconda\.org/conda-forge/[^ ]+' "$work/pixi.lock" | sort -u |
  while read -r url; do curl -fsSL --retry 3 -o "$dest/$(basename "$url")" "$url"; done
echo "fetched $(ls "$dest" | wc -l) dependency packages into $dest"
rm -rf "$work"
