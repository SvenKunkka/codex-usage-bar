#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h:h}"
dist_dir="$project_dir/dist"
app_dir="$dist_dir/Codex Usage Bar.app"
contents_dir="$app_dir/Contents"
binary_path="$project_dir/.build/CodexUsageBar"

cd "$project_dir"
mkdir -p "$project_dir/.build"
clang \
    -O2 \
    -fobjc-arc \
    -mmacosx-version-min=13.0 \
    -framework AppKit \
    -framework ServiceManagement \
    Sources/CodexUsageBar/main.m \
    -o "$binary_path"

rm -rf "$app_dir"
mkdir -p "$contents_dir/MacOS" "$contents_dir/Resources"
cp "$binary_path" "$contents_dir/MacOS/CodexUsageBar"
cp "$project_dir/Resources/Info.plist" "$contents_dir/Info.plist"
codesign --force --deep --sign - "$app_dir"

echo "$app_dir"
