# Unified Workspace engineering notes

## Baseline and boundaries

Work continues on `codex/my-subler` at upstream `0c3d7de`. Before this feature,
local changes consisted of `BUILDING.md`, `scripts/build-local.sh`, and the
MP42Foundation substitution from unavailable `4648f9d` to `bfa477b`. These remain
separate from product changes in the build-setup commit. The existing checkout
and branch are preserved; no new fork or reset was used.

## Architecture assessment

Subler is an AppKit document application. `DocumentController` creates
`Document` instances; each owns an `MP42File` and an independent undo manager.
`Document.makeWindowControllers()` previously created a window controller that
also owned all editing actions and a programmatic split view. Its XIB supplies
only the outer window. Metadata/artwork, tracks, audio/video properties and
chapters already live in reusable native view controllers.

The obstacle to sharing a window was presentation coupling, rather than a
single-document model: save/revert/script actions found the first window
controller, and editor actions presented sheets through that window controller.

`DocumentEditorViewController` now contains the existing editor and actions.
`DocumentWindowController` retains traditional window/toolbar setup and hosts
this editor. The workspace retains one original `Document` and one dedicated
editor for each visited item. It never rebinds an editor to another document or
assigns one window to several document window controllers. Windowless documents
remain registered with `NSDocumentController` for normal application lifecycle
and close handling. Active document routing and sheet hosting are explicit.

The collection is a list of file references and presentation state, not another
editable media model. Import and existing filename identification run on a
serial background queue. Media parsing occurs on first selection; document
registration and all editor work occur on the main thread. Unsupported files
report errors instead of falling into the traditional track-import workflow.

## Saving and lifetime

Edits use the same MP42 metadata/track/chapter primitives and undo history as
traditional windows. A switch first ends field editing and honors validation
failure. Attached sheets and workspace processing prevent selection changes.

Save Selected and Save All serialize calls to `Document.save` and preserve
`NSDocument` change tracking, existing MP42 writes, model reload and undo reset.
The existing processing queue is deliberately not used for live workspace
models: its items take ownership, write directly, then release their models.
Failures stay on the affected row and later files continue. Missing/read-only
sources and changed modification-date/size snapshots are checked before writes.
These checks preserve Subler's existing write guarantees; they do not make the
underlying MP42 in-place update transactionally atomic.

Removing files invokes each loaded document's normal save/discard/cancel check.
Removal never deletes the media. Closing a workspace checks every loaded
document. Processing cannot be interrupted by closing the workspace.

## Batch and metadata

Batch editing uses explicit field checkboxes, mixed-value placeholders and
independent undo groups. Only checked TV Show, Season, Media Kind or artwork
fields change. Titles, descriptions and episode numbers are preserved.
Per-file provider search remains the existing editor sheet. Look Up Season now
assigns a retained `WorkspaceSeasonContext` to every selected file. It pins the
provider, language, series identity and season, and stores isolated value
snapshots of episode records. Same-named series with different provider IDs stay
separate choices. The context contains lookup data, not editable media; each
original document still owns its metadata, artwork, undo history and writes.

The season sheet reviews automatic S01E01, 1x01 and bare E01 matches, rejects
wrong-season and ambiguous multi-episode filenames, and supports manual episode
choices. Series/season and chosen artwork apply to the entire selection, including
unmatched files. Checked episode matches explicitly replace episode-specific
fields; unchecked files retain those fields. Provider details are fetched before
any document changes, so cancellation during fetching leaves edits untouched.

The original artwork chooser is reused for reviewed season/series artwork;
local images are also supported. Episode and person images are excluded. TheTVDB
season images whose season number cannot be established from the decoded API
schema are excluded rather than silently suggesting another season's cover.
Some existing provider enrichment adds name-matched artwork from Apple TV; users
must review it rather than treating every candidate as identity-verified.

Assigned files display an inline episode picker. Applying an episode fetches
only its missing details and protects shared show, season, album and artwork
fields, including under custom result maps. Absent episode-specific values clear
the previous episode's stale values. Reapplying is an explicit replacement of
those fields, so manual corrections remain until the user requests replacement.
Artwork enrichment runs once per context; episode details are cached separately.
Providers that silently return partial results on network errors cannot expose
reliable failure status here; Search Season creates a fresh lookup for retries.
iTunes multipart collections currently remain separate contexts.

The filename parser receives the full filename because its Perl rules require
an extension to recognize dotted S01E01 names.

## Restoration

Collection references use macOS bookmarks with path fallbacks for unavailable
files. Selection and ordering are recorded. Opening Unified Workspace restores
the last collection. Successfully saved season assignments and cached episode
records are also restored; unsaved assignments are not persisted as if written.
Native Revert restores the last saved assignment alongside the media metadata.
Lookup snapshots store text, numbers, dates and remote image URLs, without
duplicating downloaded artwork in preferences. Artwork remains in each native
media document. This restores file references and saved lookup context, not
unsaved media changes; normal save/discard/cancel handling remains required.
Full crash recovery of unsaved MP42 models needs a separate design and is not
claimed here. The context schema will need explicit migration/version handling
before changing the provider implementation behind an existing provider name.

## Performance and compatibility

MP42 reads track descriptions, annotations, artwork and chapter preview samples,
then closes the media read handle. It does not retain whole audio/video streams.
Visited editors and models are retained to preserve state; large artwork and
chapter preview collections can therefore increase memory. Lazy initial loading
limits startup cost. An eviction policy for clean models should follow real
measurements and must not discard unsaved changes or undo history.

The implementation uses AppKit and existing dependencies, preserving the
project's macOS deployment setting. Local Xcode 27 builds retain the established
macOS 12 override. Actual validation is on Apple Silicon/macOS 27; older supported
systems still need a compatibility pass.

## Validation workflow

Run `./scripts/build-local.sh` for the app and strict signature verification.
Run `./scripts/test-workspace.sh` for hosted XCTest regressions. The test helper
generates H.264/AAC/two-chapter media and all writes use disposable copies.
Results and logs live in ignored `build/`. GUI verification should also exercise
cell edits while switching, menu/shortcut routing, batch sheets, close prompts,
and traditional windows; automated model tests alone cannot establish these.

For an upstream submission, separate editor extraction and regression tests from
the workspace UI, then batch/season/restoration improvements. Exclude the local
dependency substitution and environment-specific build settings unless agreed
with maintainers. Complete localization, accessibility and old-macOS review,
and test with larger real-world artwork/track/chapter collections.


## Progress and verification — 21 October 2026

Milestone One is implemented and verified. The final `scripts/build-local.sh`
build and strict code-signature verification passed; log:
`build/workspace-final-build.log`. Final hosted XCTest run:
`build/WorkspaceTests-20261021-125939.xcresult`, 22 tests, zero failures and zero
skips. Coverage includes 20-file state isolation/Save All, Save Selected,
independent undo and chapter undo, mixed batch edits preserving unique values,
traditional windows/save sheets, failed saves with continuation/retry,
corrupt/unsupported/missing/read-only files, duplicate paths/symlinks/hard links,
external-change and Save As ownership conflicts, close-Cancel, rapid A-B-A loads,
keyboard focus and the unhandled-key recursion regression. The 100-file fixture
collection imports lazily with at most one model/editor initially loaded.
These small generated fixtures do not establish memory use for large artwork.

Actual GUI verification used 20 disposable files under
`/private/tmp/subler-workspace-gui-20261021/Season 1`. Folder import, retained cell
edits while switching without Return, multi-selection, batch show/season edits,
Save All, original chapter insertion and Cmd-Z, consecutive Down arrows,
collection restoration and metadata reload were exercised in one workspace.
A GUI-discovered keyboard recursion crash was fixed and covered by tests.

Live season lookup through existing TheTVDB returned six season-one records for
the public test query The Office. Two exact file matches were reviewed and
applied with replacement disabled. The manually entered titles and show name
survived while episode numbers and descriptions were added; Save All and reopen
confirmed persistence. Other providers, manual mismatch corrections and shared
artwork have not had a complete GUI regression pass.

FFprobe/FFmpeg independently confirmed the two GUI-edited files' distinct titles,
shared show/season, episode numbers, provider text and original chapters. Their
original H.264/AAC stream SHA-256 hashes match the source, and both decode without
errors. Machine-readable evidence is `build/qa/workspace-gui-validation.json`.
File drag/drop is implemented in the sidebar; GUI import verification used the
Add panel. Testing used no personal media.

Remaining work for upstream review: hierarchical series/season grouping,
full localization/accessibility review, larger real-world memory profiling,
older supported macOS testing, more provider/artwork regression coverage, and
unsaved crash recovery. Collection/selection/order restoration is implemented;
unsaved-edit restoration is not. Changes were kept local through validation;
the user subsequently authorized committing and pushing this checkpoint.
No pull request has been created.

## Retained season workflow — 21 October 2026

The follow-up season workflow is implemented. Select a subset, use Look Up
Season, review its episode matches and choose shared artwork once. Apply Season
to Selection assigns shared tags/artwork to all selected files and replaces only
checked episode matches. An assigned file's inline episode picker changes its
episode without repeating the show/season or artwork search. Other subsets keep
independent contexts. Saved contexts and episode choices survive app restart.

The app build and strict signature check passed in
`build/season-context-final-build.log`. The final hosted run is
`build/WorkspaceTests-20261021-151445.xcresult`: 36 tests, zero failures and zero
skips. New coverage includes three groups/30 files with independent artwork,
filename ambiguity, provider identity and episode identity, custom map field
protection, removal of stale episode values, isolated snapshots (including
Date/URL normalization), caching/artwork request counts, cancellation, native
undo, save/revert/context restoration, malformed legacy references, and the
actual inline episode menu. XCTest commands use explicit event boundaries where
needed; AX actions do not necessarily create native AppKit undo event groups.

Hosted tests now build under `org.subler.WorkspaceTestsHost` with separate
DerivedData. A crash cannot overwrite normal app workspace preferences. The
normal app remains `org.galad.Subler`; all four normal workspace preference
values were byte-identical before/after the isolated final test run. Evidence:
`build/qa/season-context/preference-isolation.json`.

Actual GUI testing imported 30 generated MP4s in three folders. Three ten-file
subsets were independently assigned The Office (US), seasons 1/2/3. Season one
used a downloaded provider image; seasons two and three used different generated
local images to verify image isolation. The six real season-one matches were
applied; four extra files correctly stayed unmatched while receiving shared
tags/artwork. After save/quit/reopen, one unmatched file was assigned E02,
Diversity Day, from the retained episode list. Its description/cast appeared
without another series or artwork search; Cmd-Z/Shift-Cmd-Z and Save Selected
were exercised. Season two/three auto-matched ten files each. Save All completed
each group with zero failures. Only the workspace and its modal sheets appeared.

GUI testing found/fixed two control regressions: episode popup items were
disabled by generic menu validation, and season match cells needed reloading
when asynchronous artwork loading ended. Nested artwork and local-image sheets
were exercised successfully. Existing sample files from the first milestone
remain on disk; the previously unsaved sample edit was saved before restarting.

FFprobe/FFmpeg reopened all 30 saved files, verified their respective show/season,
three distinct artwork hashes (one identical hash within each ten-file group),
the manually chosen episode/title/description, preserved unmatched titles and
original two chapter titles. Every original H.264/AAC packet hash matches the
generated source, and all 30 files decode without errors. Evidence:
`build/qa/season-context/gui-media-validation.json`. No personal media was tested.

The retained three-season lookup cache occupies about 1.6 MB in this live test;
no downloaded image bytes are duplicated in that cache. Repeated remote artwork
URLs in provider snapshots could be deduplicated if profiling warrants it.
The existing lazy-media model policy remains unchanged. Large real media,
other providers' full GUI workflows and older macOS releases remain unverified.

The final normal-app restart restored all 30 references, all three season
contexts and the manual E02 assignment with zero modified files or errors.
The actual retained episode menu is captured in
`build/qa/season-context/retained-episode-picker.png`; the app is left open.
