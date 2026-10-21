# Local development

Use Xcode 27 with its license accepted and required components installed.
The local build uses the Mac's native architecture, a macOS 12 deployment
target, and ad-hoc signing, so an Apple developer account is not required.

From the repository root:

```sh
./scripts/build-local.sh
```

The app is written under `~/Library/Developer/Xcode/DerivedData/MySubler-*`.
Its exact path is recorded in `build/app-path.txt` after a successful build.
The complete build log is `build/build.log`. Generated local files are ignored by Git.
Derived data stays outside this workspace because its file provider attaches
Finder metadata to app bundles, which prevents code signing.
To launch this exact copy separately from an installed Subler:

```sh
open -n "$(cat build/app-path.txt)"
```

This build retains Subler's bundle identifier, preferences, and upstream update
feed. It is a local development build; do not use its updater to replace it.

## Dependency pin

Upstream Subler revision `0c3d7de364a7eedaa54bcc4bb81d76bde6ca2d8b` points
MP42Foundation at `4648f9d585b38957a797bdb13632497abdbe4dfe`, which GitHub
does not serve. This working tree instead uses
`bfa477b799ce55716f744638e6dfe3f23d39c5d7`, the dependency version recorded
by the preceding Subler dependency update, `934ae63`.

The changed submodule pointer is recorded separately as this fork's build
preparation. Checkouts of this branch can initialize the pinned dependencies
normally:

```sh
git submodule update --init --recursive
```

To reproduce the dependency substitution when starting from the upstream
revision instead:

```sh
git submodule update --init --remote MP42Foundation
git -C MP42Foundation checkout bfa477b799ce55716f744638e6dfe3f23d39c5d7
git -C MP42Foundation submodule update --init --recursive
```

Sparkle is resolved by Xcode at the project's exact version, 2.9.6.
The build helper overrides the deployment target for the app and its framework
without changing the upstream Xcode project settings.

## Validation on 21 October 2026

On an Apple Silicon Mac running macOS 27.0.1 with Xcode 27.0 (27A266a):

- The Debug build succeeded and passed `codesign --verify --deep --strict`.
- The running process was confirmed to use the newly built app's executable.
- A generated two-second H.264/AAC MP4 with two chapters opened successfully.
- Metadata and chapter-title edits saved and reopened successfully. Adding a
  chapter and undoing the addition restored the original two chapters.
- FFprobe confirmed the saved title, chapter names, timestamps, and duration.
  SHA-256 stream hashes showed the original video and audio were unchanged,
  and FFmpeg decoded both streams without errors.

These are build and smoke checks, not a full regression test of every feature.
Test files and inspection results are under the ignored `build/qa/` directory.
