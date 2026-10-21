#!/bin/bash
set -euo pipefail

project_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_root"
mkdir -p build/qa
project_key="$(printf '%s' "$project_root" | shasum -a 256 | cut -c 1-12)"
# Tests use a separate application identity and product directory so crashes
# cannot replace the user's collection preferences or the normal development app.
derived_data="$HOME/Library/Developer/Xcode/DerivedData/MySubler-WorkspaceTests-$project_key"
fixture_directory="$(mktemp -d "${TMPDIR:-/private/tmp/}SublerWorkspaceFixture.XXXXXX")"
trap 'rm -rf "$fixture_directory"' EXIT

# A generated test source with H.264, AAC and two chapters. Tests copy it into
# unique temporary directories; no personal media is opened or modified.
if ! command -v ffmpeg >/dev/null 2>&1; then
    printf '%s\n' 'FFmpeg is required to generate the disposable workspace fixture.' >&2
    exit 1
fi
cat > build/qa/workspace-chapters.ffmetadata <<'METADATA'
;FFMETADATA1
title=Workspace fixture
[CHAPTER]
TIMEBASE=1/1000
START=0
END=1000
title=Chapter 1
[CHAPTER]
TIMEBASE=1/1000
START=1000
END=2000
title=Chapter 2
METADATA
ffmpeg -hide_banner -loglevel error -y \
  -f lavfi -i 'color=c=navy:s=320x180:r=24:d=2' \
  -f lavfi -i 'sine=frequency=440:sample_rate=48000:duration=2' \
  -i build/qa/workspace-chapters.ffmetadata \
  -map 0:v -map 1:a -map_metadata 2 -map_chapters 2 \
  -c:v libx264 -pix_fmt yuv420p -c:a aac -movflags +faststart \
  "$fixture_directory/workspace-fixture.mp4"
cp "$fixture_directory/workspace-fixture.mp4" build/qa/workspace-fixture.mp4

result_bundle="$project_root/build/WorkspaceTests-$(date +%Y%m%d-%H%M%S).xcresult"
# xcodebuild forwards TEST_RUNNER_ variables to the hosted test process.
export TEST_RUNNER_WORKSPACE_TEST_FIXTURE="$fixture_directory/workspace-fixture.mp4"
xcodebuild \
  -project Subler.xcodeproj \
  -scheme SublerWorkspace \
  -configuration Debug \
  -destination "platform=macOS,arch=$(uname -m)" \
  -derivedDataPath "$derived_data" \
  -resultBundlePath "$result_bundle" \
  -parallel-testing-enabled NO \
  MACOSX_DEPLOYMENT_TARGET=12.0 \
  CODE_SIGN_IDENTITY=- \
  SUBLER_APP_BUNDLE_IDENTIFIER=org.subler.WorkspaceTestsHost \
  "$@" test 2>&1 | tee build/workspace-tests.log
if grep -Eq 'with [1-9][0-9]* tests? skipped' build/workspace-tests.log; then
    printf '%s\n' 'Fixture tests were skipped; inspect build/workspace-tests.log.' >&2
    exit 1
fi
printf '\nTest results: %s\n' "$result_bundle"
