import Foundation

/// Finder actions are untrusted URL requests, never authorization or IPC tokens.
/// The app must confirm every selection and validate its live owned mount.
public struct FinderActionRequest: Sendable, Equatable {
    public enum Action: String, Sendable { case keepDownloaded, freeSpace, move, activity }
    public static let maximumSelections = 32
    public let action: Action
    public let paths: [String]
    /// Older callers fail closed on multiple selections instead of acting on only
    /// the first item without displaying the complete confirmation.
    public var path: String? { paths.count == 1 ? paths[0] : nil }
    public init(action: Action, path: String? = nil) throws {
        try self.init(action: action, paths: path.map { [$0] } ?? [])
    }
    public init(action: Action, paths: [String]) throws {
        guard (action != .move || paths.count == 1), paths.count <= Self.maximumSelections, action == .activity || !paths.isEmpty,
              Set(paths.map { URL(fileURLWithPath: $0).standardizedFileURL.path }).count == paths.count else {
            throw CocoaError(.fileReadInvalidFileName)
        }
        for path in paths {
            guard path.hasPrefix("/"), !path.contains("\0"), path.utf8.count <= 4096,
                  !path.split(separator: "/", omittingEmptySubsequences: true).contains(where: { $0 == "." || $0 == ".." }) else { throw CocoaError(.fileReadInvalidFileName) }
        }
        self.action = action; self.paths = paths
        guard url != nil else { throw CocoaError(.fileReadInvalidFileName) }
    }
    public init(url: URL) throws {
        guard url.absoluteString.utf8.count <= 16_384,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme == "clouddrive", components.host == "finder", components.path.isEmpty,
              components.user == nil, components.password == nil, components.port == nil, components.fragment == nil,
              let query = components.queryItems, query.count <= 2,
              Set(query.map(\.name)).count == query.count,
              query.allSatisfy({ ["action", "path", "paths"].contains($0.name) }),
              let raw = query.first(where: { $0.name == "action" })?.value,
              let action = Action(rawValue: raw) else { throw CocoaError(.fileReadInvalidFileName) }
        if let item = query.first(where: { $0.name == "paths" }) {
            guard let json = item.value, let data = json.data(using: .utf8),
                  let paths = try? JSONDecoder().decode([String].self, from: data) else { throw CocoaError(.fileReadInvalidFileName) }
            try self.init(action: action, paths: paths)
        } else {
            try self.init(action: action, path: query.first(where: { $0.name == "path" })?.value)
        }
    }
    public var url: URL? {
        var components = URLComponents(); components.scheme = "clouddrive"; components.host = "finder"
        components.queryItems = [URLQueryItem(name: "action", value: action.rawValue)]
        if let path { components.queryItems?.append(URLQueryItem(name: "path", value: path)) }
        else if !paths.isEmpty {
            guard let data = try? JSONEncoder().encode(paths), let json = String(data: data, encoding: .utf8) else { return nil }
            components.queryItems?.append(URLQueryItem(name: "paths", value: json))
        }
        guard let result = components.url, result.absoluteString.utf8.count <= 16_384 else { return nil }
        return result
    }
    /// Lexical scope only. Never follows symlinks or establishes mount ownership.
    public func relativeSelections(under mountpoint: URL) throws -> [[String]] {
        guard !paths.isEmpty, mountpoint.isFileURL else { throw CocoaError(.fileReadInvalidFileName) }
        let root = mountpoint.standardizedFileURL.pathComponents
        return try paths.map { path in
            let selected = URL(fileURLWithPath: path).standardizedFileURL.pathComponents
            guard selected.count > root.count, Array(selected.prefix(root.count)) == root else { throw CocoaError(.fileReadNoPermission) }
            return Array(selected.dropFirst(root.count))
        }
    }
    public func relativeComponents(under mountpoint: URL) throws -> [String] {
        guard paths.count == 1 else { throw CocoaError(.fileReadInvalidFileName) }
        return try relativeSelections(under: mountpoint)[0]
    }
}
