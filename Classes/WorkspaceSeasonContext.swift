// Season lookup state shared by a collection, separate from each file's editable media.

import Cocoa
import MP42Foundation

/// Value snapshots isolate mutable provider results from documents and background tasks.
struct WorkspaceMetadataSnapshot: Codable {
    private var strings: [String: String] = [:]
    private var integers: [String: Int] = [:]
    private var mediaKind: Int
    private var contentRating: Int
    private var artworks: [RemoteArtwork]

    private struct RemoteArtwork: Codable {
        let url: URL
        let thumbURL: URL
        let service: String
        let type: Int
        let size: Int
    }

    init(_ result: MetadataResult) {
        mediaKind = result.mediaKind.rawValue
        contentRating = result.contentRating
        let keys = Set(MetadataResult.Key.tvShowKeysStrings + [MetadataResult.Key.iTunesURL.rawValue])
        for rawKey in keys {
            guard let key = MetadataResult.Key(rawValue: rawKey) else { continue }
            if let value = result[key] as? String { strings[rawKey] = value }
            else if let value = result[key] as? Int { integers[rawKey] = value }
            else if let value = result[key] as? Date { strings[rawKey] = ISO8601DateFormatter().string(from: value) }
            else if let value = result[key] as? URL { strings[rawKey] = value.absoluteString }
        }
        artworks = result.remoteArtworks.map { RemoteArtwork(url: $0.url, thumbURL: $0.thumbURL, service: $0.service, type: $0.type.rawValue, size: $0.size.rawValue) }
    }

    func metadata() -> MetadataResult {
        let result = MetadataResult()
        result.mediaKind = MediaKind(rawValue: mediaKind) ?? .tvShow
        result.contentRating = contentRating
        for (rawKey, value) in strings { if let key = MetadataResult.Key(rawValue: rawKey) { result[key] = value } }
        for (rawKey, value) in integers { if let key = MetadataResult.Key(rawValue: rawKey) { result[key] = value } }
        result.remoteArtworks = artworks.compactMap {
            guard let type = ArtworkType(rawValue: $0.type), let size = ArtworkSize(rawValue: $0.size) else { return nil }
            return Artwork(url: $0.url, thumbURL: $0.thumbURL, service: $0.service, type: type, size: size)
        }
        return result
    }
}

struct WorkspaceEpisode: Codable {
    let id: String
    let number: Int
    let title: String
    let season: Int
    fileprivate let snapshot: WorkspaceMetadataSnapshot
}

final class WorkspaceSeasonContext: Codable {
    let id: String
    let seriesName: String
    let season: Int
    let providerName: String
    let language: String
    let episodes: [WorkspaceEpisode]
    private let seriesIdentity: String
    private var details: [String: WorkspaceMetadataSnapshot] = [:]
    private var artworkWasLoaded = false
    private var artworkSnapshot: WorkspaceMetadataSnapshot?

    private init(seriesName: String, season: Int, providerName: String, language: String, identity: String, results: [MetadataResult]) {
        id = UUID().uuidString
        self.seriesName = seriesName
        self.season = season
        self.providerName = providerName
        self.language = language
        seriesIdentity = identity
        episodes = results.enumerated().compactMap { index, result in
            guard let number = Self.number(result[.episodeNumber]), number >= 0 else { return nil }
            let providerID = Self.string(result[.serviceEpisodeID]) ?? Self.string(result[.contentID]) ?? (providerName == iTunesStore().name ? Self.string(result[.serviceContentID]) : nil) ?? "\(number)"
            return WorkspaceEpisode(id: "\(providerID):\(index)", number: number,
                                    title: Self.string(result[.name]) ?? "Episode \(number)", season: season,
                                    snapshot: WorkspaceMetadataSnapshot(result))
        }.sorted { $0.number < $1.number }
    }

    static func number(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? String { return Int(value) }
        return nil
    }

    private static func string(_ value: Any?) -> String? {
        if let value = value as? String, !value.isEmpty { return value }
        if let value = value as? Int { return String(value) }
        return nil
    }

    private static func identity(_ result: MetadataResult, provider: String) -> String {
        if provider == iTunesStore().name {
            return "\(string(result[.artistID]) ?? string(result[.seriesName]) ?? "")|\(string(result[.playlistID]) ?? "")"
        }
        return "\(string(result[.serviceContentID]) ?? string(result[.seriesName]) ?? "")|\(string(result[.serviceAdditionalContentID]) ?? "")"
    }

    static func groups(results: [MetadataResult], providerName: String, language: String, season: Int) -> [WorkspaceSeasonContext] {
        let valid = results.filter { number($0[.season]) == season && number($0[.episodeNumber]) != nil && string($0[.seriesName]) != nil }
        let groups = Dictionary(grouping: valid) { identity($0, provider: providerName) }
        return groups.keys.sorted().compactMap { identity in
            guard let records = groups[identity], let first = records.first, let name = string(first[.seriesName]) else { return nil }
            return WorkspaceSeasonContext(seriesName: name, season: season, providerName: providerName, language: language, identity: identity, results: records)
        }
    }

    func metadata(for episodeID: String) -> MetadataResult? {
        return (details[episodeID] ?? episodes.first { $0.id == episodeID }?.snapshot)?.metadata()
    }

    var artworkCandidates: [Artwork] {
        let sources = artworkSnapshot.map { [$0] } ?? episodes.map { $0.snapshot }
        return Artwork.unique(artworks: sources.flatMap { $0.metadata().remoteArtworks }.filter { $0.type == .season || $0.type == .poster || $0.type == .backdrop })
            .sorted { ($0.type == .season ? 0 : 1) < ($1.type == .season ? 0 : 1) }
    }

    /// A bare E01 is meaningful only within the season explicitly chosen by the user.
    func episode(matchingFilename url: URL) -> WorkspaceEpisode? {
        let name = url.deletingPathExtension().lastPathComponent
        if name.range(of: "(?i)E[0-9]{1,4}(?:[ ._+\\-]*E|[-+])[0-9]{1,4}", options: .regularExpression) != nil { return nil }
        var numbers: Set<Int> = []
        var explicitSeasons: Set<Int> = []
        let patterns = ["(?i)(?<![A-Za-z0-9])S([0-9]{1,3})[ ._-]*E([0-9]{1,4})(?![0-9])",
                        "(?i)(?<![A-Za-z0-9])([0-9]{1,3})x([0-9]{1,4})(?![0-9])"]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            for match in regex.matches(in: name, range: NSRange(name.startIndex..., in: name)) {
                if let seasonRange = Range(match.range(at: 1), in: name), let episodeRange = Range(match.range(at: 2), in: name),
                   let s = Int(name[seasonRange]), let e = Int(name[episodeRange]) { explicitSeasons.insert(s); numbers.insert(e) }
            }
        }
        if let regex = try? NSRegularExpression(pattern: "(?i)(?<![A-Za-z0-9])E(?:P)?[ ._-]*([0-9]{1,4})(?![0-9])") {
            for match in regex.matches(in: name, range: NSRange(name.startIndex..., in: name)) {
                if let range = Range(match.range(at: 1), in: name), let value = Int(name[range]) { numbers.insert(value) }
            }
        }
        // A provider parser also understands conventional full S01E01 names.
        if numbers.isEmpty, case let .tvShow(_, s, e) = url.lastPathComponent.parsedAsFilename(), let e = e {
            numbers.insert(e)
            if let s = s { explicitSeasons.insert(s) }
        }
        guard numbers.count == 1, explicitSeasons.isEmpty || explicitSeasons == [season], let number = numbers.first else { return nil }
        let matches = episodes.filter { $0.number == number }
        return matches.count == 1 ? matches.first : nil
    }

    func cacheDetails(_ result: MetadataResult, episodeID: String) throws {
        guard let episode = episodes.first(where: { $0.id == episodeID }),
              Self.number(result[.season]) == season, Self.number(result[.episodeNumber]) == episode.number,
              Self.identity(result, provider: providerName) == seriesIdentity else {
            throw Self.error("The provider returned details for a different series or episode. No files have changed.")
        }
        let original = episode.snapshot.metadata()
        let identityKeys: [MetadataResult.Key] = providerName == iTunesStore().name ? [.serviceEpisodeID, .serviceContentID, .contentID] : [.serviceEpisodeID]
        guard identityKeys.allSatisfy({ key in
            guard let expected = Self.string(original[key]) else { return true }
            return Self.string(result[key]) == expected
        }) else { throw Self.error("The provider returned a different episode identifier. No files have changed.") }
        details[episodeID] = WorkspaceMetadataSnapshot(result)
    }

    /// The service parameter supports deterministic provider tests; production uses the pinned provider.
    @discardableResult
    func loadDetails(episodeID: String, includeArtwork: Bool = false, service: MetadataService? = nil,
                     completion: @escaping (Result<MetadataResult, Error>) -> Void) -> Runnable {
        let fetchArtwork = includeArtwork && !artworkWasLoaded
        if !fetchArtwork, let snapshot = details[episodeID] {
            completion(.success(snapshot.metadata()))
            return WorkspaceCompletedTask()
        }
        guard let metadata = episodes.first(where: { $0.id == episodeID })?.snapshot.metadata() else {
            completion(.failure(Self.error("This episode is no longer available in the assigned season.")))
            return WorkspaceCompletedTask()
        }
        let provider = service ?? MetadataSearch.service(name: providerName)
        let selectedLanguage = language
        return RunnableTask(search: fetchArtwork ? provider.loadTVMetadata(metadata, language: selectedLanguage) : provider.loadTVEpisodeMetadata(metadata, language: selectedLanguage), completionHandler: { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                do {
                    try self.cacheDetails(result, episodeID: episodeID)
                    if fetchArtwork { self.artworkSnapshot = WorkspaceMetadataSnapshot(result); self.artworkWasLoaded = true }
                    completion(.success(WorkspaceMetadataSnapshot(result).metadata()))
                } catch { completion(.failure(error)) }
            }
        }).runAsync()
    }

    func sharedMetadata() -> MP42Metadata {
        let sample = artworkSnapshot?.metadata() ?? episodes.first.flatMap { metadata(for: $0.id) } ?? MetadataResult()
        sample[.seriesName] = seriesName
        sample[.season] = season
        let allowed: Set<String> = [MP42MetadataKeyTVShow, MP42MetadataKeyTVSeason, MP42MetadataKeyMediaKind,
                                    MP42MetadataKeyArtist, MP42MetadataKeyAlbumArtist, MP42MetadataKeyAlbum,
                                    MP42MetadataKeyTVNetwork, MP42MetadataKeySeriesDescription,
                                    MP42MetadataKeyUserGenre, MP42MetadataKeyStudio]
        let map = MetadataResultMap(items: MetadataPrefs.tvShowResultMap.items.filter { allowed.contains($0.key) }, type: .tvShow)
        let mapped = sample.mappedMetadata(to: map, keepEmptyKeys: false)
        mapped.removeItems(mapped.items.filter { !allowed.contains($0.identifier) })
        // Required native tags are independent of customizable result maps.
        mapped.addItem(MP42MetadataItem(identifier: MP42MetadataKeyTVShow, value: seriesName as NSString, dataType: .string, extendedLanguageTag: nil))
        mapped.addItem(MP42MetadataItem(identifier: MP42MetadataKeyTVSeason, value: NSNumber(value: season), dataType: .integer, extendedLanguageTag: nil))
        mapped.addItem(MP42MetadataItem(identifier: MP42MetadataKeyMediaKind, value: NSNumber(value: MediaKind.tvShow.rawValue), dataType: .integer, extendedLanguageTag: nil))
        return mapped
    }

    var isUsable: Bool {
        return season >= 0 && season <= Int(UInt32.max) && !seriesName.isEmpty && !language.isEmpty &&
            !episodes.isEmpty && episodes.allSatisfy { $0.season == season && $0.number >= 0 } &&
            Set(episodes.map { $0.id }).count == episodes.count
    }

    private static func error(_ message: String) -> NSError { NSError(domain: "WorkspaceSeason", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}

private final class WorkspaceCompletedTask: Runnable {
    func runAsync() -> Runnable { self }
    func run() -> Runnable { self }
    func cancel() {}
}

/// Only these destination fields change when the user chooses a different episode.
/// In particular, custom metadata maps cannot replace the shared season or artwork.
enum WorkspaceSeasonOperations {
    static let episodeKeys: Set<String> = [MP42MetadataKeyName, MP42MetadataKeyDescription, MP42MetadataKeyLongDescription,
        MP42MetadataKeyTVEpisodeNumber, MP42MetadataKeyTVEpisodeID, MP42MetadataKeyTrackNumber,
        MP42MetadataKeyReleaseDate, MP42MetadataKeyCast, MP42MetadataKeyDirector, MP42MetadataKeyScreenwriters,
        MP42MetadataKeyProducer, MP42MetadataKeyExecProducer, MP42MetadataKeyComposer, MP42MetadataKeyRating,
        MP42MetadataKeyContentRating, MP42MetadataKeyContentID, MP42MetadataKeyCopyright]

    static func episodeMetadata(context: WorkspaceSeasonContext, episodeID: String) throws -> MP42Metadata {
        guard let result = context.metadata(for: episodeID), let episode = context.episodes.first(where: { $0.id == episodeID }) else {
            throw NSError(domain: "WorkspaceSeason", code: 1, userInfo: [NSLocalizedDescriptionKey: "Choose an episode from the assigned season."])
        }
        let map = MetadataResultMap(items: MetadataPrefs.tvShowResultMap.items.filter { episodeKeys.contains($0.key) }, type: .tvShow)
        let mapped = result.mappedMetadata(to: map, keepEmptyKeys: false)
        mapped.removeItems(mapped.items.filter { !episodeKeys.contains($0.identifier) })
        mapped.addItem(MP42MetadataItem(identifier: MP42MetadataKeyTVEpisodeNumber, value: NSNumber(value: episode.number), dataType: .integer, extendedLanguageTag: nil))
        return mapped
    }

    static func assign(context: WorkspaceSeasonContext, artworks: [MP42Image], to items: [WorkspaceItem], episodes: [String: String]) throws {
        guard !items.isEmpty, items.allSatisfy({ $0.document != nil && $0.document?.isSaving == false }) else {
            throw NSError(domain: "WorkspaceSeason", code: 1, userInfo: [NSLocalizedDescriptionKey: "Wait until all selected files are loaded and no file is saving."])
        }
        let shared = context.sharedMetadata()
        let images = try artworks.map { image -> (Data, MP42TagArtworkType) in
            guard let data = image.data, NSImage(data: data)?.isValid == true else { throw NSError(domain: "WorkspaceSeason", code: 1, userInfo: [NSLocalizedDescriptionKey: "The selected artwork could not be read. No files have changed."]) }
            return (data, image.type)
        }
        var episodeValues: [String: MP42Metadata] = [:]
        for id in Set(episodes.values) { episodeValues[id] = try episodeMetadata(context: context, episodeID: id) }
        for item in items {
            guard let document = item.document else { continue }
            document.undoManager?.beginUndoGrouping()
            document.mp4.metadata.merge(shared, overwrite: true)
            if !images.isEmpty {
                document.mp4.metadata.removeItems(document.mp4.metadata.metadataItemsFiltered(byIdentifier: MP42MetadataKeyCoverArt))
                for (data, type) in images { document.mp4.metadata.addItem(MP42MetadataItem(identifier: MP42MetadataKeyCoverArt, value: MP42Image(data: data, type: type), dataType: .image, extendedLanguageTag: nil)) }
            }
            let episodeID = episodes[item.url.path]
            if let episodeID = episodeID, let metadata = episodeValues[episodeID] { replaceEpisodeFields(metadata, on: document) }
            item.setSeasonContext(context, episodeID: episodeID)
            document.undoManager?.setActionName(NSLocalizedString("Assign TV Season", comment: "Workspace season undo"))
            document.undoManager?.endUndoGrouping()
            document.editorController?.reloadData()
        }
    }

    static func applyEpisode(context: WorkspaceSeasonContext, episodeID: String, to item: WorkspaceItem) throws {
        guard item.seasonContext?.id == context.id, let document = item.document, !document.isSaving else {
            throw NSError(domain: "WorkspaceSeason", code: 1, userInfo: [NSLocalizedDescriptionKey: "The file’s season assignment changed. Select the file again before applying an episode."])
        }
        let values = try episodeMetadata(context: context, episodeID: episodeID)
        document.undoManager?.beginUndoGrouping()
        replaceEpisodeFields(values, on: document)
        item.setSeasonContext(context, episodeID: episodeID)
        document.undoManager?.setActionName(NSLocalizedString("Assign TV Episode", comment: "Workspace episode undo"))
        document.undoManager?.endUndoGrouping()
        document.editorController?.reloadData()
    }

    private static func replaceEpisodeFields(_ values: MP42Metadata, on document: Document) {
        document.mp4.metadata.removeItems(document.mp4.metadata.items.filter { episodeKeys.contains($0.identifier) })
        document.mp4.metadata.merge(values, overwrite: true)
    }
}
