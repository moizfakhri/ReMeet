import Foundation

/// A user folder for meetings (e.g. one per team or project). The meeting files never move: a
/// meeting belongs to a folder through `MeetingMeta.collectionID`. The folder's `context` is
/// written once by the user and goes into that folder's summaries and "Copy for AI".
/// When `exportDirectoryPath` is set, ReMeet automatically writes AI-ready Markdown files for
/// meetings in this folder into that local directory.
public struct MeetingCollection: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var context: String
    /// Optional local directory path where meetings in this folder auto-export as `.md` files.
    public var exportDirectoryPath: String?

    public init(id: String = UUID().uuidString, name: String, context: String = "",
                exportDirectoryPath: String? = nil) {
        self.id = id
        self.name = name
        self.context = context
        self.exportDirectoryPath = exportDirectoryPath
    }

    private enum CodingKeys: String, CodingKey { case id, name, context, exportDirectoryPath }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        context = try c.decodeIfPresent(String.self, forKey: .context) ?? ""
        let raw = try c.decodeIfPresent(String.self, forKey: .exportDirectoryPath)?.trimmingCharacters(in: .whitespacesAndNewlines)
        exportDirectoryPath = (raw?.isEmpty == false) ? raw : nil
    }
}

/// `collections.json` next to the `meetings` folder.
public struct CollectionsFile: Sendable {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    /// The file for the storage folder a meeting lives in (`<storage>/meetings/<meeting>`).
    public init(for meeting: MeetingFolder) {
        url = meeting.url.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("collections.json")
    }

    public func load() -> [MeetingCollection] {
        guard FileManager.default.fileExists(atPath: url.path),
              let list = try? JSONCoding.read([MeetingCollection].self, from: url) else { return [] }
        return list
    }

    public func save(_ collections: [MeetingCollection]) throws {
        try JSONCoding.write(collections, to: url)
    }

    /// The context text of the folder a meeting is in, trimmed; empty when it has none.
    public func context(for meta: MeetingMeta) -> String {
        guard let id = meta.collectionID, let collection = load().first(where: { $0.id == id }) else { return "" }
        return collection.context.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The name of the folder a meeting is in.
    public func name(for meta: MeetingMeta) -> String? {
        guard let id = meta.collectionID else { return nil }
        return load().first { $0.id == id }?.name
    }
}

/// What is being dragged in the sidebar, as the plain string the drag carries.
public enum SidebarDrag: Equatable, Sendable {
    /// A recording, by its folder's path.
    case meeting(String)
    /// A user folder, by id.
    case collection(String)

    public var payload: String {
        switch self {
        case .meeting(let path): "remeet-meeting:\(path)"
        case .collection(let id): "remeet-folder:\(id)"
        }
    }

    public init?(payload: String) {
        if payload.hasPrefix("remeet-meeting:") {
            self = .meeting(String(payload.dropFirst("remeet-meeting:".count)))
        } else if payload.hasPrefix("remeet-folder:") {
            self = .collection(String(payload.dropFirst("remeet-folder:".count)))
        } else {
            return nil
        }
    }
}

public enum SidebarList {
    /// Rows shown before "Show more": a folder's dropdown and a date group.
    public static let folderLimit = 5
    public static let groupLimit = 8

    /// The rows to show and how many are behind "Show more". The selected row always stays
    /// visible, so opening a meeting from elsewhere never highlights something hidden.
    public static func visible<T>(_ items: [T], limit: Int, showAll: Bool, keep: (T) -> Bool = { _ in false })
        -> (rows: [T], hidden: Int) {
        guard !showAll, items.count > limit else { return (items, 0) }
        let rows = items.enumerated().filter { $0.offset < limit || keep($0.element) }.map(\.element)
        return (rows, items.count - rows.count)
    }

    /// `moving` placed just before `target`, for dragging folders into a new order.
    public static func reordered(_ list: [MeetingCollection], moving: String, before target: String) -> [MeetingCollection] {
        guard moving != target, let item = list.first(where: { $0.id == moving }) else { return list }
        var result = list.filter { $0.id != moving }
        guard let index = result.firstIndex(where: { $0.id == target }) else { return list }
        // Dragging downward lands after the target, so the last place can be reached.
        let wasAbove = (list.firstIndex { $0.id == moving } ?? 0) < (list.firstIndex { $0.id == target } ?? 0)
        result.insert(item, at: wasAbove ? index + 1 : index)
        return result
    }
}
