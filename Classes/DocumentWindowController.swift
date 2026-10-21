//
//  DocumentWindowController.swift
//  Subler
//
//  Traditional document presentation. The editor is also used by Unified Workspace.
//

import Cocoa

final class DocumentWindowController: NSWindowController, NSWindowDelegate, NSDraggingDestination {

    private let toolbarDelegate = DocumentToolbarDelegate()
    private(set) var editor: DocumentEditorViewController!

    override var windowNibName: NSNib.Name? { return "DocumentWindowController" }

    init() { super.init(window: nil) }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func windowDidLoad() {
        super.windowDidLoad()
        guard let window = window, let document = document as? Document else { return }
        editor = DocumentEditorViewController(document: document)
        window.contentViewController = editor
        toolbarDelegate.target = editor
        let toolbar = NSToolbar(identifier: "SublerDocumentToolbar")
        toolbar.delegate = toolbarDelegate
        toolbar.allowsUserCustomization = true
        toolbar.autosavesConfiguration = true
        if #available(macOS 26, *) { toolbar.displayMode = .iconOnly }
        else { toolbar.displayMode = .iconAndLabel }
        window.toolbar = toolbar
        if #available(macOS 11, *) { window.toolbarStyle = .expanded }
        window.registerForDraggedTypes([.fileURL])
        if Prefs.rememberDocumentWindowSize {
            window.setFrameAutosaveName("documentSave")
            window.setFrameUsingName("documentSave")
        } else {
            window.setContentSize(NSSize(width: 692, height: 600))
        }
        editor.restoreSplitView(rememberSize: Prefs.rememberDocumentWindowSize)
    }

    override func supplementalTarget(forAction action: Selector, sender: Any?) -> Any? {
        if let editor = editor, editor.responds(to: action) { return editor }
        return super.supplementalTarget(forAction: action, sender: sender)
    }

    func showImportSheet(fileURLs: [URL]) { editor.showImportSheet(fileURLs: fileURLs) }

    func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { return editor.draggingEntered(sender) }
    func performDragOperation(_ sender: NSDraggingInfo) -> Bool { return editor.performDragOperation(sender) }
    override func keyDown(with event: NSEvent) {
        if editor?.handleNavigation(with: event) != true { super.keyDown(with: event) }
    }
}
