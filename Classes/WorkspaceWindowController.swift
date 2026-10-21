// Optional collection presentation for existing Subler documents.

import Cocoa
import MP42Foundation

final class WorkspaceItem {
    var url: URL
    let searchTerms: MetadataSearchTerms
    var document: Document?
    var editor: DocumentEditorViewController?
    var error: String?
    var status = "Not loaded"
    var mediaInfo = ""
    var isLoading = false
    var modificationDate: Date?
    var fileSize: Int?
    private(set) var seasonContext: WorkspaceSeasonContext?
    private(set) var episodeID: String?
    var savedSeasonContext: WorkspaceSeasonContext?
    var savedEpisodeID: String?

    func setSeasonContext(_ context: WorkspaceSeasonContext?, episodeID: String?) {
        guard seasonContext?.id != context?.id || self.episodeID != episodeID else { return }
        let previousContext = seasonContext
        let previousEpisode = self.episodeID
        document?.undoManager?.registerUndo(withTarget: self) { item in
            item.setSeasonContext(previousContext, episodeID: previousEpisode)
        }
        seasonContext = context
        self.episodeID = episodeID
    }

    func restoreSavedSeasonContext() {
        seasonContext = savedSeasonContext
        episodeID = savedEpisodeID
    }

    init(url: URL, searchTerms: MetadataSearchTerms = .none) {
        self.url = url
        self.searchTerms = searchTerms
    }

    var detail: String {
        let state = error.map { "Error: \($0)" } ?? (isLoading || status == "Saving…" ? status : (document?.isDocumentEdited == true ? "Modified" : status))
        if let context = seasonContext {
            let episode = context.episodes.first { $0.id == episodeID }
            let name = episode.map { "E\($0.number) · \($0.title)" } ?? "Choose episode"
            return "\(state) · \(context.seriesName) · S\(context.season) · \(name)"
        }
        if case let .tvShow(series, season, episode) = searchTerms {
            let number = [season.map { "S\($0)" }, episode.map { "E\($0)" }].compactMap { $0 }.joined()
            return "\(series) \(number) · \(state)"
        }
        return mediaInfo.isEmpty ? state : "\(mediaInfo) · \(state)"
    }
}

final class WorkspaceWindowController: NSWindowController, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate, NSToolbarDelegate, NSUserInterfaceValidations {
    private(set) var entries: [WorkspaceItem] = []
    private var visibleEntries: [WorkspaceItem] = []
    private let table = NSTableView()
    private let documentToolbarDelegate = DocumentToolbarDelegate()
    private let search = NSSearchField()
    private let statusLabel = NSTextField(labelWithString: "Add media files or a season folder to begin.")
    private let editorHost = NSViewController()
    private let episodeBar = NSStackView()
    private let seasonLabel = NSTextField(labelWithString: "")
    private let episodePicker = NSPopUpButton(frame: .zero, pullsDown: false)
    private lazy var applyEpisodeButton = NSButton(title: "Apply Episode", target: self, action: #selector(applySelectedEpisode(_:)))
    private lazy var cancelEpisodeButton = NSButton(title: "Cancel Lookup", target: self, action: #selector(cancelEpisodeLookup(_:)))
    private var episodeTask: Runnable?
    private var episodeGeneration = UUID()
    private var displayedSeasonID: String?
    private var displayedEpisodeID: String?
    private var restoredAssignments: [String: (WorkspaceSeasonContext, String?)] = [:]
    private static let contextsKey = "UnifiedWorkspaceSeasonContextsV1"
    private let root = NSViewController()
    private let placeholder = NSTextField(wrappingLabelWithString: "Add media files or a season folder, then select an episode to edit.")
    private let importQueue = DispatchQueue(label: "org.subler.workspace.loading", qos: .userInitiated)
    private var activeItem: WorkspaceItem?
    private var changeObservers: [NSObjectProtocol] = []
    private(set) var isProcessing = false
    private(set) var isImporting = false
    private var alphabetical = false
    private var isUpdatingSidebar = false
    private weak var savingDocument: Document?
    private var externalSave = false
    private var seasonLookupRequested = false
    private var pendingClose: [WorkspaceItem] = []
    private var closingWindow = false
    private var allowWindowClose = false
    private var restoredSelection: String?
    private var pendingLoads: [ObjectIdentifier: [() -> Void]] = [:]
    private static let collectionKey = "UnifiedWorkspaceCollection"

    var activeDocument: Document? { return activeItem?.document }

    init() {
        let window = WorkspaceWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 760),
                                     styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        super.init(window: window)
        window.workspace = self
        window.title = NSLocalizedString("Unified Workspace", comment: "Workspace window")
        window.minSize = NSSize(width: 920, height: 600)
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("UnifiedWorkspaceWindow")
        window.center()
        buildInterface()
        for name in [Notification.Name.NSUndoManagerDidCloseUndoGroup, .NSUndoManagerDidUndoChange, .NSUndoManagerDidRedoChange] {
            changeObservers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.refreshStatus()
            })
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { for observer in changeObservers { NotificationCenter.default.removeObserver(observer) } }

    private func buildInterface() {
        root.view = NSView(frame: NSRect(x: 0, y: 0, width: 1100, height: 760))
        window?.contentViewController = root
        let split = NSSplitViewController()
        root.addChild(split)
        split.view.translatesAutoresizingMaskIntoConstraints = false
        root.view.addSubview(split.view)
        statusLabel.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingMiddle
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        root.view.addSubview(statusLabel)
        NSLayoutConstraint.activate([
            split.view.topAnchor.constraint(equalTo: root.view.topAnchor),
            split.view.leadingAnchor.constraint(equalTo: root.view.leadingAnchor),
            split.view.trailingAnchor.constraint(equalTo: root.view.trailingAnchor),
            split.view.bottomAnchor.constraint(equalTo: statusLabel.topAnchor, constant: -8),
            statusLabel.leadingAnchor.constraint(equalTo: root.view.leadingAnchor, constant: 12),
            statusLabel.trailingAnchor.constraint(equalTo: root.view.trailingAnchor, constant: -12),
            statusLabel.bottomAnchor.constraint(equalTo: root.view.bottomAnchor, constant: -8)
        ])
        let sidebar = NSViewController()
        sidebar.view = NSView()
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        sidebar.view.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: sidebar.view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: sidebar.view.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: sidebar.view.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: sidebar.view.bottomAnchor)
        ])
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("Media"))
        column.title = "Media"
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 54
        table.allowsMultipleSelection = true
        table.allowsEmptySelection = true
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.dataSource = self
        table.delegate = self
        if #available(macOS 11, *) { table.style = .sourceList }
        table.setAccessibilityLabel("Workspace Media")
        table.registerForDraggedTypes([.fileURL])
        scroll.documentView = table
        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        sidebarItem.minimumThickness = 240
        sidebarItem.maximumThickness = 420
        sidebarItem.canCollapse = false
        split.addSplitViewItem(sidebarItem)
        editorHost.view = NSView()
        split.addSplitViewItem(NSSplitViewItem(viewController: editorHost))
        seasonLabel.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        seasonLabel.lineBreakMode = .byTruncatingMiddle
        episodePicker.setAccessibilityLabel("Season Episode")
        episodePicker.menu?.autoenablesItems = false
        episodePicker.target = self
        episodePicker.action = #selector(episodeChoiceChanged(_:))
        let episodeRow = NSStackView(views: [episodePicker, applyEpisodeButton, cancelEpisodeButton])
        episodeRow.orientation = .horizontal
        episodeRow.spacing = 8
        episodeBar.orientation = .vertical
        episodeBar.alignment = .leading
        episodeBar.spacing = 6
        episodeBar.addArrangedSubview(seasonLabel)
        episodeBar.addArrangedSubview(episodeRow)
        episodeBar.translatesAutoresizingMaskIntoConstraints = false
        editorHost.view.addSubview(episodeBar)
        NSLayoutConstraint.activate([
            episodeBar.leadingAnchor.constraint(equalTo: editorHost.view.leadingAnchor, constant: 12),
            episodeBar.trailingAnchor.constraint(equalTo: editorHost.view.trailingAnchor, constant: -12),
            episodeBar.topAnchor.constraint(equalTo: editorHost.view.topAnchor, constant: 10),
            episodePicker.widthAnchor.constraint(greaterThanOrEqualToConstant: 260)
        ])
        episodeBar.isHidden = true
        cancelEpisodeButton.isHidden = true
        placeholder.textColor = .secondaryLabelColor
        placeholder.alignment = .center
        placeholder.translatesAutoresizingMaskIntoConstraints = false
        editorHost.view.addSubview(placeholder)
        NSLayoutConstraint.activate([
            placeholder.centerXAnchor.constraint(equalTo: editorHost.view.centerXAnchor),
            placeholder.centerYAnchor.constraint(equalTo: editorHost.view.centerYAnchor),
            placeholder.widthAnchor.constraint(lessThanOrEqualTo: editorHost.view.widthAnchor, constant: -60)
        ])
        search.placeholderString = NSLocalizedString("Search files", comment: "Workspace")
        search.delegate = self
        search.sendsSearchStringImmediately = true
        search.setAccessibilityLabel("Search Workspace")
        let toolbar = NSToolbar(identifier: "UnifiedWorkspaceToolbar")
        toolbar.delegate = self
        documentToolbarDelegate.target = nil
        toolbar.allowsUserCustomization = true
        toolbar.displayMode = .iconAndLabel
        window?.toolbar = toolbar
        if #available(macOS 11, *) { window?.toolbarStyle = .expanded }
        refreshStatus()
    }

    // Files are catalogued off the main thread. Models and editors load only on first selection.
    func importURLs(_ urls: [URL]) {
        guard !isProcessing, !isImporting else { return }
        isImporting = true
        statusLabel.stringValue = "Reading collection…"
        importQueue.async { [weak self] in
            var files: [URL] = []
            for url in urls {
                var directory: ObjCBool = false
                if FileManager.default.fileExists(atPath: url.path, isDirectory: &directory), directory.boolValue {
                    if let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles, .skipsPackageDescendants]) {
                        for case let file as URL in enumerator where Self.supports(file) { files.append(file) }
                    }
                } else { files.append(url) }
            }
            let items = files.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }.map {
                WorkspaceItem(url: Self.canonicalURL($0), searchTerms: $0.lastPathComponent.parsedAsFilename())
            }
            DispatchQueue.main.async {
                guard let self = self else { return }
                for item in items where !self.entries.contains(where: { Self.sameFile($0.url, item.url) }) {
                    if !Self.supports(item.url) { item.error = "Use an MP4, M4V, M4A or M4B file. Other formats can be imported in a traditional document window." }
                    if let (context, episodeID) = self.restoredAssignments.removeValue(forKey: item.url.path) {
                        item.setSeasonContext(context, episodeID: episodeID)
                        item.savedSeasonContext = context
                        item.savedEpisodeID = episodeID
                    }
                    self.entries.append(item)
                }
                self.isImporting = false
                self.rebuildList()
                self.persistCollection()
                if self.table.selectedRow < 0, !self.visibleEntries.isEmpty {
                    let index = self.visibleEntries.firstIndex { $0.url.path == self.restoredSelection } ?? 0
                    self.table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
                    self.restoredSelection = nil
                }
            }
        }
    }

    static func supports(_ url: URL) -> Bool { return ["mp4", "m4v", "m4a", "m4b"].contains(url.pathExtension.lowercased()) }
    static func canonicalURL(_ url: URL) -> URL { return url.resolvingSymlinksInPath().standardizedFileURL }
    static func sameFile(_ lhs: URL, _ rhs: URL) -> Bool {
        if canonicalURL(lhs) == canonicalURL(rhs) { return true }
        let a = try? lhs.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier
        let b = try? rhs.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier
        if let a = a as? NSObject, let b = b as? NSObject { return a.isEqual(b) }
        return false
    }

    private var selectedItems: [WorkspaceItem] { return table.selectedRowIndexes.compactMap { visibleEntries.indices.contains($0) ? visibleEntries[$0] : nil } }

    func showDocument(_ document: Document) {
        showWindow(self)
        window?.makeKeyAndOrderFront(self)
        guard !isProcessing, !isImporting, window?.attachedSheet == nil, commitEditing() else { return }
        if let item = entries.first(where: { $0.document === document }) {
            search.stringValue = ""
            rebuildList()
            if let index = visibleEntries.firstIndex(where: { $0 === item }) { table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false) }
        }
        window?.makeKeyAndOrderFront(self)
    }

    private func load(_ item: WorkspaceItem, completion: @escaping () -> Void) {
        if item.document != nil || item.error != nil { completion(); return }
        let loadKey = ObjectIdentifier(item)
        if item.isLoading { pendingLoads[loadKey, default: []].append(completion); return }
        if let existing = NSDocumentController.shared.documents.first(where: { $0.fileURL.map { Self.sameFile($0, item.url) } == true }) as? Document {
            if existing.workspaceWindowController === self { item.document = existing; completion(); return }
            item.error = "This file is already open in a document window. Close that document before adding it to the workspace."
            completion(); return
        }
        pendingLoads[loadKey] = [completion]
        item.isLoading = true
        item.status = "Loading…"
        refreshStatus()
        importQueue.async { [weak self, weak item] in
            guard let item = item else { return }
            let result = Result { try MP42File(url: item.url) }
            item.url.removeAllCachedResourceValues()
            let values = try? item.url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            DispatchQueue.main.async {
                guard let self = self else { return }
                guard self.entries.contains(where: { $0 === item }) else { self.pendingLoads.removeValue(forKey: loadKey); return }
                item.isLoading = false
                switch result {
                case .success(let file):
                    if NSDocumentController.shared.documents.contains(where: { $0.fileURL.map { Self.sameFile($0, item.url) } == true }) {
                        item.error = "This file was opened in another document while loading. Close that document and add it again."
                        break
                    }
                    let document = Document(mp4: file)
                    document.fileURL = item.url
                    document.fileType = (try? NSDocumentController.shared.typeForContents(of: item.url)) ?? "Movie-MPEG4"
                    document.fileModificationDate = values?.contentModificationDate
                    document.workspaceWindowController = self
                    item.document = document
                    item.modificationDate = values?.contentModificationDate
                    item.fileSize = values?.fileSize
                    item.status = "Ready"
                    item.mediaInfo = "\(file.tracks.count) tracks · \(file.duration / 1000)s"
                    NSDocumentController.shared.addDocument(document)
                case .failure(let error): item.error = error.localizedDescription
                }
                self.refreshStatus()
                let completions = self.pendingLoads.removeValue(forKey: loadKey) ?? []
                completions.forEach { $0() }
            }
        }
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !isProcessing, !isUpdatingSidebar else { return }
        showSelection()
        persistCollection()
    }

    private func showSelection() {
        detachEditor()
        activeItem = selectedItems.count == 1 ? selectedItems.first : nil
        guard let item = activeItem else {
            placeholder.stringValue = selectedItems.isEmpty ? "Select a file to edit. Drop files or folders in the sidebar." : "\(selectedItems.count) files selected. Use Look Up Season to assign a show, season and shared artwork."
            refreshStatus(); return
        }
        placeholder.stringValue = item.error ?? "Loading \(item.url.lastPathComponent)…"
        load(item) { [weak self, weak item] in
            guard let self = self, let item = item, self.activeItem === item, !self.isProcessing else { return }
            if let document = item.document {
                let editor = item.editor ?? DocumentEditorViewController(document: document)
                item.editor = editor
                // Several selection requests may finish after the same lazy load.
                if editor.parent === self.editorHost { self.refreshStatus(); return }
                self.detachEditor()
                self.editorHost.addChild(editor)
                let headerHeight = self.configureEpisodeBar(for: item)
                var editorFrame = self.editorHost.view.bounds
                editorFrame.size.height = max(0, editorFrame.height - headerHeight)
                editor.view.frame = editorFrame
                editor.view.autoresizingMask = [.width, .height]
                self.editorHost.view.addSubview(editor.view)
                self.placeholder.isHidden = true
                self.window?.representedURL = item.url
            } else { self.placeholder.stringValue = item.error ?? "Loading…" }
            self.refreshStatus()
        }
    }

    private func detachEditor() {
        if let editor = editorHost.children.first {
            editor.view.removeFromSuperview()
            editor.removeFromParent()
        }
        placeholder.isHidden = false
        episodeBar.isHidden = true
        window?.representedURL = nil
    }

    private func configureEpisodeBar(for item: WorkspaceItem) -> CGFloat {
        displayedSeasonID = item.seasonContext?.id
        displayedEpisodeID = item.episodeID
        guard let context = item.seasonContext else { episodeBar.isHidden = true; return 0 }
        episodeBar.isHidden = false
        cancelEpisodeButton.isHidden = true
        seasonLabel.stringValue = "\(context.seriesName) · Season \(context.season) · \(context.providerName)"
        seasonLabel.toolTip = "Episode details use this assigned season. Artwork and shared metadata are preserved."
        episodePicker.removeAllItems()
        episodePicker.addItem(withTitle: "Choose an episode…")
        for episode in context.episodes {
            episodePicker.addItem(withTitle: String(format: "E%02d · %@", episode.number, episode.title))
            episodePicker.lastItem?.representedObject = episode.id
        }
        let choice = item.episodeID ?? context.episode(matchingFilename: item.url)?.id
        if let index = episodePicker.itemArray.firstIndex(where: { ($0.representedObject as? String) == choice && choice != nil }) { episodePicker.selectItem(at: index) }
        applyEpisodeButton.isEnabled = episodePicker.selectedItem?.representedObject is String
        return 78
    }

    @objc private func episodeChoiceChanged(_ sender: Any?) {
        applyEpisodeButton.isEnabled = !isProcessing && episodePicker.selectedItem?.representedObject is String
    }

    @IBAction func applySelectedEpisode(_ sender: Any?) {
        guard !isProcessing, !isImporting, window?.attachedSheet == nil, commitEditing(),
              let item = activeItem, let context = item.seasonContext,
              let episodeID = episodePicker.selectedItem?.representedObject as? String else { return }
        isProcessing = true
        table.isEnabled = false
        search.isEnabled = false
        applyEpisodeButton.isEnabled = false
        episodePicker.isEnabled = false
        cancelEpisodeButton.isHidden = false
        item.editor?.view.isHidden = true
        placeholder.isHidden = false
        placeholder.stringValue = "Loading episode details…"
        episodeGeneration = UUID()
        let token = episodeGeneration
        let task = context.loadDetails(episodeID: episodeID) { [weak self, weak item] result in
            guard let self = self, self.episodeGeneration == token else { return }
            guard let item = item, self.entries.contains(where: { $0 === item }), self.activeItem === item else { self.finishEpisodeLookup(); return }
            var errorMessage: String?
            do {
                _ = try result.get()
                try WorkspaceSeasonOperations.applyEpisode(context: context, episodeID: episodeID, to: item)
            } catch { errorMessage = error.localizedDescription }
            self.finishEpisodeLookup()
            if let message = errorMessage { self.statusLabel.stringValue = message }
            else { self.statusLabel.stringValue = "Episode metadata applied to \(item.url.lastPathComponent). Save to write the file." }
        }
        if isProcessing { episodeTask = task }
    }

    @objc private func cancelEpisodeLookup(_ sender: Any?) {
        episodeGeneration = UUID()
        episodeTask?.cancel()
        finishEpisodeLookup()
        statusLabel.stringValue = "Episode lookup cancelled. No episode changes were applied."
    }

    private func finishEpisodeLookup() {
        episodeTask = nil
        isProcessing = false
        table.isEnabled = true
        search.isEnabled = true
        episodePicker.isEnabled = true
        activeItem?.editor?.view.isHidden = false
        showSelection()
        refreshStatus()
    }

    private func commitEditing() -> Bool {
        // Sidebar keyboard navigation must retain its first responder between arrows.
        if window?.firstResponder === table { return true }
        return window?.makeFirstResponder(nil) != false
    }

    func tableView(_ tableView: NSTableView, selectionIndexesForProposedSelection proposedSelectionIndexes: IndexSet) -> IndexSet {
        if isUpdatingSidebar { return proposedSelectionIndexes }
        guard !isProcessing, window?.attachedSheet == nil, commitEditing() else { return tableView.selectedRowIndexes }
        window?.makeFirstResponder(tableView)
        return proposedSelectionIndexes
    }

    func numberOfRows(in tableView: NSTableView) -> Int { return visibleEntries.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let item = visibleEntries[row]
        let cell = NSTableCellView()
        let title = NSTextField(labelWithString: item.url.lastPathComponent)
        title.font = NSFont.systemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        title.lineBreakMode = .byTruncatingMiddle
        let detail = NSTextField(labelWithString: item.detail)
        detail.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        detail.textColor = item.error == nil ? .secondaryLabelColor : .systemRed
        detail.lineBreakMode = .byTruncatingTail
        let stack = NSStackView(views: [title, detail])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(stack)
        cell.textField = title
        cell.toolTip = item.url.path + "\n" + item.detail
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
            stack.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
        ])
        return cell
    }

    func controlTextDidChange(_ obj: Notification) {
        guard !isProcessing, window?.attachedSheet == nil else { return }
        rebuildList()
    }
    private func rebuildList() {
        let selection = selectedItems
        visibleEntries = entries.filter { search.stringValue.isEmpty || ($0.url.lastPathComponent + " " + $0.detail).localizedCaseInsensitiveContains(search.stringValue) }
        if alphabetical { visibleEntries.sort { $0.url.lastPathComponent.localizedStandardCompare($1.url.lastPathComponent) == .orderedAscending } }
        reloadSidebar(selecting: IndexSet(visibleEntries.indices.filter { i in selection.contains { $0 === visibleEntries[i] } }), rowsOnly: false)
        showSelection()
        refreshStatus()
    }

    private func reloadSidebar(selecting indexes: IndexSet? = nil, rowsOnly: Bool = true) {
        let selection = indexes ?? table.selectedRowIndexes
        isUpdatingSidebar = true
        if rowsOnly {
            table.reloadData(forRowIndexes: IndexSet(integersIn: 0..<visibleEntries.count), columnIndexes: IndexSet(integer: 0))
        } else { table.reloadData() }
        table.selectRowIndexes(selection, byExtendingSelection: false)
        isUpdatingSidebar = false
    }

    private func refreshStatus() {
        if !isProcessing, let item = activeItem, let editor = item.editor, editor.parent === editorHost,
           displayedSeasonID != item.seasonContext?.id || displayedEpisodeID != item.episodeID {
            let height = configureEpisodeBar(for: item)
            var frame = editorHost.view.bounds
            frame.size.height = max(0, frame.height - height)
            editor.view.frame = frame
        }
        reloadSidebar()
        let modified = entries.filter { $0.document?.isDocumentEdited == true }.count
        let errors = entries.filter { $0.error != nil }.count
        if !isProcessing && !isImporting { statusLabel.stringValue = "\(entries.count) files · \(modified) modified · \(errors) errors" }
        window?.isDocumentEdited = modified > 0
        window?.toolbar?.validateVisibleItems()
    }

    // Native Save As, Optimize and close-prompt saves must participate in the same lock.
    func prepareToSave(_ document: Document, to url: URL, operation: NSDocument.SaveOperationType) -> Error? {
        func error(_ message: String) -> NSError { return NSError(domain: "Workspace", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
        guard let item = entries.first(where: { $0.document === document }) else { return error("This document is no longer in the workspace.") }
        if isProcessing && savingDocument !== document { return error("Wait for the current workspace operation to finish.") }
        if NSDocumentController.shared.documents.contains(where: { $0 !== document && $0.fileURL.map { Self.sameFile($0, url) } == true }) || entries.contains(where: { $0 !== item && Self.sameFile($0.url, url) }) {
            return error("The destination belongs to another open document or workspace item. Choose a different destination.")
        }
        let queue = QueueController.shared
        if queue.items(at: IndexSet(integersIn: 0..<queue.count)).contains(where: {
            [.ready, .working, .editing].contains($0.status) && (Self.sameFile($0.destURL, url) || Self.sameFile($0.fileURL, url))
        }) { return error("This file is also pending in the processing queue. Remove or finish that queue item before saving in the workspace.") }
        if operation == .saveOperation {
            do {
                item.url.removeAllCachedResourceValues()
                let values = try item.url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
                if !FileManager.default.isWritableFile(atPath: item.url.path) { return NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError) }
                if values.contentModificationDate != item.modificationDate || values.fileSize != item.fileSize {
                    return error("This file changed on disk after it was loaded. Your edits are preserved. Reopen or revert it before saving.")
                }
            } catch { return error }
        }
        if !isProcessing {
            externalSave = true
            isProcessing = true
            table.isEnabled = false
            search.isEnabled = false
            detachEditor()
            placeholder.stringValue = "Saving \(item.url.lastPathComponent)…"
        }
        savingDocument = document
        return nil
    }

    func didFinishSaving(_ document: Document, error: Error?) {
        if let item = entries.first(where: { $0.document === document }) {
            if let error = error { item.error = error.localizedDescription; item.status = "Save failed" }
            else {
                updateFileSnapshot(item); item.error = nil; item.status = "Saved"
                item.savedSeasonContext = item.seasonContext
                item.savedEpisodeID = item.episodeID
            }
        }
        savingDocument = nil
        if externalSave {
            externalSave = false
            isProcessing = false
            table.isEnabled = true
            search.isEnabled = true
            showSelection()
            persistCollection()
        }
        refreshStatus()
    }

    private func updateFileSnapshot(_ item: WorkspaceItem) {
        item.url = item.document?.fileURL ?? item.url
        item.url.removeAllCachedResourceValues()
        let values = try? item.url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        item.modificationDate = values?.contentModificationDate
        item.fileSize = values?.fileSize
    }

    func didRevert(_ document: Document) {
        guard let item = entries.first(where: { $0.document === document }) else { return }
        updateFileSnapshot(item)
        item.error = nil
        item.status = "Ready"
        item.restoreSavedSeasonContext()
        refreshStatus()
    }

    // Save through NSDocument, serially; never hand workspace-owned models to the processing queue.
    @IBAction func saveSelected(_ sender: Any?) { saveItems(selectedItems) }
    @IBAction func saveAllModified(_ sender: Any?) { saveItems(entries) }
    @IBAction func saveDocument(_ sender: Any?) { saveSelected(sender) }

    private func saveItems(_ items: [WorkspaceItem]) {
        guard !isProcessing, !isImporting, window?.attachedSheet == nil, commitEditing() else { return }
        let modified = items.filter { $0.document?.isDocumentEdited == true }
        guard !modified.isEmpty else { return }
        isProcessing = true
        table.isEnabled = false
        search.isEnabled = false
        detachEditor()
        placeholder.stringValue = "Saving modified files…"
        saveNext(modified, completed: 0, failures: 0)
    }

    private func saveNext(_ remaining: [WorkspaceItem], completed: Int, failures: Int) {
        guard let item = remaining.first, let document = item.document else {
            isProcessing = false
            table.isEnabled = true
            search.isEnabled = true
            showSelection()
            statusLabel.stringValue = "Saved \(completed - failures) files · \(failures) failed" + (failures > 0 ? " — select a file to review its error and retry." : "")
            persistCollection()
            return
        }
        statusLabel.stringValue = "Saving \(completed + 1) of \(completed + remaining.count): \(item.url.lastPathComponent)"
        item.status = "Saving…"
        item.error = nil
        let continuation: (Error?) -> Void = { [weak self] error in
            guard let self = self else { return }
            if let error = error { item.error = error.localizedDescription; item.status = "Save failed" }
            else {
                item.status = "Saved"
                item.url = document.fileURL ?? item.url
                item.url.removeAllCachedResourceValues()
            let values = try? item.url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
                item.modificationDate = values?.contentModificationDate
                item.fileSize = values?.fileSize
            }
            self.refreshStatus()
            self.saveNext(Array(remaining.dropFirst()), completed: completed + 1, failures: failures + (error == nil ? 0 : 1))
        }
        savingDocument = document
        document.save(to: item.url, ofType: document.fileType ?? "Movie-MPEG4", for: .saveOperation, completionHandler: continuation)
    }

    @IBAction func addFiles(_ sender: Any?) {
        guard let window = window, !isProcessing, !isImporting else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Add to Workspace"
        panel.beginSheetModal(for: window) { [weak self] response in
            if response == .OK { self?.importURLs(panel.urls) }
        }
    }
    @IBAction func sortFiles(_ sender: Any?) {
        guard !isProcessing, !isImporting, window?.attachedSheet == nil, commitEditing() else { return }
        alphabetical.toggle(); rebuildList(); persistCollection()
    }
    @IBAction func batchEdit(_ sender: Any?) {
        guard !isProcessing, !isImporting, window?.attachedSheet == nil, commitEditing() else { return }
        seasonLookupRequested = false
        let items = selectedItems
        guard items.count > 1 else { return }
        isProcessing = true
        table.isEnabled = false
        loadForBatch(items, remaining: items)
    }
    @IBAction func lookupSeason(_ sender: Any?) {
        guard !isProcessing, !isImporting, window?.attachedSheet == nil, commitEditing() else { return }
        let items = selectedItems
        guard !items.isEmpty else { return }
        seasonLookupRequested = true
        isProcessing = true
        table.isEnabled = false
        loadForBatch(items, remaining: items)
    }

    private func loadForBatch(_ items: [WorkspaceItem], remaining: [WorkspaceItem]) {
        guard let first = remaining.first else {
            isProcessing = false
            table.isEnabled = true
            let documents = items.compactMap { $0.document }
            guard documents.count == items.count else { statusLabel.stringValue = "Some selected files could not be loaded. Review their errors before batch editing."; return }
            showSelection()
            let completion: () -> Void = { [weak self] in
                self?.showSelection()
                self?.persistCollection()
            }
            let controller: NSViewController = seasonLookupRequested ? WorkspaceSeasonViewController(items: items, completion: completion) : WorkspaceBatchViewController(documents: documents, completion: completion)
            root.presentAsSheet(controller)
            return
        }
        load(first) { [weak self] in self?.loadForBatch(items, remaining: Array(remaining.dropFirst())) }
    }

    @IBAction func removeSelected(_ sender: Any?) {
        guard !isProcessing, !isImporting, window?.attachedSheet == nil, commitEditing() else { return }
        pendingClose = selectedItems
        closeNext()
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if allowWindowClose { return true }
        guard !isProcessing, !isImporting, sender.attachedSheet == nil, sender.makeFirstResponder(nil) else { NSSound.beep(); return false }
        persistCollection()
        closingWindow = true
        pendingClose = entries
        closeNext()
        return false
    }
    private func closeNext() {
        guard let item = pendingClose.first else {
            if closingWindow { allowWindowClose = true; window?.close(); allowWindowClose = false; closingWindow = false }
            return
        }
        if let document = item.document {
            document.canClose(withDelegate: self, shouldClose: #selector(document(_:shouldClose:contextInfo:)), contextInfo: nil)
        } else {
            pendingClose.removeFirst()
            entries.removeAll { $0 === item }
            rebuildList()
            closeNext()
        }
    }
    @objc private func document(_ document: NSDocument, shouldClose: Bool, contextInfo: UnsafeMutableRawPointer?) {
        guard shouldClose else { pendingClose = []; closingWindow = false; return }
        pendingClose.removeFirst()
        document.close()
        closeNext()
    }
    func documentDidClose(_ document: Document) {
        if activeItem?.document === document { detachEditor(); activeItem = nil }
        entries.removeAll { $0.document === document }
        rebuildList()
        if !closingWindow { persistCollection() }
    }
    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? { return activeDocument?.undoManager }
    override func keyDown(with event: NSEvent) {
        if activeItem?.editor?.handleNavigation(with: event) != true { super.keyDown(with: event) }
    }

    // Window-level commands (including toolbar menus) target the selected document explicitly.
    override func supplementalTarget(forAction action: Selector, sender: Any?) -> Any? {
        return commandTarget(action) ?? super.supplementalTarget(forAction: action, sender: sender)
    }
    private func commandTarget(_ action: Selector) -> NSObject? {
        guard !isProcessing, selectedItems.count == 1 else { return nil }
        if let editor = activeItem?.editor, editor.responds(to: action) { return editor }
        if let document = activeDocument, document.responds(to: action) { return document }
        return nil
    }
    func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        guard !isProcessing, !isImporting, window?.attachedSheet == nil else { return false }
        switch item.action {
        case #selector(addFiles(_:)), #selector(sortFiles(_:)): return true
        case #selector(saveSelected(_:)), #selector(saveDocument(_:)): return selectedItems.contains { $0.document?.isDocumentEdited == true }
        case #selector(saveAllModified(_:)): return entries.contains { $0.document?.isDocumentEdited == true }
        case #selector(batchEdit(_:)): return selectedItems.count > 1
        case #selector(lookupSeason(_:)): return !selectedItems.isEmpty
        case #selector(removeSelected(_:)): return !selectedItems.isEmpty
        default:
            if let action = item.action, let target = commandTarget(action) as? NSUserInterfaceValidations { return target.validateUserInterfaceItem(item) }
            return false
        }
    }

    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int, proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
        tableView.setDropRow(-1, dropOperation: .above)
        return isProcessing || isImporting ? [] : .copy
    }
    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
        guard let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] else { return false }
        importURLs(urls)
        return true
    }

    // Persist references only. Unsaved edits remain owned by NSDocument and require its normal close decision.
    func persistCollection() {
        if closingWindow { return }
        let references: [[String: Any]] = entries.map {
            var reference: [String: Any] = ["path": $0.url.path]
            reference["seasonContextID"] = $0.savedSeasonContext?.id
            reference["episodeID"] = $0.savedEpisodeID
            reference["bookmark"] = try? $0.url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
            return reference
        }
        let contexts = Dictionary(entries.compactMap { item -> (String, WorkspaceSeasonContext)? in
            guard let context = item.savedSeasonContext else { return nil }
            return (context.id, context)
        }, uniquingKeysWith: { first, _ in first })
        if let data = try? JSONEncoder().encode(Array(contexts.values)) {
            UserDefaults.standard.set(data, forKey: Self.contextsKey)
        }
        UserDefaults.standard.set(references, forKey: Self.collectionKey)
        UserDefaults.standard.set(activeItem?.url.path, forKey: Self.collectionKey + "Selection")
        UserDefaults.standard.set(alphabetical, forKey: Self.collectionKey + "Sort")
    }
    func restoreCollection() {
        guard entries.isEmpty, let references = UserDefaults.standard.array(forKey: Self.collectionKey) as? [[String: Any]] else { return }
        alphabetical = UserDefaults.standard.bool(forKey: Self.collectionKey + "Sort")
        restoredSelection = UserDefaults.standard.string(forKey: Self.collectionKey + "Selection")
        let contexts: [WorkspaceSeasonContext] = UserDefaults.standard.data(forKey: Self.contextsKey).flatMap { try? JSONDecoder().decode([WorkspaceSeasonContext].self, from: $0) } ?? []
        let contextMap = Dictionary(contexts.filter { $0.isUsable && MetadataSearch.tvProviders.contains($0.providerName) }.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let urls = references.compactMap { reference -> URL? in
            var stale = false
            let resolved = (reference["bookmark"] as? Data).flatMap { try? URL(resolvingBookmarkData: $0, options: [.withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale) }
            guard let url = resolved ?? (reference["path"] as? String).map({ URL(fileURLWithPath: $0) }) else { return nil }
            if let id = reference["seasonContextID"] as? String, let context = contextMap[id] {
                let episodeID = reference["episodeID"] as? String
                let validEpisode = episodeID.flatMap { id in context.episodes.contains { $0.id == id } ? id : nil }
                self.restoredAssignments[Self.canonicalURL(url).path] = (context, validEpisode)
            }
            return url
        }
        importURLs(urls)
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        return ["WorkspaceAdd", "WorkspaceSave", "WorkspaceSaveAll", "Actions", NSToolbarItem.Identifier.space.rawValue, "WorkspaceBatch", "WorkspaceSeason", "WorkspaceLookup", "WorkspaceRemove", "WorkspaceSort", NSToolbarItem.Identifier.flexibleSpace.rawValue, "WorkspaceSearch"].map { NSToolbarItem.Identifier($0) }
    }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        return toolbarDefaultItemIdentifiers(toolbar) + ["AddTracks", "DeleteTracks", "SendToQueue", "ShowQueue"].map { NSToolbarItem.Identifier($0) }
    }
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        if id.rawValue == "WorkspaceSearch" {
            let item = NSToolbarItem(itemIdentifier: id)
            item.label = "Search"
            item.view = search
            item.minSize = NSSize(width: 140, height: 24)
            item.maxSize = NSSize(width: 240, height: 24)
            return item
        }
        let config: (String, String, String, Selector, AnyObject?)
        switch id.rawValue {
        case "WorkspaceAdd": config = ("Add Files", "NSAddTemplate", "folder.badge.plus", #selector(addFiles(_:)), self)
        case "WorkspaceSave": config = ("Save Selected", "NSMenuOnStateTemplate", "square.and.arrow.down", #selector(saveSelected(_:)), self)
        case "WorkspaceSaveAll": config = ("Save All", "NSMenuOnStateTemplate", "square.and.arrow.down.on.square", #selector(saveAllModified(_:)), self)
        case "WorkspaceBatch": config = ("Batch Edit", "NSActionTemplate", "slider.horizontal.3", #selector(batchEdit(_:)), self)
        case "WorkspaceSeason": config = ("Look Up Season", "NSRevealFreestandingTemplate", "tv", #selector(lookupSeason(_:)), self)
        case "WorkspaceLookup": config = ("Search Metadata", "NSRevealFreestandingTemplate", "doc.text.magnifyingglass", #selector(DocumentEditorViewController.searchMetadata(_:)), nil)
        case "WorkspaceRemove": config = ("Remove", "NSRemoveTemplate", "minus.circle", #selector(removeSelected(_:)), self)
        case "WorkspaceSort": config = ("Sort", "NSListViewTemplate", "arrow.up.arrow.down", #selector(sortFiles(_:)), self)
        default: return documentToolbarDelegate.toolbar(toolbar, itemForItemIdentifier: id, willBeInsertedIntoToolbar: flag)
        }
        return ButtonToolbarItem(itemIdentifier: id, label: config.0, toolTip: config.0, image: config.1, symbolName: config.2, target: config.4, action: config.3)
    }
}

private final class WorkspaceWindow: NSWindow {
    weak var workspace: WorkspaceWindowController?
    override var undoManager: UndoManager? { return workspace?.activeDocument?.undoManager }
}
