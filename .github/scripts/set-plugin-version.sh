#!/usr/bin/env bash
#
# Records the released version in .claude-plugin/plugin.json.
#
# Claude Code decides whether to update a plugin by this field, so a change that
# reaches main without it never reaches users. The release workflow writes it in the
# same commit that cuts the changelog, so the two records of a version cannot disagree.
#
#   set-plugin-version.sh 0.6.1 [.claude-plugin/plugin.json]
#
# Idempotent: a file that already records the version is left alone.
set -euo pipefail

version=${1:?usage: set-plugin-version.sh <version> [file]}
file=${2:-.claude-plugin/plugin.json}

fail() {
    echo "$*" >&2
    exit 1
}

case "$version" in
    v*) fail "Pass the version without the leading v, got '$version'." ;;
esac
printf '%s' "$version" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+([-.][0-9A-Za-z.-]+)?$' ||
    fail "'$version' is not a version; expected MAJOR.MINOR.PATCH."
[ -f "$file" ] || fail "No such file: $file"

# The manifest's own "version" is the first one in the file: userConfig comes later.
current=$(sed -nE 's/^  "version": "([^"]*)".*$/\1/p' "$file" | head -1)
[ -n "$current" ] || fail "No top-level \"version\" in $file; nothing to update."
if [ "$current" = "$version" ]; then
    echo "$file already records $version; leaving it alone."
    exit 0
fi

tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT

awk -v version="$version" '
    /^  "version": "/ && !replaced {
        sub(/"version": "[^"]*"/, "\"version\": \"" version "\"")
        replaced = 1
    }
    { print }
' "$file" >"$tmp"

cat "$tmp" >"$file"
echo "Set version to $version in $file, was $current."
