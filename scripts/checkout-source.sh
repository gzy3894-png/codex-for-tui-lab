#!/usr/bin/env sh
set -eu

repo="${1:?usage: checkout-source.sh owner/repo ref dest}"
ref="${2:?usage: checkout-source.sh owner/repo ref dest}"
dest="${3:?usage: checkout-source.sh owner/repo ref dest}"

case "$repo" in
  */*) ;;
  *) printf 'FAIL: repository must be owner/name: %s\n' "$repo" >&2; exit 1 ;;
esac
owner="${repo%%/*}"
name="${repo#*/}"
[ "$repo" = "$owner/$name" ] || { printf 'FAIL: repository must be owner/name: %s\n' "$repo" >&2; exit 1; }
case "$owner" in *[!A-Za-z0-9_.-]*|""|*".."*) printf 'FAIL: unsafe repository owner: %s\n' "$owner" >&2; exit 1 ;; esac
case "$name" in *[!A-Za-z0-9_.-]*|""|*".."*) printf 'FAIL: unsafe repository name: %s\n' "$name" >&2; exit 1 ;; esac

rm -rf "$dest"
mkdir -p "$dest"

git init -q "$dest"
git -C "$dest" remote add origin "https://github.com/$repo.git"
git -C "$dest" fetch --depth 1 origin "$ref"
git -C "$dest" checkout -q --detach FETCH_HEAD

printf 'SOURCE_REPO=%s\n' "$repo"
printf 'SOURCE_REF=%s\n' "$ref"
printf 'SOURCE_SHA=%s\n' "$(git -C "$dest" rev-parse HEAD)"
