#!/bin/bash

set -euo pipefail

app_path="${1:?Usage: validate-release.sh <app-path> [appcast-path]}"
appcast_path="${2:-}"
info_path="$app_path/Contents/Info.plist"

if [[ ! -d "$app_path" || ! -f "$info_path" ]]; then
    echo "Application bundle is missing or invalid: $app_path" >&2
    exit 1
fi

feed_url="$(/usr/libexec/PlistBuddy -c 'Print :SUFeedURL' "$info_path")"
public_key="$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$info_path")"
bundle_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$info_path")"
short_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$info_path")"

if [[ "$feed_url" != "https://github.com/Seaony/Yomi/releases/latest/download/appcast.xml" ]]; then
    echo "SUFeedURL does not point to the Yomi release feed." >&2
    exit 1
fi
if [[ -z "$bundle_version" || -z "$short_version" ]]; then
    echo "Bundle versions must not be empty." >&2
    exit 1
fi
key_length="$(printf '%s' "$public_key" | base64 --decode | wc -c | tr -d ' ')"
if [[ "$key_length" != "32" ]]; then
    echo "SUPublicEDKey must decode to 32 bytes." >&2
    exit 1
fi
if [[ ! -d "$app_path/Contents/Frameworks/Sparkle.framework" ]]; then
    echo "Sparkle.framework is missing from the application bundle." >&2
    exit 1
fi

codesign --verify --deep --strict --verbose=2 "$app_path"

if [[ -n "$appcast_path" ]]; then
    if [[ ! -f "$appcast_path" ]]; then
        echo "Appcast is missing: $appcast_path" >&2
        exit 1
    fi
    xmllint --noout "$appcast_path"
    if ! grep -Eq 'sparkle:edSignature=' "$appcast_path"; then
        echo "Appcast does not contain an EdDSA archive signature." >&2
        exit 1
    fi
    if ! grep -Eq 'https://github\.com/Seaony/Yomi/releases/download/' "$appcast_path"; then
        echo "Appcast does not point to a Yomi GitHub release asset." >&2
        exit 1
    fi
fi

echo "Validated $short_version ($bundle_version)"
