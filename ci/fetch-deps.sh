#!/usr/bin/env bash
# Download the conda-forge packages our built packages need at runtime that the
# channel doesn't have yet, so uploading them makes the channel install on its own.
# Usage: ci/fetch-deps.sh <channel> <dest-dir> <package-dir>...
set -euo pipefail

channel=$1
dest=$(realpath -m "$2"); shift 2
work=$(mktemp -d)
mkdir -p "$dest"

# Names of the packages we built; they are already uploaded to the channel.
names=()
for f in $(find "$@" -name '*.conda'); do
  names+=("$(basename "$f" | sed -E 's/-[^-]+-[^-]+\.conda$//')")
done

# Solve all of them together against conda-forge.
{
  echo '[workspace]'
  echo 'name = "deps"'
  echo "channels = [\"https://prefix.dev/$channel\", \"conda-forge\"]"
  echo 'platforms = ["linux-64"]'
  echo '[dependencies]'
  for n in $(printf '%s\n' "${names[@]}" | sort -u); do echo "$n = \"*\""; done
} > "$work/pixi.toml"
# Retry briefly in case the channel hasn't indexed the fresh upload yet.
for i in 1 2 3 4 5; do
  pixi lock --manifest-path "$work/pixi.toml" >/dev/null && break
  [ "$i" = 5 ] && exit 1
  sleep 15
done

grep -oE 'https://conda\.anaconda\.org/conda-forge/[^ ]+' "$work/pixi.lock" | sort -u |
  while read -r url; do curl -fsSL --retry 3 -o "$dest/$(basename "$url")" "$url"; done
echo "fetched $(ls "$dest" | wc -l) dependency packages into $dest"
rm -rf "$work"
