import Foundation

/// Where unsent drafts are kept between launches: a file of their own in Application Support for
/// the app, since a pasted prompt can be long and the defaults file is rewritten whole; the given
/// defaults for tests and previews, which keep their own.
protocol DraftStore {
    func read() -> [String: String]
    /// False when nothing was written, so the caller keeps its other copy.
    @discardableResult func write(_ drafts: [String: String]) -> Bool
}

/// `Drafts.json` in the app's Application Support directory.
struct FileDrafts: DraftStore {
    let url: URL

    static var standard: FileDrafts {
        let support = URL.applicationSupportDirectory.appending(path: Bundle.main.bundleIdentifier ?? "Tether",
                                                                directoryHint: .isDirectory)
        return FileDrafts(url: support.appending(path: "Drafts.json"))
    }

    func read() -> [String: String] {
        (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode([String: String].self, from: $0) } ?? [:]
    }

    @discardableResult func write(_ drafts: [String: String]) -> Bool {
        guard let data = try? JSONEncoder().encode(drafts) else { return false }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }
}

/// In a defaults domain, as tests and previews keep everything.
struct DefaultsDrafts: DraftStore {
    let defaults: UserDefaults
    let key: String

    func read() -> [String: String] {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode([String: String].self, from: $0) } ?? [:]
    }

    @discardableResult func write(_ drafts: [String: String]) -> Bool {
        guard let data = try? JSONEncoder().encode(drafts) else { return false }
        defaults.set(data, forKey: key)
        return true
    }
}
