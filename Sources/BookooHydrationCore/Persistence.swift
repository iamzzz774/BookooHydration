import Foundation

public enum BookooPaths {
    public static func dataDirectory(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        if let root = ProcessInfo.processInfo.environment["BOOKOO_DATA_ROOT"], !root.isEmpty {
            return URL(fileURLWithPath: root, isDirectory: true)
        }
        precondition(ProcessInfo.processInfo.environment["BOOKOO_PREVIEW"] != "1", "Preview requires isolated BOOKOO_DATA_ROOT")
        return homeDirectory.appendingPathComponent("Library/Application Support/BookooHydration", isDirectory: true)
    }

    public static func hydrationURL(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        dataDirectory(homeDirectory: homeDirectory).appendingPathComponent("hydration.json")
    }

    public static func settingsURL(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        dataDirectory(homeDirectory: homeDirectory).appendingPathComponent("settings.json")
    }
}

public enum PersistenceError: Error, LocalizedError {
    case invalidParentDirectory(URL)

    public var errorDescription: String? {
        switch self {
        case .invalidParentDirectory(let url): "无法确定数据目录：\(url.path)"
        }
    }
}

public struct HydrationPersistence {
    public let url: URL

    public init(url: URL = BookooPaths.hydrationURL()) {
        self.url = url
    }

    public func load(defaultTargetML: Double = 2000) throws -> HydrationData {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return HydrationData(dailyTargetML: defaultTargetML)
        }
        return try JSONDecoder().decode(HydrationData.self, from: Data(contentsOf: url))
    }

    public func loadRecoveringCorruptFile(defaultTargetML: Double = 2000) throws -> (data: HydrationData, backupURL: URL?) {
        do {
            return (try load(defaultTargetML: defaultTargetML), nil)
        } catch {
            let backupURL = url.deletingPathExtension()
                .appendingPathExtension("corrupt-\(UUID().uuidString).json")
            try FileManager.default.copyItem(at: url, to: backupURL)
            return (HydrationData(dailyTargetML: defaultTargetML), backupURL)
        }
    }

    public func save(_ hydration: HydrationData) throws {
        try AtomicJSONWriter.write(hydration, to: url)
    }
}

public struct SettingsPersistence {
    public let url: URL

    public init(url: URL = BookooPaths.settingsURL()) {
        self.url = url
    }

    public func load() throws -> AppSettings {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return .defaults
        }
        var settings = try JSONDecoder().decode(AppSettings.self, from: Data(contentsOf: url))
        settings.normalize()
        return settings
    }

    public func save(_ settings: AppSettings) throws {
        var normalized = settings
        normalized.normalize()
        try AtomicJSONWriter.write(normalized, to: url)
    }
}

public enum AtomicJSONWriter {
    public static func write<T: Encodable>(_ value: T, to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        guard !directory.path.isEmpty else { throw PersistenceError.invalidParentDirectory(url) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(value)
        // Data.write(.atomic) writes a sibling temporary file and renames it over the target.
        try data.write(to: url, options: .atomic)
    }
}
