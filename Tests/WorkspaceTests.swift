//
//  WorkspaceTests.swift
//  Subler
//
//  Hosted regression tests. Every write targets a disposable fixture copy.
//

import XCTest
import Cocoa
import MP42Foundation
@testable import Subler

@MainActor
final class WorkspaceTests: XCTestCase {
    private var temporaryDirectory: URL!
    private var workspaces: [WorkspaceWindowController] = []
    private var savedWorkspaceDefaults: [String: Any] = [:]
    private let workspaceDefaultKeys = ["UnifiedWorkspaceCollection", "UnifiedWorkspaceCollectionSelection", "UnifiedWorkspaceCollectionSort", "UnifiedWorkspaceSeasonContextsV1", "SBMetadataTvShowResultMap2"]

    override func setUpWithError() throws {
        savedWorkspaceDefaults = [:]
        for key in workspaceDefaultKeys {
            savedWorkspaceDefaults[key] = UserDefaults.standard.object(forKey: key)
        }
        MetadataPrefs.tvShowResultMap = MetadataResultMap.tvShowDefaultMap
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SublerWorkspaceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory,
                                               withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        for workspace in workspaces {
            for item in workspace.entries {
                item.document?.undoManager?.removeAllActions()
                item.document?.updateChangeCount(.changeCleared)
                item.document?.close()
            }
            workspace.window?.close()
        }
        workspaces = []
        for key in workspaceDefaultKeys {
            if let value = savedWorkspaceDefaults[key] {
                UserDefaults.standard.set(value, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        if let temporaryDirectory {
            try FileManager.default.removeItem(at: temporaryDirectory)
        }
        temporaryDirectory = nil
    }

    private func fixtureCopy(_ filename: String = "episode.mp4") throws -> URL {
        let fixturePath = ProcessInfo.processInfo.environment["WORKSPACE_TEST_FIXTURE"] ?? ""
        let fixture = URL(fileURLWithPath: fixturePath)
        guard !fixturePath.isEmpty, FileManager.default.fileExists(atPath: fixture.path) else {
            throw XCTSkip("Generate the disposable fixture with scripts/test-workspace.sh first.")
        }
        let destination = temporaryDirectory.appendingPathComponent(filename)
        // File-provider workspaces can stall cross-volume clonefile copies.
        try Data(contentsOf: fixture).write(to: destination)
        return destination
    }

    private func document(_ filename: String = "episode.mp4") throws -> Document {
        let url = try fixtureCopy(filename)
        let document = Document(mp4: try MP42File(url: url))
        document.fileURL = url
        document.fileType = "Movie-MPEG4"
        return document
    }

    private func title(_ document: Document) -> String? {
        document.mp4.metadata.metadataItemsFiltered(byIdentifier: MP42MetadataKeyName).first?.stringValue
    }

    private func setTitle(_ title: String, on document: Document) {
        let metadata = document.mp4.metadata
        document.undoManager?.beginUndoGrouping()
        for item in metadata.metadataItemsFiltered(byIdentifier: MP42MetadataKeyName) {
            metadata.removeItem(item)
        }
        metadata.addItem(MP42MetadataItem(identifier: MP42MetadataKeyName,
                                          value: title as NSString,
                                          dataType: .string,
                                          extendedLanguageTag: nil))
        document.undoManager?.endUndoGrouping()
    }

    func testIndependentMetadataAndUndoManagers() throws {
        let first = try document("first.mp4")
        let second = try document("second.mp4")
        let originalFirstTitle = title(first)
        let originalSecondTitle = title(second)

        XCTAssertFalse(first.undoManager === second.undoManager)
        setTitle("First episode", on: first)
        setTitle("Second episode", on: second)
        XCTAssertEqual(title(first), "First episode")
        XCTAssertEqual(title(second), "Second episode")

        first.undoManager?.undo()
        XCTAssertEqual(title(first), originalFirstTitle)
        XCTAssertEqual(title(second), "Second episode")
        second.undoManager?.undo()
        XCTAssertEqual(title(second), originalSecondTitle)
        first.undoManager?.redo()
        XCTAssertEqual(title(first), "First episode")
    }

    func testExistingEditorsLoadWithoutCreatingDocumentWindows() throws {
        let first = try document("first.mp4")
        let second = try document("second.mp4")
        let visibleWindowCount = NSApp.windows.filter(\.isVisible).count
        let firstEditor = DocumentEditorViewController(document: first)
        let secondEditor = DocumentEditorViewController(document: second)
        let container = NSViewController()
        container.view = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 650))

        for editor in [firstEditor, secondEditor, firstEditor, secondEditor, firstEditor] {
            for child in container.children {
                child.view.removeFromSuperview()
                child.removeFromParent()
            }
            container.addChild(editor)
            editor.view.frame = container.view.bounds
            container.view.addSubview(editor.view)
        }
        setTitle("Retained after switching", on: first)
        XCTAssertEqual(title(first), "Retained after switching")
        XCTAssertNotEqual(title(second), "Retained after switching")
        XCTAssertTrue(first.windowControllers.isEmpty)
        XCTAssertTrue(second.windowControllers.isEmpty)
        XCTAssertEqual(NSApp.windows.filter(\.isVisible).count, visibleWindowCount)
        XCTAssertNil(firstEditor.view.window)
        XCTAssertNil(secondEditor.view.window)
        XCTAssertFalse(firstEditor.view === secondEditor.view)
        XCTAssertTrue(container.children.first === firstEditor)
    }

    func testChapterUndoRemainsIndependent() throws {
        let first = try document("first.mp4")
        let second = try document("second.mp4")
        let firstChapters = try XCTUnwrap(first.mp4.chapters)
        let secondChapters = try XCTUnwrap(second.mp4.chapters)
        let originalCount = firstChapters.chapterCount()
        let secondCount = secondChapters.chapterCount()

        first.undoManager?.beginUndoGrouping()
        firstChapters.addChapter("Added in workspace", timestamp: 1500)
        first.undoManager?.endUndoGrouping()
        XCTAssertEqual(firstChapters.chapterCount(), originalCount + 1)
        first.undoManager?.undo()
        XCTAssertEqual(firstChapters.chapterCount(), originalCount)
        XCTAssertEqual(secondChapters.chapterCount(), secondCount)
        first.undoManager?.redo()
        XCTAssertEqual(firstChapters.chapterCount(), originalCount + 1)
    }

    func testSaveAndReopenPreservesIndependentEdits() throws {
        let first = try document("first.mp4")
        let second = try document("second.mp4")
        let firstURL = try XCTUnwrap(first.fileURL)
        let secondURL = try XCTUnwrap(second.fileURL)
        let originalDuration = first.mp4.duration
        let originalTrackIDs = Set(first.mp4.tracks.filter { $0 is MP42VideoTrack || $0 is MP42AudioTrack }.map(\.trackId))
        setTitle("Saved first episode", on: first)
        setTitle("Still unsaved second episode", on: second)
        first.updateChangeCount(.changeDone)
        second.updateChangeCount(.changeDone)

        let saved = expectation(description: "Existing NSDocument save completes")
        var saveError: Error?
        first.save(to: firstURL, ofType: "Movie-MPEG4", for: .saveOperation) { error in
            saveError = error
            saved.fulfill()
        }
        wait(for: [saved], timeout: 30)
        XCTAssertNil(saveError)
        let reopenedFirst = try MP42File(url: firstURL)
        let reopenedSecond = try MP42File(url: secondURL)
        XCTAssertEqual(reopenedFirst.metadata.metadataItemsFiltered(byIdentifier: MP42MetadataKeyName).first?.stringValue,
                       "Saved first episode")
        XCTAssertNotEqual(reopenedSecond.metadata.metadataItemsFiltered(byIdentifier: MP42MetadataKeyName).first?.stringValue,
                          "Still unsaved second episode")
        XCTAssertEqual(title(second), "Still unsaved second episode")
        XCTAssertTrue(second.isDocumentEdited)
        XCTAssertFalse(first.isDocumentEdited)
        XCTAssertEqual(reopenedFirst.duration, originalDuration)
        XCTAssertEqual(reopenedFirst.tracks.filter { originalTrackIDs.contains($0.trackId) }.count,
                       originalTrackIDs.count)
    }

    func testMissingFileSaveReportsFailureAndRetainsEdits() throws {
        let document = try self.document()
        let url = try XCTUnwrap(document.fileURL)
        setTitle("Recoverable unsaved edit", on: document)
        document.updateChangeCount(.changeDone)
        try FileManager.default.removeItem(at: url)

        let failed = expectation(description: "Save of missing disposable source completes with error")
        var saveError: Error?
        document.save(to: url, ofType: "Movie-MPEG4", for: .saveOperation) { error in
            saveError = error
            failed.fulfill()
        }
        wait(for: [failed], timeout: 30)
        XCTAssertNotNil(saveError)
        XCTAssertEqual(title(document), "Recoverable unsaved edit")
        XCTAssertTrue(document.isDocumentEdited)
    }

    private func descendants<T: NSView>(of view: NSView, matching type: T.Type) -> [T] {
        let matches = (view as? T).map { [$0] } ?? []
        return matches + view.subviews.flatMap { descendants(of: $0, matching: type) }
    }

    private func sidebar(_ workspace: WorkspaceWindowController) throws -> NSTableView {
        let content = try XCTUnwrap(workspace.window?.contentView)
        return try XCTUnwrap(descendants(of: content, matching: NSTableView.self)
            .first { $0.accessibilityLabel() == "Workspace Media" })
    }

    private func waitUntil(_ description: String, timeout: TimeInterval = 20,
                           file: StaticString = #filePath, line: UInt = #line,
                           _ predicate: () -> Bool) {
        let deadline = Date(timeIntervalSinceNow: timeout)
        while !predicate() && Date() < deadline {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
        }
        XCTAssertTrue(predicate(), description, file: file, line: line)
    }

    private func workspace(importing urls: [URL], expectedCount: Int) throws -> WorkspaceWindowController {
        let workspace = WorkspaceWindowController()
        workspaces.append(workspace)
        workspace.showWindow(nil)
        workspace.importURLs(urls)
        waitUntil("Collection import completes") { !workspace.isImporting && workspace.entries.count == expectedCount }
        return workspace
    }

    @discardableResult
    private func select(_ row: Int, in workspace: WorkspaceWindowController) throws -> WorkspaceItem {
        let table = try sidebar(workspace)
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        let item = try XCTUnwrap(workspace.entries.indices.contains(row) ? workspace.entries[row] : nil)
        waitUntil("Selected document loads or reports its error") { item.document != nil || item.error != nil }
        return item
    }

    func testTwentyFileFolderImportsLazilyAndSaveAllPreservesBothEdits() throws {
        for episode in 1...20 {
            _ = try fixtureCopy(String(format: "Fixture.Show.S01E%02d.mp4", episode))
        }
        let workspace = try self.workspace(importing: [temporaryDirectory], expectedCount: 20)
        XCTAssertLessThanOrEqual(workspace.entries.filter { $0.document != nil }.count, 1)
        let first = try select(0, in: workspace)
        let firstDocument = try XCTUnwrap(first.document)
        let firstEditor = try XCTUnwrap(first.editor)
        setTitle("Episode one reviewed", on: firstDocument)
        firstDocument.updateChangeCount(.changeDone)
        let second = try select(1, in: workspace)
        let secondDocument = try XCTUnwrap(second.document)
        setTitle("Episode two reviewed", on: secondDocument)
        secondDocument.updateChangeCount(.changeDone)
        try select(0, in: workspace)
        XCTAssertTrue(first.editor === firstEditor)
        XCTAssertEqual(title(firstDocument), "Episode one reviewed")
        XCTAssertEqual(title(secondDocument), "Episode two reviewed")
        XCTAssertTrue(firstDocument.windowControllers.isEmpty)
        XCTAssertTrue(secondDocument.windowControllers.isEmpty)
        XCTAssertTrue(firstDocument.windowForSheet === workspace.window)
        XCTAssertEqual(workspace.entries.filter { $0.document != nil }.count, 2)

        workspace.saveAllModified(nil)
        XCTAssertTrue(workspace.isProcessing)
        XCTAssertFalse(workspace.windowShouldClose(try XCTUnwrap(workspace.window)))
        waitUntil("Save All finishes", timeout: 60) { !workspace.isProcessing }
        XCTAssertEqual(first.status, "Saved")
        XCTAssertEqual(second.status, "Saved")
        XCTAssertNil(first.error)
        XCTAssertNil(second.error)
        XCTAssertFalse(firstDocument.isDocumentEdited)
        XCTAssertFalse(secondDocument.isDocumentEdited)
        XCTAssertEqual(try MP42File(url: first.url).metadata.metadataItemsFiltered(byIdentifier: MP42MetadataKeyName).first?.stringValue,
                       "Episode one reviewed")
        XCTAssertEqual(try MP42File(url: second.url).metadata.metadataItemsFiltered(byIdentifier: MP42MetadataKeyName).first?.stringValue,
                       "Episode two reviewed")
    }

    func testSaveSelectedLeavesOtherDocumentModified() throws {
        let firstURL = try fixtureCopy("01-first.mp4")
        let secondURL = try fixtureCopy("02-second.mp4")
        let workspace = try self.workspace(importing: [firstURL, secondURL], expectedCount: 2)
        let first = try select(0, in: workspace)
        let firstDocument = try XCTUnwrap(first.document)
        setTitle("Unsaved first", on: firstDocument)
        firstDocument.updateChangeCount(.changeDone)
        let second = try select(1, in: workspace)
        let secondDocument = try XCTUnwrap(second.document)
        setTitle("Saved second", on: secondDocument)
        secondDocument.updateChangeCount(.changeDone)
        XCTAssertEqual(try sidebar(workspace).selectedRowIndexes, IndexSet(integer: 1), "Selection before Save Selected")
        XCTAssertTrue(workspace.activeDocument === secondDocument)
        XCTAssertFalse(workspace.isImporting)
        XCTAssertFalse(workspace.isProcessing)
        XCTAssertNil(workspace.window?.attachedSheet)
        workspace.saveSelected(nil)
        waitUntil("Save Selected finishes", timeout: 60) { !workspace.isProcessing }
        XCTAssertTrue(firstDocument.isDocumentEdited)
        XCTAssertFalse(secondDocument.isDocumentEdited)
        XCTAssertEqual(second.status, "Saved")
        XCTAssertNotEqual(try MP42File(url: firstURL).metadata.metadataItemsFiltered(byIdentifier: MP42MetadataKeyName).first?.stringValue,
                          "Unsaved first")
        XCTAssertEqual(try MP42File(url: secondURL).metadata.metadataItemsFiltered(byIdentifier: MP42MetadataKeyName).first?.stringValue,
                       "Saved second")
    }

    func testDuplicatePathsSymlinksAndHardLinksCollapseToOneItem() throws {
        let source = try fixtureCopy("source.mp4")
        let symbolicLink = temporaryDirectory.appendingPathComponent("symbolic.mp4")
        let hardLink = temporaryDirectory.appendingPathComponent("hard.mp4")
        try FileManager.default.createSymbolicLink(at: symbolicLink, withDestinationURL: source)
        try FileManager.default.linkItem(at: source, to: hardLink)
        let workspace = try self.workspace(importing: [source, source, symbolicLink, hardLink], expectedCount: 1)
        let item = try select(0, in: workspace)
        XCTAssertNotNil(item.document)
        XCTAssertNil(item.error)
        XCTAssertEqual(workspace.entries.count, 1)
    }

    func testCorruptUnsupportedAndMissingFilesProducePerFileErrors() throws {
        let corrupt = temporaryDirectory.appendingPathComponent("01-corrupt.mp4")
        let missing = temporaryDirectory.appendingPathComponent("02-missing.mp4")
        let unsupported = temporaryDirectory.appendingPathComponent("03-unsupported.txt")
        try Data("This is not an MP4 file".utf8).write(to: corrupt)
        try Data("Unsupported media".utf8).write(to: unsupported)
        let workspace = try self.workspace(importing: [corrupt, missing, unsupported], expectedCount: 3)
        for row in 0..<3 {
            let item = try select(row, in: workspace)
            XCTAssertNotNil(item.error)
            XCTAssertNil(item.document)
        }
    }

    func testReadOnlySaveFailsThenContinuesAndCanBeRetried() throws {
        let readOnlyURL = try fixtureCopy("01-read-only.mp4")
        let writableURL = try fixtureCopy("02-writable.mp4")
        let workspace = try self.workspace(importing: [readOnlyURL, writableURL], expectedCount: 2)
        let readOnly = try select(0, in: workspace)
        let readOnlyDocument = try XCTUnwrap(readOnly.document)
        setTitle("Retry after permissions fixed", on: readOnlyDocument)
        readOnlyDocument.updateChangeCount(.changeDone)
        let writable = try select(1, in: workspace)
        let writableDocument = try XCTUnwrap(writable.document)
        setTitle("Other save continues", on: writableDocument)
        writableDocument.updateChangeCount(.changeDone)
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: readOnlyURL.path)
        XCTAssertFalse(FileManager.default.isWritableFile(atPath: readOnlyURL.path))
        workspace.saveAllModified(nil)
        waitUntil("Save All continues after a permission failure", timeout: 60) { !workspace.isProcessing }
        XCTAssertNotNil(readOnly.error)
        XCTAssertEqual(readOnly.status, "Save failed")
        XCTAssertTrue(readOnlyDocument.isDocumentEdited)
        XCTAssertNil(writable.error)
        XCTAssertEqual(writable.status, "Saved")
        XCTAssertFalse(writableDocument.isDocumentEdited)
        XCTAssertEqual(title(readOnlyDocument), "Retry after permissions fixed")
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: readOnlyURL.path)
        workspace.saveAllModified(nil)
        waitUntil("Failed save can be retried", timeout: 60) { !workspace.isProcessing }
        XCTAssertNil(readOnly.error)
        XCTAssertEqual(readOnly.status, "Saved")
        XCTAssertFalse(readOnlyDocument.isDocumentEdited)
    }

    func testExternalFileChangeBlocksOverwriteAndPreservesEdits() throws {
        let source = try fixtureCopy()
        let workspace = try self.workspace(importing: [source], expectedCount: 1)
        let item = try select(0, in: workspace)
        let document = try XCTUnwrap(item.document)
        setTitle("Preserved conflicting edit", on: document)
        document.updateChangeCount(.changeDone)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: 60)], ofItemAtPath: source.path)
        workspace.saveAllModified(nil)
        waitUntil("Conflict preflight completes") { !workspace.isProcessing }
        XCTAssertNotNil(item.error)
        XCTAssertEqual(item.status, "Save failed")
        XCTAssertTrue(document.isDocumentEdited)
        XCTAssertEqual(title(document), "Preserved conflicting edit")
        XCTAssertNotEqual(try MP42File(url: source).metadata.metadataItemsFiltered(byIdentifier: MP42MetadataKeyName).first?.stringValue,
                          "Preserved conflicting edit")
    }

    func testRemovingUnmodifiedItemPreservesFileOnDisk() throws {
        let source = try fixtureCopy()
        let workspace = try self.workspace(importing: [source], expectedCount: 1)
        try select(0, in: workspace)
        XCTAssertEqual(try sidebar(workspace).selectedRowIndexes, IndexSet(integer: 0), "Selection before Remove")
        XCTAssertFalse(try XCTUnwrap(workspace.activeDocument).isDocumentEdited)
        XCTAssertFalse(workspace.isImporting)
        XCTAssertFalse(workspace.isProcessing)
        XCTAssertNil(workspace.window?.attachedSheet)
        workspace.removeSelected(nil)
        waitUntil("Unmodified item removed") { workspace.entries.isEmpty }
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }

    func testClosingModifiedWorkspaceOffersCancelWithoutLosingEdits() throws {
        let source = try fixtureCopy()
        let workspace = try self.workspace(importing: [source], expectedCount: 1)
        let item = try select(0, in: workspace)
        let document = try XCTUnwrap(item.document)
        setTitle("Do not discard", on: document)
        document.updateChangeCount(.changeDone)
        let window = try XCTUnwrap(workspace.window)
        XCTAssertFalse(workspace.windowShouldClose(window))
        waitUntil("Unsaved changes close prompt is presented") { window.attachedSheet != nil }
        let sheet = try XCTUnwrap(window.attachedSheet)
        let content = try XCTUnwrap(sheet.contentView)
        let cancel = try XCTUnwrap(descendants(of: content, matching: NSButton.self).first { $0.title == "Cancel" })
        cancel.performClick(nil)
        waitUntil("Cancel dismisses close prompt") { window.attachedSheet == nil }
        XCTAssertEqual(workspace.entries.count, 1)
        XCTAssertTrue(document.isDocumentEdited)
        XCTAssertEqual(title(document), "Do not discard")
        XCTAssertTrue(window.isVisible)
    }


    func testBatchEditAppliesOnlyCheckedSharedField() throws {
        let firstURL = try fixtureCopy("01-first.mp4")
        let secondURL = try fixtureCopy("02-second.mp4")
        let workspace = try self.workspace(importing: [firstURL, secondURL], expectedCount: 2)
        let first = try select(0, in: workspace)
        let firstDocument = try XCTUnwrap(first.document)
        let second = try select(1, in: workspace)
        let secondDocument = try XCTUnwrap(second.document)
        setTitle("Unique first title", on: firstDocument)
        setTitle("Unique second title", on: secondDocument)
        for (index, document) in [firstDocument, secondDocument].enumerated() {
            document.mp4.metadata.addItem(MP42MetadataItem(identifier: MP42MetadataKeyTVShow,
                                                          value: "Old show \(index)" as NSString,
                                                          dataType: .string, extendedLanguageTag: nil))
            document.mp4.metadata.addItem(MP42MetadataItem(identifier: MP42MetadataKeyTVSeason,
                                                          value: NSNumber(value: index + 1),
                                                          dataType: .integer, extendedLanguageTag: nil))
            document.mp4.metadata.addItem(MP42MetadataItem(identifier: MP42MetadataKeyTVEpisodeNumber,
                                                          value: NSNumber(value: index + 5),
                                                          dataType: .integer, extendedLanguageTag: nil))
            document.updateChangeCount(.changeDone)
        }
        let table = try sidebar(workspace)
        table.selectRowIndexes(IndexSet(integersIn: 0..<2), byExtendingSelection: false)
        XCTAssertEqual(table.selectedRowIndexes, IndexSet(integersIn: 0..<2), "Selection before Batch Edit")
        XCTAssertFalse(workspace.isImporting)
        XCTAssertFalse(workspace.isProcessing)
        XCTAssertNil(workspace.window?.attachedSheet)
        workspace.batchEdit(nil)
        waitUntil("Batch edit sheet opens") { workspace.window?.attachedSheet != nil }
        let sheet = try XCTUnwrap(workspace.window?.attachedSheet)
        let content = try XCTUnwrap(sheet.contentView)
        let grid = try XCTUnwrap(descendants(of: content, matching: NSGridView.self).first)
        let showField = try XCTUnwrap(grid.cell(atColumnIndex: 1, rowIndex: 0).contentView as? NSTextField)
        XCTAssertEqual(showField.placeholderString, "Mixed values")
        let check = try XCTUnwrap(descendants(of: content, matching: NSButton.self).first { $0.title == "TV Show" })
        check.performClick(nil)
        showField.stringValue = "Shared show"
        let apply = try XCTUnwrap(descendants(of: content, matching: NSButton.self).first { $0.title == "Apply Changes" })
        XCTAssertTrue(apply.isEnabled)
        apply.performClick(nil)
        waitUntil("Batch apply sheet closes") { workspace.window?.attachedSheet == nil }
        for (index, document) in [firstDocument, secondDocument].enumerated() {
            XCTAssertEqual(document.mp4.metadata.metadataItemsFiltered(byIdentifier: MP42MetadataKeyTVShow).first?.stringValue,
                           "Shared show")
            XCTAssertEqual(document.mp4.metadata.metadataItemsFiltered(byIdentifier: MP42MetadataKeyTVSeason).first?.numberValue?.intValue,
                           index + 1)
            XCTAssertEqual(document.mp4.metadata.metadataItemsFiltered(byIdentifier: MP42MetadataKeyTVEpisodeNumber).first?.numberValue?.intValue,
                           index + 5)
            XCTAssertTrue(document.isDocumentEdited)
        }
        XCTAssertEqual(title(firstDocument), "Unique first title")
        XCTAssertEqual(title(secondDocument), "Unique second title")
    }


    func testRapidFirstSecondFirstSelectionAttachesOnlyOneEditor() throws {
        let firstURL = try fixtureCopy("01-first.mp4")
        let secondURL = try fixtureCopy("02-second.mp4")
        let workspace = try self.workspace(importing: [firstURL, secondURL], expectedCount: 2)
        let table = try sidebar(workspace)
        for row in [0, 1, 0, 1, 0] {
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
        waitUntil("Rapidly selected documents finish loading") {
            workspace.entries.allSatisfy { $0.document != nil } && workspace.entries[0].editor?.parent != nil
        }
        let first = workspace.entries[0]
        let second = workspace.entries[1]
        XCTAssertTrue(workspace.activeDocument === first.document)
        XCTAssertEqual(first.editor?.parent?.children.count, 1)
        XCTAssertNil(second.editor?.parent)
        XCTAssertEqual(table.selectedRowIndexes, IndexSet(integer: 0))
        XCTAssertTrue(try XCTUnwrap(first.document).windowControllers.isEmpty)
        XCTAssertTrue(try XCTUnwrap(second.document).windowControllers.isEmpty)
    }

    func testSaveAsRejectsDestinationOwnedByAnotherWorkspaceDocument() throws {
        let firstURL = try fixtureCopy("01-first.mp4")
        let secondURL = try fixtureCopy("02-second.mp4")
        let workspace = try self.workspace(importing: [firstURL, secondURL], expectedCount: 2)
        let first = try select(0, in: workspace)
        let firstDocument = try XCTUnwrap(first.document)
        _ = try select(1, in: workspace)
        let originalDestination = try Data(contentsOf: secondURL)
        setTitle("Cannot overwrite second document", on: firstDocument)
        firstDocument.updateChangeCount(.changeDone)
        let finished = expectation(description: "Conflicting Save As rejected")
        var saveError: Error?
        firstDocument.save(to: secondURL, ofType: "Movie-MPEG4", for: .saveAsOperation) { error in
            saveError = error
            finished.fulfill()
        }
        wait(for: [finished], timeout: 10)
        XCTAssertNotNil(saveError)
        XCTAssertEqual(try Data(contentsOf: secondURL), originalDestination)
        XCTAssertTrue(WorkspaceWindowController.sameFile(try XCTUnwrap(firstDocument.fileURL), firstURL))
        XCTAssertTrue(firstDocument.isDocumentEdited)
        XCTAssertFalse(workspace.isProcessing)
    }

    func testWindowSupplementalActionTargetsOnlyActiveDocument() throws {
        let firstURL = try fixtureCopy("01-first.mp4")
        let secondURL = try fixtureCopy("02-second.mp4")
        let workspace = try self.workspace(importing: [firstURL, secondURL], expectedCount: 2)
        let first = try select(0, in: workspace)
        let firstDocument = try XCTUnwrap(first.document)
        let second = try select(1, in: workspace)
        let secondDocument = try XCTUnwrap(second.document)
        try select(0, in: workspace)
        let firstCount = try XCTUnwrap(firstDocument.mp4.chapters).chapterCount()
        let secondCount = try XCTUnwrap(secondDocument.mp4.chapters).chapterCount()
        let window = try XCTUnwrap(workspace.window)
        window.makeKeyAndOrderFront(nil)
        XCTAssertTrue(window.makeFirstResponder(try sidebar(workspace)))
        XCTAssertEqual(try sidebar(workspace).selectedRowIndexes, IndexSet(integer: 0))
        let action = #selector(DocumentEditorViewController.addChaptersEvery(_:))
        let sender = NSMenuItem(title: "At the Beginning", action: action, keyEquivalent: "")
        sender.tag = -1
        // Hosted tests may remain inactive under macOS. Global nil-target dispatch
        // is also exercised through the actual toolbar during manual GUI QA.
        let target = workspace.supplementalTarget(forAction: action, sender: sender) as AnyObject?
        XCTAssertTrue(target === first.editor)
        XCTAssertTrue(NSApp.sendAction(action, to: target, from: sender))
        XCTAssertEqual(firstDocument.mp4.chapters?.chapterCount(), firstCount + 1)
        XCTAssertEqual(secondDocument.mp4.chapters?.chapterCount(), secondCount)
    }


    func testTraditionalDocumentWindowStillEditsSavesAndReopens() throws {
        let document = try self.document()
        defer {
            document.undoManager?.removeAllActions()
            document.updateChangeCount(.changeCleared)
            document.close()
        }
        document.makeWindowControllers()
        let controller = try XCTUnwrap(document.windowControllers.first as? DocumentWindowController)
        let window = try XCTUnwrap(controller.window)
        XCTAssertTrue(window.isVisible)
        XCTAssertTrue(window.contentViewController === controller.editor)
        XCTAssertTrue(document.editorController === controller.editor)
        XCTAssertTrue(document.windowForSheet === window)
        setTitle("Traditional editor retained", on: document)
        document.updateChangeCount(.changeDone)
        let url = try XCTUnwrap(document.fileURL)
        let saved = expectation(description: "Traditional document with progress sheet saves")
        var saveError: Error?
        document.save(to: url, ofType: "Movie-MPEG4", for: .saveOperation) { error in
            saveError = error
            saved.fulfill()
        }
        wait(for: [saved], timeout: 30)
        XCTAssertNil(saveError)
        XCTAssertFalse(document.isDocumentEdited)
        XCTAssertEqual(try MP42File(url: url).metadata.metadataItemsFiltered(byIdentifier: MP42MetadataKeyName).first?.stringValue,
                       "Traditional editor retained")
    }


    private func downArrowEvent(in window: NSWindow) throws -> NSEvent {
        return try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                             timestamp: ProcessInfo.processInfo.systemUptime,
                                             windowNumber: window.windowNumber, context: nil,
                                             characters: "\u{F701}", charactersIgnoringModifiers: "\u{F701}",
                                             isARepeat: false, keyCode: 125))
    }

    func testUnhandledDownArrowDoesNotRecurseInEitherWindowHost() throws {
        let source = try fixtureCopy("workspace.mp4")
        let workspace = try self.workspace(importing: [source], expectedCount: 1)
        let item = try select(0, in: workspace)
        let window = try XCTUnwrap(workspace.window)
        XCTAssertTrue(window.makeFirstResponder(window))
        let event = try downArrowEvent(in: window)
        XCTAssertFalse(try XCTUnwrap(item.editor).handleNavigation(with: event))
        workspace.keyDown(with: event)
        XCTAssertTrue(window.isVisible)

        let traditional = try document("traditional.mp4")
        defer {
            traditional.undoManager?.removeAllActions()
            traditional.updateChangeCount(.changeCleared)
            traditional.close()
        }
        traditional.makeWindowControllers()
        let controller = try XCTUnwrap(traditional.windowControllers.first as? DocumentWindowController)
        let traditionalWindow = try XCTUnwrap(controller.window)
        XCTAssertTrue(traditionalWindow.makeFirstResponder(traditionalWindow))
        controller.keyDown(with: try downArrowEvent(in: traditionalWindow))
        XCTAssertTrue(traditionalWindow.isVisible)
    }

    func testRepeatedSidebarDownArrowsRetainKeyboardFocus() throws {
        for episode in 1...5 {
            _ = try fixtureCopy(String(format: "Fixture.Show.S01E%02d.mp4", episode))
        }
        let workspace = try self.workspace(importing: [temporaryDirectory], expectedCount: 5)
        _ = try select(0, in: workspace)
        let table = try sidebar(workspace)
        let window = try XCTUnwrap(workspace.window)
        XCTAssertTrue(window.makeFirstResponder(table))
        for expectedRow in 1...3 {
            table.keyDown(with: try downArrowEvent(in: window))
            waitUntil("Arrow selection loads its document") {
                workspace.entries[expectedRow].document != nil
            }
            XCTAssertEqual(table.selectedRow, expectedRow)
            XCTAssertTrue(window.firstResponder === table)
            XCTAssertTrue(workspace.activeDocument === workspace.entries[expectedRow].document)
        }
    }

    func testSidebarRecognizesSeasonAndEpisodeFromFullFilename() throws {
        let source = try fixtureCopy("Fixture.Show.S01E03.mp4")
        let workspace = try self.workspace(importing: [source], expectedCount: 1)
        guard case let .tvShow(series, season, episode) = workspace.entries[0].searchTerms else {
            return XCTFail("The filename should produce television episode search terms")
        }
        XCTAssertFalse(series.isEmpty)
        XCTAssertEqual(season, 1)
        XCTAssertEqual(episode, 3)
    }

    func testHundredFileCollectionKeepsModelsLazy() throws {
        for episode in 1...100 {
            _ = try fixtureCopy(String(format: "Collection.%03d.mp4", episode))
        }
        let workspace = try self.workspace(importing: [temporaryDirectory], expectedCount: 100)
        XCTAssertEqual(try sidebar(workspace).numberOfRows, 100)
        XCTAssertLessThanOrEqual(workspace.entries.filter { $0.document != nil }.count, 1)
        XCTAssertLessThanOrEqual(workspace.entries.filter { $0.editor != nil }.count, 1)
    }


    private func providerEpisode(series: String = "Fixture Show", seriesID: Int = 100,
                                 season: Int = 1, episode: Int, description: String? = nil,
                                 cast: String? = nil) -> MetadataResult {
        let result = MetadataResult()
        result.mediaKind = .tvShow
        result[.seriesName] = series
        result[.serviceContentID] = seriesID
        result[.serviceEpisodeID] = seriesID * 10000 + season * 100 + episode
        result[.season] = season
        result[.episodeNumber] = episode
        result[.episodeID] = "S\(season)E\(episode)"
        result[.name] = "\(series) S\(season) Episode \(episode)"
        result[.description] = description
        result[.cast] = cast
        return result
    }

    private func seasonContext(series: String = "Fixture Show", seriesID: Int = 100,
                               season: Int = 1, count: Int = 3,
                               providerName: String = "Workspace Fixture Provider") throws -> WorkspaceSeasonContext {
        let results = (1...count).map {
            providerEpisode(series: series, seriesID: seriesID, season: season, episode: $0,
                            description: "Description \(season)-\($0)", cast: "Cast \(season)-\($0)")
        }
        return try XCTUnwrap(WorkspaceSeasonContext.groups(results: results,
                                                           providerName: providerName,
                                                           language: "en", season: season).first)
    }

    private func seasonItem(_ filename: String = "season-item.mp4") throws -> WorkspaceItem {
        let document = try self.document(filename)
        // Each user command is a separate event; model-only calls here run in one test event.
        document.undoManager?.groupsByEvent = false
        let item = WorkspaceItem(url: try XCTUnwrap(document.fileURL))
        item.document = document
        return item
    }

    private func fixtureArtwork(_ color: NSColor) throws -> MP42Image {
        let representation = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
                                                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                                           isPlanar: false, colorSpaceName: .deviceRGB,
                                                           bytesPerRow: 8, bitsPerPixel: 32))
        for x in 0..<2 { for y in 0..<2 { representation.setColor(color, atX: x, y: y) } }
        let data = try XCTUnwrap(representation.representation(using: .png, properties: [:]))
        return MP42Image(data: data, type: MP42_ART_PNG)
    }

    private func value(_ key: String, in item: WorkspaceItem) -> String? {
        item.document?.mp4.metadata.metadataItemsFiltered(byIdentifier: key).first?.stringValue
    }

    private func artworkData(in item: WorkspaceItem) -> [Data] {
        item.document?.mp4.metadata.metadataItemsFiltered(byIdentifier: MP42MetadataKeyCoverArt).compactMap { $0.imageValue?.data } ?? []
    }

    private func loadedDetails(_ context: WorkspaceSeasonContext, episodeID: String,
                               includeArtwork: Bool = false, service: MetadataService) throws -> MetadataResult {
        let finished = expectation(description: "Fixture provider details load")
        var result: Result<MetadataResult, Error>?
        context.loadDetails(episodeID: episodeID, includeArtwork: includeArtwork, service: service) {
            result = $0
            finished.fulfill()
        }
        wait(for: [finished], timeout: 10)
        return try XCTUnwrap(result).get()
    }

    func testThirtyFilesCanBelongToThreeIndependentSeasonGroups() throws {
        let colors: [NSColor] = [.red, .green, .blue]
        var groupedItems: [[WorkspaceItem]] = []
        var contexts: [WorkspaceSeasonContext] = []
        var images: [MP42Image] = []
        for season in 1...3 {
            let context = try seasonContext(season: season, count: 10)
            let image = try fixtureArtwork(colors[season - 1])
            let items = try (1...10).map { try seasonItem("Group\(season).E\($0).mp4") }
            var assignments: [String: String] = [:]
            for (index, item) in items.enumerated() where index < 9 {
                assignments[item.url.path] = context.episodes[index].id
            }
            try WorkspaceSeasonOperations.assign(context: context, artworks: [image], to: items, episodes: assignments)
            groupedItems.append(items)
            contexts.append(context)
            images.append(image)
        }
        XCTAssertEqual(groupedItems.flatMap { $0 }.count, 30)
        waitUntil("Assigned season documents become modified") {
            groupedItems.flatMap { $0 }.allSatisfy { $0.document?.isDocumentEdited == true }
        }
        for group in 0..<3 {
            for (index, item) in groupedItems[group].enumerated() {
                XCTAssertEqual(item.seasonContext?.id, contexts[group].id)
                XCTAssertEqual(value(MP42MetadataKeyTVShow, in: item), "Fixture Show")
                XCTAssertEqual(item.document?.mp4.metadata.metadataItemsFiltered(byIdentifier: MP42MetadataKeyTVSeason).first?.numberValue?.intValue,
                               group + 1)
                XCTAssertEqual(artworkData(in: item), [try XCTUnwrap(images[group].data)])
                XCTAssertTrue(try XCTUnwrap(item.document).isDocumentEdited)
                if index < 9 {
                    XCTAssertEqual(item.episodeID, contexts[group].episodes[index].id)
                    XCTAssertEqual(value(MP42MetadataKeyName, in: item), "Fixture Show S\(group + 1) Episode \(index + 1)")
                } else {
                    XCTAssertNil(item.episodeID)
                    XCTAssertEqual(value(MP42MetadataKeyName, in: item), "Workspace fixture")
                }
            }
        }
        try WorkspaceSeasonOperations.applyEpisode(context: contexts[1], episodeID: contexts[1].episodes[2].id,
                                                    to: groupedItems[1][9])
        XCTAssertEqual(value(MP42MetadataKeyName, in: groupedItems[1][9]), "Fixture Show S2 Episode 3")
        XCTAssertEqual(value(MP42MetadataKeyName, in: groupedItems[0][9]), "Workspace fixture")
        XCTAssertEqual(value(MP42MetadataKeyName, in: groupedItems[2][9]), "Workspace fixture")
    }

    func testSeasonContextFilenameMatchingRejectsAmbiguousOrWrongSeason() throws {
        let context = try seasonContext(count: 3)
        for name in ["E01.mp4", "Fixture.E01.m4v", "Fixture.EP01.mp4", "Fixture.S01E01.mp4", "Fixture.1x01.mp4"] {
            XCTAssertEqual(context.episode(matchingFilename: URL(fileURLWithPath: "/tmp/" + name))?.number, 1, name)
        }
        for name in ["Fixture.S02E01.mp4", "Fixture.E01-E02.mp4", "Fixture.E01-02.mp4", "Fixture.E01+E02.mp4",
                     "Fixture.E01.E02.mp4", "Fixture.S01E01.S02E01.mp4", "Fixture.E99.mp4", "Fixture.Unknown.mp4"] {
            XCTAssertNil(context.episode(matchingFilename: URL(fileURLWithPath: "/tmp/" + name)), name)
        }
        let duplicate = [providerEpisode(episode: 1), providerEpisode(episode: 1)]
        let ambiguous = try XCTUnwrap(WorkspaceSeasonContext.groups(results: duplicate, providerName: "Fixture", language: "en", season: 1).first)
        XCTAssertNil(ambiguous.episode(matchingFilename: URL(fileURLWithPath: "/tmp/E01.mp4")))
    }

    func testSameNameProviderSeriesAndITunesEpisodeIDsStaySeparate() throws {
        let one = providerEpisode(series: "Same Name", seriesID: 100, episode: 1)
        let two = providerEpisode(series: "Same Name", seriesID: 200, episode: 1)
        let wrongSeason = providerEpisode(series: "Same Name", seriesID: 100, season: 2, episode: 1)
        let contexts = WorkspaceSeasonContext.groups(results: [one, two, wrongSeason], providerName: "Fixture", language: "en", season: 1)
        XCTAssertEqual(contexts.count, 2)
        XCTAssertTrue(contexts.allSatisfy { $0.episodes.count == 1 })
        let firstITunes = providerEpisode(episode: 1)
        firstITunes[.artistID] = 50
        firstITunes[.playlistID] = 500
        firstITunes[.serviceContentID] = 501
        let secondITunes = providerEpisode(episode: 2)
        secondITunes[.artistID] = 50
        secondITunes[.playlistID] = 500
        secondITunes[.serviceContentID] = 502
        let otherCollection = providerEpisode(episode: 1)
        otherCollection[.artistID] = 50
        otherCollection[.playlistID] = 600
        otherCollection[.serviceContentID] = 601
        let iTunesContexts = WorkspaceSeasonContext.groups(results: [firstITunes, secondITunes, otherCollection],
                                                           providerName: iTunesStore().name, language: "en", season: 1)
        XCTAssertEqual(iTunesContexts.count, 2)
        XCTAssertEqual(iTunesContexts.map { $0.episodes.count }.sorted(), [1, 2])
    }

    func testEpisodeChangeReplacesUniqueFieldsAndProtectsSharedCustomDestinations() throws {
        let context = try seasonContext(count: 2)
        let item = try seasonItem()
        let image = try fixtureArtwork(.red)
        try WorkspaceSeasonOperations.assign(context: context, artworks: [image], to: [item],
                                               episodes: [item.url.path: context.episodes[0].id])
        let sharedAlbum = value(MP42MetadataKeyAlbum, in: item)
        let second = try XCTUnwrap(context.metadata(for: context.episodes[1].id))
        second[.description] = nil
        second[.longDescription] = nil
        second[.cast] = "New episode cast"
        try context.cacheDetails(second, episodeID: context.episodes[1].id)
        let originalMap = MetadataPrefs.tvShowResultMap
        defer { MetadataPrefs.tvShowResultMap = originalMap }
        MetadataPrefs.tvShowResultMap = MetadataResultMap(items: MetadataResultMap.tvShowDefaultMap.items + [
            MetadataResultMapItem(key: MP42MetadataKeyTVShow, value: [MetadataResult.Key.name.token]),
            MetadataResultMapItem(key: MP42MetadataKeyTVSeason, value: [MetadataResult.Key.episodeNumber.token]),
            MetadataResultMapItem(key: MP42MetadataKeyAlbum, value: [MetadataResult.Key.name.token]),
            MetadataResultMapItem(key: MP42MetadataKeyCoverArt, value: [MetadataResult.Key.name.token])
        ], type: .tvShow)
        try WorkspaceSeasonOperations.applyEpisode(context: context, episodeID: context.episodes[1].id, to: item)
        XCTAssertEqual(value(MP42MetadataKeyName, in: item), "Fixture Show S1 Episode 2")
        XCTAssertEqual(value(MP42MetadataKeyCast, in: item), "New episode cast")
        XCTAssertNil(value(MP42MetadataKeyDescription, in: item))
        XCTAssertNil(value(MP42MetadataKeyLongDescription, in: item))
        XCTAssertEqual(value(MP42MetadataKeyTVShow, in: item), "Fixture Show")
        XCTAssertEqual(item.document?.mp4.metadata.metadataItemsFiltered(byIdentifier: MP42MetadataKeyTVSeason).first?.numberValue?.intValue, 1)
        XCTAssertEqual(value(MP42MetadataKeyAlbum, in: item), sharedAlbum)
        XCTAssertEqual(artworkData(in: item), [try XCTUnwrap(image.data)])
    }

    func testInlineEpisodePickerKeepsEpisodesEnabledAndAppliesCachedDetails() throws {
        let source = try fixtureCopy("inline-picker.E01.mp4")
        let workspace = try self.workspace(importing: [source], expectedCount: 1)
        let item = try select(0, in: workspace)
        let document = try XCTUnwrap(item.document)
        let context = try seasonContext(count: 2)
        let image = try fixtureArtwork(.green)
        // This command and the later popup action represent separate user events.
        document.undoManager?.groupsByEvent = false
        try WorkspaceSeasonOperations.assign(context: context, artworks: [image], to: [item],
                                               episodes: [item.url.path: context.episodes[0].id])
        document.undoManager?.groupsByEvent = true
        let secondID = context.episodes[1].id
        let details = try XCTUnwrap(context.metadata(for: secondID))
        details[.description] = "Cached popup episode description"
        details[.cast] = "Cached popup episode cast"
        try context.cacheDetails(details, episodeID: secondID)
        let sharedAlbum = value(MP42MetadataKeyAlbum, in: item)

        workspace.showDocument(document)
        let content = try XCTUnwrap(workspace.window?.contentView)
        let picker = try XCTUnwrap(descendants(of: content, matching: NSPopUpButton.self)
            .first { $0.accessibilityLabel() == "Season Episode" })
        let menu = try XCTUnwrap(picker.menu)
        menu.update()
        let episodes = picker.itemArray.filter { $0.representedObject is String }
        XCTAssertEqual(episodes.count, 2)
        XCTAssertTrue(picker.isEnabled)
        XCTAssertTrue(episodes.allSatisfy(\.isEnabled), "Normal menu validation must not disable episode choices")
        picker.selectItem(at: try XCTUnwrap(picker.itemArray.firstIndex { ($0.representedObject as? String) == secondID }))
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(picker.action), to: picker.target, from: picker))
        XCTAssertEqual(try sidebar(workspace).selectedRowIndexes, IndexSet(integer: 0))
        XCTAssertNil(workspace.window?.attachedSheet)
        workspace.applySelectedEpisode(picker)
        waitUntil("Cached inline episode applies without a provider request") { !workspace.isProcessing && item.episodeID == secondID }

        XCTAssertEqual(value(MP42MetadataKeyName, in: item), "Fixture Show S1 Episode 2")
        XCTAssertEqual(value(MP42MetadataKeyDescription, in: item), "Cached popup episode description")
        XCTAssertEqual(value(MP42MetadataKeyCast, in: item), "Cached popup episode cast")
        XCTAssertEqual(value(MP42MetadataKeyTVShow, in: item), "Fixture Show")
        XCTAssertEqual(document.mp4.metadata.metadataItemsFiltered(byIdentifier: MP42MetadataKeyTVSeason).first?.numberValue?.intValue, 1)
        XCTAssertEqual(value(MP42MetadataKeyAlbum, in: item), sharedAlbum)
        XCTAssertEqual(artworkData(in: item), [try XCTUnwrap(image.data)])
        XCTAssertTrue(picker.isEnabled)
        XCTAssertTrue(try sidebar(workspace).isEnabled)
    }

    func testAssignmentAndEpisodeUndoRestoreMembershipAndMetadataPerDocument() throws {
        let context = try seasonContext(count: 2)
        let first = try seasonItem("first-group.mp4")
        let second = try seasonItem("second-group.mp4")
        let image = try fixtureArtwork(.green)
        try WorkspaceSeasonOperations.assign(context: context, artworks: [image], to: [first, second], episodes: [:])
        first.document?.undoManager?.undo()
        XCTAssertNil(first.seasonContext)
        XCTAssertNil(value(MP42MetadataKeyTVShow, in: first))
        XCTAssertTrue(artworkData(in: first).isEmpty)
        XCTAssertEqual(second.seasonContext?.id, context.id)
        first.document?.undoManager?.redo()
        XCTAssertEqual(first.seasonContext?.id, context.id)
        try WorkspaceSeasonOperations.applyEpisode(context: context, episodeID: context.episodes[0].id, to: first)
        try WorkspaceSeasonOperations.applyEpisode(context: context, episodeID: context.episodes[1].id, to: first)
        first.document?.undoManager?.undo()
        XCTAssertEqual(first.episodeID, context.episodes[0].id)
        XCTAssertEqual(value(MP42MetadataKeyName, in: first), "Fixture Show S1 Episode 1")
        XCTAssertNil(second.episodeID)
        XCTAssertEqual(value(MP42MetadataKeyName, in: second), "Workspace fixture")
        XCTAssertEqual(artworkData(in: first), [try XCTUnwrap(image.data)])
    }

    func testAssignmentPreflightFailureLeavesEveryFileUnchanged() throws {
        let context = try seasonContext()
        let first = try seasonItem("preflight-first.mp4")
        let second = try seasonItem("preflight-second.mp4")
        XCTAssertThrowsError(try WorkspaceSeasonOperations.assign(context: context, artworks: [], to: [first, second],
                                                                  episodes: [second.url.path: "missing-episode"]))
        for item in [first, second] {
            XCTAssertNil(item.seasonContext)
            XCTAssertNil(value(MP42MetadataKeyTVShow, in: item))
            XCTAssertEqual(value(MP42MetadataKeyName, in: item), "Workspace fixture")
            XCTAssertFalse(try XCTUnwrap(item.document).isDocumentEdited)
        }
        let invalidImage = MP42Image(data: Data("not an image".utf8), type: MP42_ART_PNG)
        XCTAssertThrowsError(try WorkspaceSeasonOperations.assign(context: context, artworks: [invalidImage], to: [first, second], episodes: [:]))
        XCTAssertNil(first.seasonContext)
        XCTAssertNil(second.seasonContext)
        let unloaded = WorkspaceItem(url: temporaryDirectory.appendingPathComponent("unloaded.mp4"))
        XCTAssertThrowsError(try WorkspaceSeasonOperations.assign(context: context, artworks: [], to: [first, unloaded], episodes: [:]))
        XCTAssertNil(first.seasonContext)
    }

    func testMetadataSnapshotsAndCachedDetailsDoNotShareMutableResults() throws {
        let source = providerEpisode(episode: 1, description: "Original description")
        source[.releaseDate] = Date(timeIntervalSince1970: 0)
        source[.iTunesURL] = URL(string: "https://example.invalid/episode/1")!
        let snapshot = WorkspaceMetadataSnapshot(source)
        source[.name] = "Mutated provider record"
        let first = snapshot.metadata()
        XCTAssertEqual(first[.name] as? String, "Fixture Show S1 Episode 1")
        XCTAssertEqual(first[.releaseDate] as? String, "1970-01-01T00:00:00Z")
        XCTAssertEqual(first[.iTunesURL] as? String, "https://example.invalid/episode/1")
        first[.description] = "Mutated returned copy"
        XCTAssertEqual(snapshot.metadata()[.description] as? String, "Original description")
        let context = try seasonContext()
        let episodeID = context.episodes[0].id
        let details = try XCTUnwrap(context.metadata(for: episodeID))
        details[.description] = "Cached independently"
        details[.releaseDate] = Date(timeIntervalSince1970: 0)
        details[.iTunesURL] = URL(string: "https://example.invalid/episode/1")!
        try context.cacheDetails(details, episodeID: episodeID)
        details[.description] = "Changed after caching"
        let returned = try XCTUnwrap(context.metadata(for: episodeID))
        returned[.description] = "Changed after reading"
        XCTAssertEqual(context.metadata(for: episodeID)?[.description] as? String, "Cached independently")
        let decoded = try JSONDecoder().decode(WorkspaceSeasonContext.self, from: JSONEncoder().encode(context))
        XCTAssertEqual(decoded.metadata(for: episodeID)?[.description] as? String, "Cached independently")
        XCTAssertEqual(decoded.metadata(for: episodeID)?[.releaseDate] as? String, "1970-01-01T00:00:00Z")
        XCTAssertEqual(decoded.metadata(for: episodeID)?[.iTunesURL] as? String, "https://example.invalid/episode/1")
    }

    func testContextDetailsCacheLoadsSharedArtworkOnlyOnce() throws {
        let context = try seasonContext(count: 2)
        let service = WorkspaceTestMetadataService()
        let firstID = context.episodes[0].id
        let secondID = context.episodes[1].id
        _ = try loadedDetails(context, episodeID: firstID, includeArtwork: true, service: service)
        _ = try loadedDetails(context, episodeID: firstID, service: service)
        let second = try loadedDetails(context, episodeID: secondID, service: service)
        second[.description] = "Does not mutate cache"
        _ = try loadedDetails(context, episodeID: secondID, service: service)
        _ = try loadedDetails(context, episodeID: secondID, includeArtwork: true, service: service)
        XCTAssertEqual(service.fullCalls, 1)
        XCTAssertEqual(service.episodeCalls, 1)
        XCTAssertEqual(service.searchCalls, 0)
        XCTAssertFalse(context.artworkCandidates.isEmpty)
        XCTAssertNotEqual(context.metadata(for: secondID)?[.description] as? String, "Does not mutate cache")
    }

    func testCancelledDetailsLoadCannotMutateDocumentOrComplete() throws {
        let context = try seasonContext(count: 1)
        let item = try seasonItem()
        try WorkspaceSeasonOperations.assign(context: context, artworks: [], to: [item], episodes: [:])
        let entered = expectation(description: "Provider request started")
        let finishedProvider = expectation(description: "Cancelled provider request unwinds")
        let gate = DispatchSemaphore(value: 0)
        let service = WorkspaceTestMetadataService()
        service.transform = { metadata in
            entered.fulfill()
            _ = gate.wait(timeout: .now() + 5)
            finishedProvider.fulfill()
            return metadata
        }
        var completed = false
        let task = context.loadDetails(episodeID: context.episodes[0].id, service: service) { _ in completed = true }
        wait(for: [entered], timeout: 3)
        task.cancel()
        gate.signal()
        wait(for: [finishedProvider], timeout: 3)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        XCTAssertFalse(completed)
        XCTAssertNil(item.episodeID)
        XCTAssertEqual(value(MP42MetadataKeyName, in: item), "Workspace fixture")
        XCTAssertEqual(service.episodeCalls, 1)
    }

    func testProviderIdentityMismatchCannotPoisonEpisodeCache() throws {
        let context = try seasonContext(count: 1)
        let service = WorkspaceTestMetadataService()
        service.transform = { metadata in metadata[.serviceContentID] = 999; return metadata }
        XCTAssertThrowsError(try loadedDetails(context, episodeID: context.episodes[0].id, service: service))
        XCTAssertEqual(context.metadata(for: context.episodes[0].id)?[.serviceContentID] as? Int, 100)
        let item = try seasonItem()
        let other = try seasonContext(seriesID: 200)
        try WorkspaceSeasonOperations.assign(context: other, artworks: [], to: [item], episodes: [:])
        XCTAssertThrowsError(try WorkspaceSeasonOperations.applyEpisode(context: context, episodeID: context.episodes[0].id, to: item))
        XCTAssertEqual(item.seasonContext?.id, other.id)
        XCTAssertEqual(value(MP42MetadataKeyName, in: item), "Workspace fixture")
    }

    func testChangedOrMissingProviderEpisodeIdentityCannotPoisonCache() throws {
        for removeIdentity in [false, true] {
            let context = try seasonContext(count: 1)
            let id = context.episodes[0].id
            let originalIdentity = context.metadata(for: id)?[.serviceEpisodeID] as? Int
            let service = WorkspaceTestMetadataService()
            service.transform = { metadata in
                metadata[.serviceEpisodeID] = removeIdentity ? nil : 999999
                return metadata
            }
            XCTAssertThrowsError(try loadedDetails(context, episodeID: id, service: service))
            XCTAssertEqual(context.metadata(for: id)?[.serviceEpisodeID] as? Int, originalIdentity)
        }
    }

    func testSavedSeasonContextAndMembershipRoundTripWithFileReferences() throws {
        let source = try fixtureCopy("saved-season.E01.mp4")
        let workspace = try self.workspace(importing: [source], expectedCount: 1)
        let item = try select(0, in: workspace)
        // This synchronous XCTest invocation has no native AppKit event boundary.
        let undo = try XCTUnwrap(item.document?.undoManager)
        undo.groupsByEvent = false
        let context = try seasonContext(providerName: TheTVDB().name)
        let image = try fixtureArtwork(.blue)
        try WorkspaceSeasonOperations.assign(context: context, artworks: [image], to: [item],
                                               episodes: [item.url.path: context.episodes[0].id])
        undo.groupsByEvent = true
        waitUntil("Assigned season is marked modified") { item.document?.isDocumentEdited == true }
        workspace.persistCollection()
        let unsavedReferences = try XCTUnwrap(UserDefaults.standard.array(forKey: "UnifiedWorkspaceCollection") as? [[String: Any]])
        XCTAssertNil(unsavedReferences.first?["seasonContextID"])
        workspace.saveAllModified(nil)
        waitUntil("Assigned season saves", timeout: 60) { !workspace.isProcessing }
        XCTAssertNil(item.error)
        XCTAssertEqual(item.savedSeasonContext?.id, context.id)
        let replacement = try seasonContext(season: 2, providerName: TheTVDB().name)
        undo.groupsByEvent = false
        try WorkspaceSeasonOperations.assign(context: replacement, artworks: [try fixtureArtwork(.green)], to: [item],
                                               episodes: [item.url.path: replacement.episodes[1].id])
        undo.groupsByEvent = true
        XCTAssertEqual(item.seasonContext?.id, replacement.id)
        try XCTUnwrap(item.document).revert(toContentsOf: item.url, ofType: "Movie-MPEG4")
        XCTAssertEqual(item.seasonContext?.id, context.id)
        XCTAssertEqual(item.episodeID, context.episodes[0].id)
        XCTAssertEqual(value(MP42MetadataKeyName, in: item), "Fixture Show S1 Episode 1")
        XCTAssertEqual(artworkData(in: item), [try XCTUnwrap(image.data)])
        XCTAssertFalse(try XCTUnwrap(item.document).isDocumentEdited)
        XCTAssertFalse(item.document?.undoManager?.canUndo ?? true)
        workspace.persistCollection()
        let references = try XCTUnwrap(UserDefaults.standard.array(forKey: "UnifiedWorkspaceCollection") as? [[String: Any]])
        let contextsData = try XCTUnwrap(UserDefaults.standard.data(forKey: "UnifiedWorkspaceSeasonContextsV1"))
        XCTAssertEqual(references.first?["seasonContextID"] as? String, context.id)
        item.document?.close()
        workspace.window?.close()
        UserDefaults.standard.set(references, forKey: "UnifiedWorkspaceCollection")
        UserDefaults.standard.set(contextsData, forKey: "UnifiedWorkspaceSeasonContextsV1")
        let restored = WorkspaceWindowController()
        workspaces.append(restored)
        restored.restoreCollection()
        waitUntil("Saved context collection restores") { !restored.isImporting && restored.entries.count == 1 }
        let restoredItem = try select(0, in: restored)
        XCTAssertEqual(restoredItem.seasonContext?.id, context.id)
        XCTAssertEqual(restoredItem.episodeID, context.episodes[0].id)
        XCTAssertFalse(try XCTUnwrap(restoredItem.document).isDocumentEdited)
        XCTAssertEqual(artworkData(in: restoredItem), [try XCTUnwrap(image.data)])
        XCTAssertEqual(value(MP42MetadataKeyName, in: restoredItem), "Fixture Show S1 Episode 1")
    }

    func testMalformedContextAndLegacyFileReferencesRemainOpenable() throws {
        let source = try fixtureCopy("legacy-context.mp4")
        UserDefaults.standard.set(Data("invalid context json".utf8), forKey: "UnifiedWorkspaceSeasonContextsV1")
        UserDefaults.standard.set([["path": source.path], ["unknown": "ignored"]], forKey: "UnifiedWorkspaceCollection")
        let restored = WorkspaceWindowController()
        workspaces.append(restored)
        restored.restoreCollection()
        waitUntil("Legacy collection without context restores") { !restored.isImporting && restored.entries.count == 1 }
        let item = try select(0, in: restored)
        XCTAssertNil(item.seasonContext)
        XCTAssertNil(item.episodeID)
        XCTAssertNotNil(item.document)
        XCTAssertNil(item.error)
        XCTAssertFalse(try XCTUnwrap(item.document).isDocumentEdited)
    }

}


/// Offline provider with synchronized counters and a controllable delayed result.
private final class WorkspaceTestMetadataService: MetadataService {
    let languageType: LanguageType = .ISO
    let languages = ["en"]
    let defaultLanguage = "en"
    let name = "Workspace Fixture Provider"
    private let lock = NSLock()
    private var fullCount = 0
    private var episodeCount = 0
    private var searchCount = 0
    var transform: ((MetadataResult) -> MetadataResult)?
    var fullCalls: Int { lock.lock(); defer { lock.unlock() }; return fullCount }
    var episodeCalls: Int { lock.lock(); defer { lock.unlock() }; return episodeCount }
    var searchCalls: Int { lock.lock(); defer { lock.unlock() }; return searchCount }

    func search(tvShow: String, language: String) -> [String] { [] }
    func search(tvShow: String, language: String, season: Int?, episode: Int?) -> [MetadataResult] {
        lock.lock(); searchCount += 1; lock.unlock()
        return []
    }
    func search(movie: String, language: String) -> [MetadataResult] { [] }
    func loadMovieMetadata(_ metadata: MetadataResult, language: String) -> MetadataResult { metadata }
    func loadTVMetadata(_ metadata: MetadataResult, language: String) -> MetadataResult {
        lock.lock(); fullCount += 1; lock.unlock()
        let copy = WorkspaceMetadataSnapshot(metadata).metadata()
        let url = URL(string: "https://example.invalid/season-artwork.jpg")!
        copy.remoteArtworks = [Artwork(url: url, thumbURL: url, service: name, type: .season, size: .standard)]
        return transform?(copy) ?? copy
    }
    func loadTVEpisodeMetadata(_ metadata: MetadataResult, language: String) -> MetadataResult {
        lock.lock(); episodeCount += 1; lock.unlock()
        let copy = WorkspaceMetadataSnapshot(metadata).metadata()
        return transform?(copy) ?? copy
    }
}
