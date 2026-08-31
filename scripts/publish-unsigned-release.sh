#!/bin/bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

app_name="Yomi"
project="Yomi.xcodeproj"
scheme="Yomi"
repository="Seaony/Yomi"
sparkle_account="${SPARKLE_ACCOUNT:-com.seaony.Moni}"
version="${1:-}"

if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "Usage: scripts/publish-unsigned-release.sh <MAJOR.MINOR.PATCH>" >&2
    exit 1
fi

tag="v$version"
branch="$(git branch --show-current)"
if [[ "$branch" != "master" ]]; then
    echo "Unsigned releases must be published from master, not $branch." >&2
    exit 1
fi
if [[ -n "$(git status --porcelain)" ]]; then
    echo "The working tree must be clean before publishing a release." >&2
    exit 1
fi

git fetch origin master --quiet
head_commit="$(git rev-parse HEAD)"
remote_commit="$(git rev-parse origin/master)"
if [[ "$head_commit" != "$remote_commit" ]]; then
    echo "master must be pushed and match origin/master before publishing." >&2
    exit 1
fi
if git rev-parse -q --verify "refs/tags/$tag" >/dev/null; then
    echo "Tag already exists locally: $tag" >&2
    exit 1
fi
if git ls-remote --exit-code --tags origin "refs/tags/$tag" >/dev/null 2>&1; then
    echo "Tag already exists on origin: $tag" >&2
    exit 1
fi
if gh release view "$tag" --repo "$repository" >/dev/null 2>&1; then
    echo "GitHub Release already exists: $tag" >&2
    exit 1
fi

for command_name in gh xcodebuild ditto hdiutil xmllint lipo codesign; do
    if ! command -v "$command_name" >/dev/null 2>&1; then
        echo "Required command is unavailable: $command_name" >&2
        exit 1
    fi
done
gh auth status >/dev/null

work_dir="$(mktemp -d /tmp/yomi-unsigned-release.XXXXXX)"
trap 'rm -rf "$work_dir"' EXIT
derived_data="$work_dir/DerivedData"
updates_dir="$work_dir/updates"
dmg_root="$work_dir/dmg-root"
output_dir="$repo_root/build/releases/$tag"
mkdir -p "$updates_dir" "$dmg_root"
if [[ -e "$output_dir" ]]; then
    echo "Release output already exists: $output_dir" >&2
    exit 1
fi

build_number=1
latest_tag="$(gh release list \
    --repo "$repository" \
    --exclude-drafts \
    --exclude-pre-releases \
    --limit 1 \
    --json tagName \
    --jq '.[0].tagName // empty')"
if [[ -n "$latest_tag" ]]; then
    latest_dir="$work_dir/latest"
    mkdir -p "$latest_dir"
    gh release download "$latest_tag" \
        --repo "$repository" \
        --pattern appcast.xml \
        --dir "$latest_dir"
    latest_build="$(xmllint --xpath \
        'string((//*[local-name()="item"]/*[local-name()="version"])[1])' \
        "$latest_dir/appcast.xml")"
    if [[ ! "$latest_build" =~ ^[0-9]+$ ]]; then
        echo "Latest appcast has an invalid build number: $latest_build" >&2
        exit 1
    fi
    build_number="$((latest_build + 1))"
fi

echo "Building $app_name $version ($build_number)..."
xcodebuild \
    -quiet \
    -project "$project" \
    -scheme "$scheme" \
    -configuration Release \
    -destination 'generic/platform=macOS' \
    -derivedDataPath "$derived_data" \
    CODE_SIGNING_ALLOWED=NO \
    MARKETING_VERSION="$version" \
    CURRENT_PROJECT_VERSION="$build_number" \
    ARCHS="arm64 x86_64" \
    ONLY_ACTIVE_ARCH=NO \
    build

app_path="$derived_data/Build/Products/Release/$app_name.app"
codesign --force --deep --sign - "$app_path"
scripts/validate-release.sh "$app_path"
architectures="$(lipo -archs "$app_path/Contents/MacOS/$app_name")"
if [[ "$architectures" != *arm64* ]] || [[ "$architectures" != *x86_64* ]]; then
    echo "Release application must contain arm64 and x86_64 architectures." >&2
    exit 1
fi

short_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app_path/Contents/Info.plist")"
bundle_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$app_path/Contents/Info.plist")"
if [[ "$short_version" != "$version" || "$bundle_version" != "$build_number" ]]; then
    echo "Built version does not match $version ($build_number)." >&2
    exit 1
fi

zip_name="$app_name-$version-unsigned.zip"
dmg_name="$app_name-$version-unsigned.dmg"
mkdir -p "$output_dir"
ditto -c -k --sequesterRsrc --keepParent "$app_path" "$output_dir/$zip_name"
ditto "$app_path" "$dmg_root/$app_name.app"
ln -s /Applications "$dmg_root/Applications"
hdiutil create \
    -volname "$app_name" \
    -srcfolder "$dmg_root" \
    -ov -format UDZO \
    "$output_dir/$dmg_name"

previous_tag="$(git describe --tags --abbrev=0 HEAD 2>/dev/null || true)"
notes_path="$work_dir/release-notes.md"
{
    printf '## %s %s\n\n' "$app_name" "$version"
    if [[ -n "$previous_tag" ]]; then
        git log --no-merges --pretty='- %s' "$previous_tag..HEAD"
    else
        git log --no-merges --pretty='- %s' HEAD
    fi
    printf '\n> 此构建未使用 Apple Developer ID 签名，也未经过 Apple 公证。首次打开时，macOS 可能阻止运行；请在“系统设置 → 隐私与安全性”中确认打开。\n'
} > "$notes_path"

cp "$output_dir/$zip_name" "$updates_dir/$zip_name"
cp "$notes_path" "$updates_dir/${zip_name%.zip}.md"
generate_appcast="$derived_data/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_appcast"
if [[ ! -x "$generate_appcast" ]]; then
    echo "Sparkle generate_appcast tool was not found." >&2
    exit 1
fi
"$generate_appcast" \
    --account "$sparkle_account" \
    --download-url-prefix "https://github.com/$repository/releases/download/$tag/" \
    --link "https://github.com/$repository" \
    --embed-release-notes \
    --maximum-versions 1 \
    --maximum-deltas 0 \
    -o "$updates_dir/appcast.xml" \
    "$updates_dir"
cp "$updates_dir/appcast.xml" "$output_dir/appcast.xml"
scripts/validate-release.sh "$app_path" "$output_dir/appcast.xml"

git tag -a "$tag" -m "$app_name $version"
git push origin "$tag"
gh release create "$tag" \
    --repo "$repository" \
    --verify-tag \
    --title "$app_name $version" \
    --notes-file "$notes_path" \
    "$output_dir/$zip_name" \
    "$output_dir/$dmg_name" \
    "$output_dir/appcast.xml"

echo "Published https://github.com/$repository/releases/tag/$tag"
echo "Artifacts: $output_dir"
