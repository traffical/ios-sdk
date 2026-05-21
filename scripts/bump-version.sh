#!/usr/bin/env bash
# Reads pending changesets, bumps Sources/Traffical/Client/Version.swift, appends to
# CHANGELOG.md, removes consumed changeset files, writes .release-notes.md for
# the GitHub release body.
#
# Expected to run in the release workflow with bunx changeset available.

set -euo pipefail

current=$(grep 'trafficalSDKVersion' Sources/Traffical/Client/Version.swift | sed -E 's/.*"([^"]+)".*/\1/')

bump="patch"
notes=""
for f in .changeset/*.md; do
    name=$(basename "$f")
    case "$name" in
        README.md|config.json) continue;;
    esac
    [ -f "$f" ] || continue

    # Frontmatter is between the first two `---` lines; body is after the
    # second `---`. Use awk for both — BSD `head` (macOS runner) does not
    # support the GNU `head -n -1` "all but last line" syntax.
    header=$(awk '/^---$/{c++; next} c==1' "$f")
    body=$(awk '/^---$/{c++; next} c==2' "$f")

    case "$header" in
        *major*) bump="major";;
        *minor*) [ "$bump" != "major" ] && bump="minor";;
    esac
    notes+="- $(echo "$body" | tr '\n' ' ' | sed 's/  */ /g' | sed 's/^ //; s/ $//')\n"
done

IFS=. read -r maj min pat <<< "$current"
case "$bump" in
    major) maj=$((maj + 1)); min=0; pat=0;;
    minor) min=$((min + 1)); pat=0;;
    patch) pat=$((pat + 1));;
esac
next="${maj}.${min}.${pat}"

sed -i.bak -E "s/trafficalSDKVersion = \"[^\"]+\"/trafficalSDKVersion = \"${next}\"/" Sources/Traffical/Client/Version.swift
rm Sources/Traffical/Client/Version.swift.bak

today=$(date -u +%Y-%m-%d)
{
    echo "## ${next} — ${today}"
    echo
    printf "%b\n" "${notes}"
    echo
    cat CHANGELOG.md
} > CHANGELOG.md.new
mv CHANGELOG.md.new CHANGELOG.md

printf "%b" "${notes}" > .release-notes.md

# Consume changesets.
for f in .changeset/*.md; do
    name=$(basename "$f")
    case "$name" in
        README.md) ;;
        *) rm -f "$f";;
    esac
done

echo "Bumped ${current} -> ${next} (${bump})"
