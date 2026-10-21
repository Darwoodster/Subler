//
//  WorkspaceSeasonViewController.swift
//  Subler
//

import Cocoa
import MP42Foundation

/// Chooses one provider series/season, then reviews its shared artwork and episode matches.
final class WorkspaceSeasonViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSComboBoxDataSource, NSComboBoxDelegate, NSTextFieldDelegate {
    private struct Match {
        var episodeID: String?
        var apply: Bool
    }

    private let items: [WorkspaceItem]
    private let completion: () -> Void
    private var contexts: [WorkspaceSeasonContext] = []
    private var selectedContext: WorkspaceSeasonContext?
    private var matches: [Match]
    private var suggestions: [String] = []
    private var task: Runnable?
    private var nameTask: Runnable?
    private var generation = UUID()
    private var closing = false
    private var busy = false
    private var chosenArtworks: [MP42Image] = []
    private var artworkChooser: WorkspaceSeasonArtworkViewController?

    private let showField = NSComboBox(frame: .zero)
    private let seasonField = NSTextField(string: "")
    private let providerMenu = NSPopUpButton(frame: .zero, pullsDown: false)
    private let languageMenu = NSPopUpButton(frame: .zero, pullsDown: false)
    private let contextMenu = NSPopUpButton(frame: .zero, pullsDown: false)
    private let tableView = NSTableView()
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let artworkLabel = NSTextField(labelWithString: "Existing artwork will be kept.")
    private let keepArtwork = NSButton(checkboxWithTitle: "Keep existing artwork", target: nil, action: nil)
    private let applyEpisodes = NSButton(checkboxWithTitle: "Apply checked episode matches", target: nil, action: nil)
    private var findButton: NSButton!
    private var searchButton: NSButton!
    private var chooseArtworkButton: NSButton!
    private var localArtworkButton: NSButton!
    private var applyButton: NSButton!

    init(items: [WorkspaceItem], completion: @escaping () -> Void) {
        self.items = items
        self.completion = completion
        self.matches = items.map { _ in Match(episodeID: nil, apply: false) }
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 940, height: 650))
        let title = NSTextField(labelWithString: "Set Series and Season for \(items.count) Files")
        title.font = .boldSystemFont(ofSize: NSFont.systemFontSize + 2)
        let explanation = NSTextField(wrappingLabelWithString: "Series and season apply to every selected file. Review the episode matches below. Only checked matches replace episode details; unmatched files keep their existing episode details.")
        explanation.font = .systemFont(ofSize: NSFont.smallSystemFontSize)

        showField.delegate = self
        showField.dataSource = self
        showField.usesDataSource = true
        showField.completes = true
        showField.placeholderString = "TV series name"
        showField.setAccessibilityLabel("Series name")
        seasonField.delegate = self
        seasonField.placeholderString = "Season"
        seasonField.setAccessibilityLabel("Season number")
        providerMenu.addItems(withTitles: MetadataSearch.tvProviders)
        providerMenu.selectItem(withTitle: MetadataSearch.defaultTVService.name)
        providerMenu.target = self
        providerMenu.action = #selector(providerChanged(_:))
        languageMenu.target = self
        languageMenu.action = #selector(languageChanged(_:))
        configureLanguages()
        findButton = button("Find Series", action: #selector(findSeries(_:)))
        searchButton = button("Search Season", action: #selector(searchSeason(_:)))
        let nameRow = NSStackView(views: [showField, findButton])
        nameRow.orientation = .horizontal
        nameRow.spacing = 8
        let grid = NSGridView(views: [
            [NSTextField(labelWithString: "Series:"), nameRow, NSTextField(labelWithString: "Season:"), seasonField, searchButton],
            [NSTextField(labelWithString: "Provider:"), providerMenu, NSTextField(labelWithString: "Language:"), languageMenu, NSView()]
        ])
        grid.columnSpacing = 10
        grid.rowSpacing = 10
        grid.column(at: 1).xPlacement = .fill
        grid.column(at: 3).xPlacement = .fill
        contextMenu.target = self
        contextMenu.action = #selector(contextChanged(_:))
        contextMenu.setAccessibilityLabel("Series and season result")
        let resultRow = NSStackView(views: [NSTextField(labelWithString: "Series and season:"), contextMenu])
        resultRow.orientation = .horizontal
        resultRow.spacing = 10

        for (identifier, heading, width) in [
            ("apply", "Apply", CGFloat(50)), ("file", "File", CGFloat(290)),
            ("match", "Episode in Selected Season", CGFloat(490))
        ] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(identifier))
            column.title = heading
            column.width = width
            column.minWidth = identifier == "match" ? 260 : width
            tableView.addTableColumn(column)
        }
        tableView.delegate = self
        tableView.dataSource = self
        tableView.rowHeight = 30
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        tableView.setAccessibilityLabel("Season episode matches")
        let scroll = NSScrollView()
        scroll.borderType = .bezelBorder
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.documentView = tableView

        keepArtwork.state = .on
        keepArtwork.target = self
        keepArtwork.action = #selector(artworkOptionChanged(_:))
        chooseArtworkButton = button("Choose Season Artwork…", action: #selector(chooseArtwork(_:)))
        localArtworkButton = button("Choose Image…", action: #selector(chooseLocalArtwork(_:)))
        artworkLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        artworkLabel.lineBreakMode = .byTruncatingMiddle
        let artworkButtons = NSStackView(views: [keepArtwork, chooseArtworkButton, localArtworkButton])
        artworkButtons.orientation = .horizontal
        artworkButtons.spacing = 12
        applyEpisodes.state = .on
        applyEpisodes.target = self
        applyEpisodes.action = #selector(episodeOptionChanged(_:))
        statusLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        statusLabel.stringValue = "Choose a cached season or search for a series and season."
        let cancel = button("Cancel", action: #selector(cancel(_:)))
        cancel.keyEquivalent = "\u{1b}"
        applyButton = button("Apply Season to Selection", action: #selector(apply(_:)))
        applyButton.keyEquivalent = "\r"
        let buttons = NSStackView(views: [NSView(), cancel, applyButton])
        buttons.orientation = .horizontal
        buttons.spacing = 8

        let stack = NSStackView(views: [title, explanation, grid, resultRow, applyEpisodes, scroll, artworkButtons, artworkLabel, statusLabel, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 24),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -24),
            explanation.widthAnchor.constraint(equalTo: stack.widthAnchor),
            grid.widthAnchor.constraint(equalTo: stack.widthAnchor),
            resultRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            showField.widthAnchor.constraint(greaterThanOrEqualToConstant: 220),
            seasonField.widthAnchor.constraint(greaterThanOrEqualToConstant: 90),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 180),
            artworkLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            statusLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        updateControls()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        var uniqueContexts: [WorkspaceSeasonContext] = []
        for item in items {
            if let context = item.seasonContext, !uniqueContexts.contains(where: { $0.id == context.id }) { uniqueContexts.append(context) }
        }
        contexts = uniqueContexts
        seedSearchFields()
        rebuildContextMenu()
        if contexts.count == 1, items.allSatisfy({ $0.seasonContext?.id == contexts[0].id }) {
            contextMenu.selectItem(withTag: 0)
            selectContext(contexts[0])
        } else if contexts.count > 1 {
            statusLabel.stringValue = "The selection includes several seasons. Choose the series and season to apply to this selection."
        }
        updateControls()
    }

    deinit { task?.cancel(); nameTask?.cancel() }

    private func button(_ title: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        return button
    }

    private var service: MetadataService { return MetadataSearch.service(name: providerMenu.titleOfSelectedItem) }
    private var language: String { return service.languageType.tag(displayName: languageMenu.titleOfSelectedItem ?? "") }

    private func configureLanguages() {
        let selectedService = service
        languageMenu.removeAllItems()
        languageMenu.addItems(withTitles: selectedService.languages.map { selectedService.languageType.displayName(language: $0) })
        languageMenu.selectItem(withTitle: MetadataSearch.defaultLanguage(service: selectedService, type: .tvShow))
        if languageMenu.indexOfSelectedItem == -1 { languageMenu.selectItem(withTitle: selectedService.languageType.displayName(language: selectedService.defaultLanguage)) }
    }

    private func seedSearchFields() {
        var shows = Set<String>()
        var seasons = Set<Int>()
        for item in items {
            if let context = item.seasonContext { shows.insert(context.seriesName); seasons.insert(context.season) }
            else if case let .tvShow(series, season, _) = item.searchTerms {
                if !series.isEmpty { shows.insert(series) }
                if let season = season { seasons.insert(season) }
            }
        }
        suggestions = shows.sorted()
        showField.reloadData()
        if shows.count == 1 { showField.stringValue = shows.first ?? "" }
        if seasons.count == 1, let season = seasons.first { seasonField.stringValue = String(season) }
    }

    private func rebuildContextMenu() {
        contextMenu.removeAllItems()
        contextMenu.addItem(withTitle: contexts.isEmpty ? "Search for a series and season" : "Choose a series and season")
        contextMenu.lastItem?.tag = -1
        for (index, context) in contexts.enumerated() {
            let duplicates = contexts.filter { $0.seriesName == context.seriesName && $0.season == context.season && $0.providerName == context.providerName }.count
            let suffix = duplicates > 1 ? " · Result \(index + 1)" : ""
            contextMenu.addItem(withTitle: "\(context.seriesName) · Season \(context.season) · \(context.providerName)\(suffix)")
            contextMenu.lastItem?.tag = index
            contextMenu.lastItem?.toolTip = context.id
        }
    }

    private func invalidateSelection(clearContexts: Bool) {
        generation = UUID()
        task?.cancel()
        nameTask?.cancel()
        task = nil
        nameTask = nil
        busy = false
        selectedContext = nil
        matches = items.map { _ in Match(episodeID: nil, apply: false) }
        chosenArtworks = []
        keepArtwork.state = .on
        artworkLabel.stringValue = "Existing artwork will be kept."
        if clearContexts { contexts = []; rebuildContextMenu() }
        else { contextMenu.selectItem(withTag: -1) }
        tableView.reloadData()
        statusLabel.stringValue = "Search for a series and season, then review the matches."
        updateControls()
    }

    @objc private func providerChanged(_ sender: Any) { configureLanguages(); invalidateSelection(clearContexts: true) }
    @objc private func languageChanged(_ sender: Any) { invalidateSelection(clearContexts: true) }
    func controlTextDidChange(_ obj: Notification) { invalidateSelection(clearContexts: false) }
    func comboBoxSelectionDidChange(_ notification: Notification) { invalidateSelection(clearContexts: false) }

    func numberOfItems(in comboBox: NSComboBox) -> Int { return suggestions.count }
    func comboBox(_ comboBox: NSComboBox, objectValueForItemAt index: Int) -> Any? { return suggestions.indices.contains(index) ? suggestions[index] : nil }
    func comboBox(_ comboBox: NSComboBox, completedString string: String) -> String? { return suggestions.first { $0.lowercased().hasPrefix(string.lowercased()) } }

    @objc private func findSeries(_ sender: Any) {
        guard !busy else { return }
        let name = showField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { statusLabel.stringValue = "Enter a series name to find suggestions."; return }
        nameTask?.cancel()
        let token = generation
        let selectedService = service
        statusLabel.stringValue = "Finding series…"
        findButton.isEnabled = false
        nameTask = MetadataNameSearch.tvNameSearch(service: selectedService, tvShow: name, language: language).search { [weak self] names in
            DispatchQueue.main.async {
                guard let self = self, !self.closing, self.generation == token else { return }
                self.nameTask = nil
                self.suggestions = Array(Set(names)).sorted()
                self.showField.reloadData()
                self.statusLabel.stringValue = names.isEmpty ? "No series suggestions found. Try another name or provider." : "\(self.suggestions.count) series found. Choose a name from the Series menu, then search its season."
                self.updateControls()
            }
        }.runAsync()
    }

    @objc private func searchSeason(_ sender: Any) {
        guard !busy, view.window?.makeFirstResponder(nil) != false else { return }
        let name = showField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let season = Int(seasonField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)), season >= 0 else {
            statusLabel.stringValue = "Enter a series name and a season number of zero or greater."
            return
        }
        invalidateSelection(clearContexts: true)
        busy = true
        statusLabel.stringValue = "Retrieving season episodes…"
        updateControls()
        let token = generation
        let selectedService = service
        let selectedLanguage = language
        task = MetadataSearch.tvSearch(service: selectedService, tvShow: name, season: season, episode: nil, language: selectedLanguage).search { [weak self] results in
            DispatchQueue.main.async {
                guard let self = self, !self.closing, self.generation == token else { return }
                self.task = nil
                self.busy = false
                self.contexts = WorkspaceSeasonContext.groups(results: results, providerName: selectedService.name, language: selectedLanguage, season: season)
                self.rebuildContextMenu()
                if self.contexts.count == 1 {
                    self.contextMenu.selectItem(withTag: 0)
                    self.selectContext(self.contexts[0])
                } else {
                    self.statusLabel.stringValue = self.contexts.isEmpty ? "No episodes were returned for this season. Check the series, season, language or provider." : "Several series were returned. Choose the correct series and review its episode list."
                    self.updateControls()
                }
            }
        }.runAsync()
    }

    @objc private func contextChanged(_ sender: Any) {
        guard !busy, let index = contextMenu.selectedItem?.tag, contexts.indices.contains(index) else { return }
        selectContext(contexts[index])
    }

    private func selectContext(_ context: WorkspaceSeasonContext) {
        generation = UUID()
        task?.cancel()
        task = nil
        selectedContext = context
        chosenArtworks = []
        keepArtwork.state = .on
        artworkLabel.stringValue = "Existing artwork will be kept."
        showField.stringValue = context.seriesName
        seasonField.stringValue = String(context.season)
        providerMenu.selectItem(withTitle: context.providerName)
        configureLanguages()
        languageMenu.selectItem(withTitle: service.languageType.displayName(language: context.language))
        matches = items.map { item in
            let assignedID = item.seasonContext?.id == context.id ? item.episodeID : nil
            let episode = assignedID.flatMap { id in context.episodes.first { $0.id == id } } ?? context.episode(matchingFilename: item.url)
            return Match(episodeID: episode?.id, apply: episode != nil)
        }
        tableView.reloadData()
        let count = matches.filter { $0.episodeID != nil }.count
        statusLabel.stringValue = "\(context.seriesName), Season \(context.season): \(context.episodes.count) episodes; \(count) file matches. Review the choices before applying."
        guard let representative = context.episodes.first else { updateControls(); return }
        busy = true
        statusLabel.stringValue = "Loading shared season artwork…"
        updateControls()
        let token = generation
        task = context.loadDetails(episodeID: representative.id, includeArtwork: true) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self, !self.closing, self.generation == token else { return }
                self.task = nil
                self.busy = false
                switch result {
                case .success:
                    self.artworkLabel.stringValue = self.providerArtworks(context).isEmpty ? "No shared artwork was returned. Keep existing artwork or choose an image." : "Keep existing artwork, or choose shared artwork once for every selected file."
                    self.statusLabel.stringValue = "\(context.seriesName), Season \(context.season): review episode matches, then apply the season to all \(self.items.count) selected files."
                case .failure(let error):
                    self.artworkLabel.stringValue = "Shared artwork could not be loaded. Keep existing artwork or choose an image."
                    self.statusLabel.stringValue = error.localizedDescription
                }
                self.tableView.reloadData()
                self.updateControls()
            }
        }
    }

    private func providerArtworks(_ context: WorkspaceSeasonContext) -> [Artwork] {
        return context.artworkCandidates.filter { $0.type != .episode && $0.type != .person && $0.type != .none }
    }

    @objc private func chooseArtwork(_ sender: Any) {
        guard !busy, let context = selectedContext else { return }
        let artworks = providerArtworks(context)
        guard !artworks.isEmpty else { return }
        let controller = WorkspaceSeasonArtworkViewController(artworks: artworks) { [weak self] images in
            guard let self = self else { return }
            self.artworkChooser = nil
            guard let images = images, !images.isEmpty else { return }
            self.chosenArtworks = images
            self.keepArtwork.state = .off
            self.artworkLabel.stringValue = "\(images.count) artwork image(s) will replace artwork in every selected file."
            self.updateControls()
        }
        artworkChooser = controller
        presentAsSheet(controller)
    }

    @objc private func chooseLocalArtwork(_ sender: Any) {
        guard !busy, selectedContext != nil, let window = view.window else { return }
        let panel = NSOpenPanel()
        panel.allowedFileTypes = ["public.image"]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self = self, response == .OK, let url = panel.url else { return }
            guard let image = NSImage(contentsOf: url), image.isValid else { self.statusLabel.stringValue = "The selected file could not be read as an image."; return }
            self.chosenArtworks = [MP42Image(image: image)]
            self.keepArtwork.state = .off
            self.artworkLabel.stringValue = "\(url.lastPathComponent) will replace artwork in every selected file."
            self.updateControls()
        }
    }

    @objc private func artworkOptionChanged(_ sender: Any) {
        if keepArtwork.state == .off && chosenArtworks.isEmpty { artworkLabel.stringValue = "Choose shared artwork or an image, or keep existing artwork." }
        else if keepArtwork.state == .on { artworkLabel.stringValue = "Existing artwork will be kept." }
        else { artworkLabel.stringValue = "\(chosenArtworks.count) artwork image(s) will replace artwork in every selected file." }
        updateControls()
    }
    @objc private func episodeOptionChanged(_ sender: Any) { tableView.reloadData(); updateControls() }

    private func updateControls() {
        findButton.isEnabled = !busy && nameTask == nil && !items.isEmpty
        searchButton.isEnabled = !busy && !items.isEmpty
        for control in [showField as NSControl, seasonField, providerMenu, languageMenu, contextMenu, keepArtwork, applyEpisodes] { control.isEnabled = !busy }
        chooseArtworkButton.isEnabled = !busy && selectedContext.map { !providerArtworks($0).isEmpty } == true
        localArtworkButton.isEnabled = !busy && selectedContext != nil
        applyButton.isEnabled = !busy && selectedContext != nil && !items.isEmpty && (keepArtwork.state == .on || !chosenArtworks.isEmpty)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { return items.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard items.indices.contains(row) else { return nil }
        switch tableColumn?.identifier.rawValue {
        case "apply":
            let check = NSButton(checkboxWithTitle: "", target: self, action: #selector(checkMatch(_:)))
            check.tag = row
            check.state = matches[row].apply ? .on : .off
            check.isEnabled = !busy && applyEpisodes.state == .on && matches[row].episodeID != nil
            check.setAccessibilityLabel("Apply episode details to \(items[row].url.lastPathComponent)")
            return check
        case "file":
            let label = NSTextField(labelWithString: items[row].url.lastPathComponent)
            label.lineBreakMode = .byTruncatingMiddle
            label.toolTip = items[row].url.path
            return label
        case "match":
            let menu = NSPopUpButton(frame: .zero, pullsDown: false)
            menu.addItem(withTitle: "Unmatched — keep episode details")
            menu.lastItem?.representedObject = ""
            if let context = selectedContext {
                for episode in context.episodes {
                    menu.addItem(withTitle: String(format: "E%02d · %@", episode.number, episode.title))
                    menu.lastItem?.representedObject = episode.id
                }
            }
            let selected = menu.itemArray.first { ($0.representedObject as? String) == (matches[row].episodeID ?? "") }
            menu.select(selected)
            menu.tag = row
            menu.target = self
            menu.action = #selector(matchChanged(_:))
            menu.isEnabled = !busy && selectedContext != nil
            return menu
        default: return nil
        }
    }

    @objc private func checkMatch(_ sender: NSButton) {
        guard !busy, matches.indices.contains(sender.tag) else { return }
        matches[sender.tag].apply = sender.state == .on && matches[sender.tag].episodeID != nil
    }
    @objc private func matchChanged(_ sender: NSPopUpButton) {
        guard !busy, matches.indices.contains(sender.tag) else { return }
        let id = sender.selectedItem?.representedObject as? String ?? ""
        matches[sender.tag] = Match(episodeID: id.isEmpty ? nil : id, apply: !id.isEmpty)
        tableView.reloadData(forRowIndexes: IndexSet(integer: sender.tag), columnIndexes: IndexSet(integer: 0))
    }

    @objc private func apply(_ sender: Any) {
        guard !busy, let context = selectedContext, view.window?.makeFirstResponder(nil) != false else { return }
        let reviewed: [(WorkspaceItem, String)] = applyEpisodes.state == .on ? zip(items, matches).compactMap { item, match in
            guard match.apply, let id = match.episodeID else { return nil }
            return (item, id)
        } : []
        busy = true
        updateControls()
        tableView.reloadData()
        loadCheckedDetails(context: context, reviewed: reviewed, position: 0, token: generation)
    }

    private func loadCheckedDetails(context: WorkspaceSeasonContext, reviewed: [(WorkspaceItem, String)], position: Int, token: UUID) {
        guard !closing, generation == token else { return }
        guard position < reviewed.count else {
            do {
                let episodes = Dictionary(uniqueKeysWithValues: reviewed.map { ($0.0.url.path, $0.1) })
                try WorkspaceSeasonOperations.assign(context: context, artworks: keepArtwork.state == .on ? [] : chosenArtworks, to: items, episodes: episodes)
                completion()
                cancelTasks()
                presentingViewController?.dismiss(self)
            } catch {
                busy = false
                statusLabel.stringValue = error.localizedDescription
                tableView.reloadData()
                updateControls()
            }
            return
        }
        statusLabel.stringValue = "Loading episode details \(position + 1) of \(reviewed.count)…"
        task = context.loadDetails(episodeID: reviewed[position].1) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self, !self.closing, self.generation == token else { return }
                self.task = nil
                switch result {
                case .success:
                    self.loadCheckedDetails(context: context, reviewed: reviewed, position: position + 1, token: token)
                case .failure(let error):
                    self.busy = false
                    self.statusLabel.stringValue = "Episode details could not be loaded. No files have changed. \(error.localizedDescription)"
                    self.tableView.reloadData()
                    self.updateControls()
                }
            }
        }
    }

    private func cancelTasks() {
        closing = true
        generation = UUID()
        task?.cancel()
        nameTask?.cancel()
        task = nil
        nameTask = nil
    }
    @objc private func cancel(_ sender: Any) {
        cancelTasks()
        presentingViewController?.dismiss(self)
    }
}

/// Supplies an explicit cancel path around Subler's existing artwork chooser.
private final class WorkspaceSeasonArtworkViewController: NSViewController, ArtworkSelectorControllerDelegate {
    private let candidates: [Artwork]
    private let completion: ([MP42Image]?) -> Void
    private var selector: ArtworkSelectorController?
    private var finished = false

    init(artworks: [Artwork], completion: @escaping ([MP42Image]?) -> Void) {
        candidates = artworks
        self.completion = completion
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 680, height: 650))
        let metadata = MetadataResult()
        metadata.mediaKind = .tvShow
        metadata.remoteArtworks = candidates
        let selector = ArtworkSelectorController(metadata: metadata, delegate: self)
        self.selector = selector
        addChild(selector)
        let title = NSTextField(labelWithString: "Choose Shared Season Artwork")
        title.font = .boldSystemFont(ofSize: NSFont.systemFontSize + 2)
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel(_:)))
        cancel.bezelStyle = .rounded
        cancel.keyEquivalent = "\u{1b}"
        let header = NSStackView(views: [title, NSView(), cancel])
        header.orientation = .horizontal
        header.spacing = 12
        header.translatesAutoresizingMaskIntoConstraints = false
        selector.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(header)
        view.addSubview(selector.view)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: view.topAnchor, constant: 16),
            header.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            header.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            selector.view.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 8),
            selector.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            selector.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            selector.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }

    func didAddArtworks(metadata: MetadataResult) { finish(metadata.artworks.isEmpty ? nil : metadata.artworks) }
    @objc private func cancel(_ sender: Any) { finish(nil) }
    private func finish(_ images: [MP42Image]?) {
        guard !finished else { return }
        finished = true
        presentingViewController?.dismiss(self)
        completion(images)
    }
}
