#!/bin/bash
set -euo pipefail

project_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_root"
mkdir -p build
project_key="$(printf '%s' "$project_root" | shasum -a 256 | cut -c 1-12)"
derived_data="$HOME/Library/Developer/Xcode/DerivedData/MySubler-$project_key"

# Xcode 27 supports macOS deployment targets starting at 12.0.
# Ad-hoc signing lets this development build run without an Apple developer account.
xcodebuild \
  -project Subler.xcodeproj \
  -scheme Subler \
  -configuration Debug \
  -destination "platform=macOS,arch=$(uname -m)" \
  -derivedDataPath "$derived_data" \
  MACOSX_DEPLOYMENT_TARGET=12.0 \
  CODE_SIGN_IDENTITY=- \
  "$@" build 2>&1 | tee build/build.log

app_path="$derived_data/Build/Products/Debug/Subler.app"
codesign --verify --deep --strict "$app_path"
printf '%s\n' "$app_path" > build/app-path.txt
printf '\nBuilt app: %s\n' "$app_path"
