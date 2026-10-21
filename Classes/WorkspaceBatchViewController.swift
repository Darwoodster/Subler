//
//  WorkspaceBatchViewController.swift
//  Subler
//

import Cocoa
import MP42Foundation

/// Applies an explicit set of shared fields without replacing episode-specific metadata.
final class WorkspaceBatchViewController: NSViewController {

    private let documents: [Document]
    private let completion: () -> Void

    private let showCheck = NSButton(checkboxWithTitle: NSLocalizedString("TV Show", comment: "Workspace batch field"), target: nil, action: nil)
    private let seasonCheck = NSButton(checkboxWithTitle: NSLocalizedString("Season", comment: "Workspace batch field"), target: nil, action: nil)
    private let kindCheck = NSButton(checkboxWithTitle: NSLocalizedString("Media Kind", comment: "Workspace batch field"), target: nil, action: nil)
    private let artworkCheck = NSButton(checkboxWithTitle: NSLocalizedString("Replace Artwork", comment: "Workspace batch field"), target: nil, action: nil)
    private let showField = NSTextField(string: "")
    private let seasonField = NSTextField(string: "")
    private let kindMenu = NSPopUpButton(frame: .zero, pullsDown: false)
    private let artworkLabel = NSTextField(labelWithString: NSLocalizedString("Choose a replacement image", comment: "Workspace batch artwork"))
    private let errorLabel = NSTextField(wrappingLabelWithString: "")
    private var applyButton: NSButton!
    private var artwork: MP42Image?

    init(documents: [Document], completion: @escaping () -> Void) {
        self.documents = documents
        self.completion = completion
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 540, height: 400))

        let title = NSTextField(labelWithString: String.localizedStringWithFormat(NSLocalizedString("Edit %ld Files", comment: "Workspace batch title"), documents.count))
        title.font = .boldSystemFont(ofSize: NSFont.systemFontSize + 2)
        let explanation = NSTextField(wrappingLabelWithString: NSLocalizedString("Check the fields to apply to every selected file. Titles, episode numbers and descriptions are preserved. Changes remain unsaved until you save the files.", comment: "Workspace batch explanation"))

        let mixed = NSLocalizedString("Mixed values", comment: "Workspace batch mixed value")
        configure(showField, identifier: MP42MetadataKeyTVShow, mixed: mixed)
        configure(seasonField, identifier: MP42MetadataKeyTVSeason, mixed: mixed)

        kindMenu.addItem(withTitle: mixed)
        kindMenu.lastItem?.tag = -1
        kindMenu.addItem(withTitle: NSLocalizedString("TV Show", comment: "Workspace media kind"))
        kindMenu.lastItem?.tag = MediaKind.tvShow.rawValue
        kindMenu.addItem(withTitle: NSLocalizedString("Movie", comment: "Workspace media kind"))
        kindMenu.lastItem?.tag = MediaKind.movie.rawValue
        let kinds = documents.map { $0.mp4.metadata.metadataItemsFiltered(byIdentifier: MP42MetadataKeyMediaKind).first?.numberValue?.intValue }
        if let first = kinds.first, kinds.allSatisfy({ $0 == first }) {
            if let first = first, [MediaKind.tvShow.rawValue, MediaKind.movie.rawValue].contains(first) {
                kindMenu.selectItem(withTag: first)
            } else {
                kindMenu.item(at: 0)?.title = NSLocalizedString("Choose a kind", comment: "Workspace batch unspecified kind")
            }
        }

        let chooseArtwork = NSButton(title: NSLocalizedString("Choose…", comment: "Workspace batch artwork action"), target: self, action: #selector(chooseArtwork(_:)))
        let coverArts = documents.map { document in
            document.mp4.metadata.metadataItemsFiltered(byIdentifier: MP42MetadataKeyCoverArt).map { $0.imageValue?.data }
        }
        if let first = coverArts.first, !coverArts.allSatisfy({ $0 == first }) {
            artworkLabel.stringValue = NSLocalizedString("Mixed artwork (choose a replacement)", comment: "Workspace batch mixed artwork")
        }
        artworkLabel.lineBreakMode = .byTruncatingMiddle
        artworkLabel.toolTip = NSLocalizedString("Replaces all artwork only when checked and an image has been chosen.", comment: "Workspace batch artwork help")
        let artworkRow = NSStackView(views: [chooseArtwork, artworkLabel])
        artworkRow.orientation = .horizontal
        artworkRow.spacing = 8

        let grid = NSGridView(views: [
            [showCheck, showField],
            [seasonCheck, seasonField],
            [kindCheck, kindMenu],
            [artworkCheck, artworkRow]
        ])
        grid.rowSpacing = 12
        grid.columnSpacing = 16
        grid.column(at: 0).xPlacement = .leading
        grid.column(at: 1).xPlacement = .fill
        for check in [showCheck, seasonCheck, kindCheck, artworkCheck] {
            check.target = self
            check.action = #selector(fieldsChanged(_:))
        }
        showField.toolTip = NSLocalizedString("An empty value clears the TV Show field when checked.", comment: "Workspace batch show help")

        errorLabel.textColor = .systemRed
        errorLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        let cancel = NSButton(title: NSLocalizedString("Cancel", comment: "Workspace batch cancel"), target: self, action: #selector(cancel(_:)))
        cancel.keyEquivalent = "\u{1b}"
        applyButton = NSButton(title: NSLocalizedString("Apply Changes", comment: "Workspace batch apply"), target: self, action: #selector(apply(_:)))
        applyButton.keyEquivalent = "\r"
        applyButton.bezelStyle = .rounded
        cancel.bezelStyle = .rounded
        let spacer = NSView()
        let buttons = NSStackView(views: [spacer, cancel, applyButton])
        buttons.orientation = .horizontal
        buttons.spacing = 8

        let stack = NSStackView(views: [title, explanation, grid, errorLabel, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 24),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -24),
            explanation.widthAnchor.constraint(equalTo: stack.widthAnchor),
            grid.widthAnchor.constraint(equalTo: stack.widthAnchor),
            errorLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor),
            showField.widthAnchor.constraint(greaterThanOrEqualToConstant: 260)
        ])
        fieldsChanged(self)
    }

    private func configure(_ field: NSTextField, identifier: String, mixed: String) {
        let values = documents.map { $0.mp4.metadata.metadataItemsFiltered(byIdentifier: identifier).first?.stringValue }
        if let first = values.first, values.allSatisfy({ $0 == first }) {
            field.stringValue = first ?? ""
        } else {
            field.placeholderString = mixed
        }
    }

    @objc private func fieldsChanged(_ sender: Any) {
        showField.isEnabled = showCheck.state == .on
        seasonField.isEnabled = seasonCheck.state == .on
        kindMenu.isEnabled = kindCheck.state == .on
        applyButton.isEnabled = !documents.isEmpty && [showCheck, seasonCheck, kindCheck, artworkCheck].contains { $0.state == .on }
        errorLabel.stringValue = ""
    }

    @objc private func chooseArtwork(_ sender: Any) {
        guard let window = view.window else { return }
        let panel = NSOpenPanel()
        panel.allowedFileTypes = ["public.image"]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self = self, response == .OK, let url = panel.url else { return }
            guard let image = NSImage(contentsOf: url), image.isValid else {
                self.errorLabel.stringValue = NSLocalizedString("The selected file could not be read as an image.", comment: "Workspace batch invalid artwork")
                return
            }
            self.artwork = MP42Image(image: image)
            self.artworkLabel.stringValue = url.lastPathComponent
            self.artworkCheck.state = .on
            self.fieldsChanged(self)
        }
    }

    @objc private func cancel(_ sender: Any) {
        presentingViewController?.dismiss(self)
    }

    @objc private func apply(_ sender: Any) {
        view.window?.makeFirstResponder(nil)
        let seasonText = seasonField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let season = Int(seasonText)
        if seasonCheck.state == .on && (season == nil || season! < 0) {
            errorLabel.stringValue = NSLocalizedString("Enter a season number of zero or greater.", comment: "Workspace batch invalid season")
            return
        }
        if kindCheck.state == .on && kindMenu.selectedItem?.tag == -1 {
            errorLabel.stringValue = NSLocalizedString("Choose a media kind to apply.", comment: "Workspace batch invalid kind")
            return
        }
        if artworkCheck.state == .on && artwork == nil {
            errorLabel.stringValue = NSLocalizedString("Choose an artwork image before applying it.", comment: "Workspace batch missing artwork")
            return
        }

        for document in documents {
            let metadata = document.mp4.metadata
            document.undoManager?.beginUndoGrouping()
            if showCheck.state == .on {
                let value = showField.stringValue
                let existing = metadata.metadataItemsFiltered(byIdentifier: MP42MetadataKeyTVShow)
                if value.isEmpty {
                    metadata.removeItems(existing)
                } else if existing.first?.stringValue != value {
                    metadata.addItem(MP42MetadataItem(identifier: MP42MetadataKeyTVShow, value: value as NSString, dataType: .string, extendedLanguageTag: nil))
                }
            }
            if seasonCheck.state == .on, let season = season,
               metadata.metadataItemsFiltered(byIdentifier: MP42MetadataKeyTVSeason).first?.numberValue?.intValue != season {
                metadata.addItem(MP42MetadataItem(identifier: MP42MetadataKeyTVSeason, value: NSNumber(value: season), dataType: .integer, extendedLanguageTag: nil))
            }
            if kindCheck.state == .on, let kind = kindMenu.selectedItem?.tag,
               metadata.metadataItemsFiltered(byIdentifier: MP42MetadataKeyMediaKind).first?.numberValue?.intValue != kind {
                metadata.addItem(MP42MetadataItem(identifier: MP42MetadataKeyMediaKind, value: NSNumber(value: kind), dataType: .integer, extendedLanguageTag: nil))
            }
            if artworkCheck.state == .on, let artwork = artwork {
                metadata.removeItems(metadata.metadataItemsFiltered(byIdentifier: MP42MetadataKeyCoverArt))
                metadata.addItem(MP42MetadataItem(identifier: MP42MetadataKeyCoverArt, value: artwork, dataType: .image, extendedLanguageTag: nil))
            }
            document.undoManager?.setActionName(NSLocalizedString("Batch Metadata Edit", comment: "Workspace batch undo"))
            document.undoManager?.endUndoGrouping()
            document.editorController?.reloadData()
        }
        completion()
        presentingViewController?.dismiss(self)
    }
}
