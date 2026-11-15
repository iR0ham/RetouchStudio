#!/usr/bin/env bash
# Asserts that the macOS and Windows version sources agree, and, when a tag
# version is passed, that the tag agrees with both. The release workflow runs
# this with the tag version before it publishes; CI runs it without a tag.
#
#   ./Tools/check-versions.sh            # Info.plist against Directory.Build.props
#   ./Tools/check-versions.sh 1.0.0      # and both against a tag version
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
plist="$root/Resources/Info.plist"
props="$root/Windows/Directory.Build.props"

fail() {
    echo "version check: $*" >&2
    exit 1
}

[ -f "$plist" ] || fail "$plist is missing"
[ -f "$props" ] || fail "$props is missing"

macos=$(awk -F'[<>]' '/<key>CFBundleShortVersionString<\/key>/{getline; print $3; exit}' "$plist")
windows=$(awk -F'[<>]' '/<Version>/{print $3; exit}' "$props")

[ -n "$macos" ] || fail 'CFBundleShortVersionString was not found in Resources/Info.plist'
[ -n "$windows" ] || fail '<Version> was not found in Windows/Directory.Build.props'

if [ "$macos" != "$windows" ]; then
    fail "Resources/Info.plist says $macos but Windows/Directory.Build.props says $windows; bump both together"
fi

if [ "$#" -gt 0 ]; then
    tag="$1"
    if [ "$tag" != "$macos" ]; then
        fail "the tag says $tag but Resources/Info.plist and Windows/Directory.Build.props say $macos; bump both together before tagging"
    fi
    echo "version check: tag, Info.plist and Directory.Build.props agree on $tag"
else
    echo "version check: Info.plist and Directory.Build.props agree on $macos (no tag to compare)"
fi
