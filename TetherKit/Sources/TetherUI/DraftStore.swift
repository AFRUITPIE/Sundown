import Foundation

/// Where unsent drafts are kept between launches: a file of their own in Application Support for
/// the app, since a pasted prompt can be long and the defaults file is rewritten whole; the given
/// defaults for tests and previews, which keep their own.
protocol DraftStore: Sendable {
    func readData() -> Data?
    /// False when nothing was written, so the caller keeps its other copy.
    func write(_ data: Data) -> Bool
}

extension DraftStore {
    func read() -> [String: String] { DraftQueue.decode(readData()) }

    @discardableResult func write(_ drafts: [String: String]) -> Bool {
        guard let data = DraftQueue.encode(drafts) else { return false }
        return write(data)
    }
}

/// `Drafts.json` in the app's Application Support directory.
struct FileDrafts: DraftStore {
    let url: URL

    static var standard: FileDrafts {
        let support = URL.applicationSupportDirectory.appending(path: Bundle.main.bundleIdentifier ?? "Tether",
                                                                directoryHint: .isDirectory)
        return FileDrafts(url: support.appending(path: "Drafts.json"))
    }

    func readData() -> Data? { try? Data(contentsOf: url) }

    func write(_ data: Data) -> Bool {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }
}

/// In a defaults domain, as tests and previews keep everything. Defaults are safe to use from any
/// thread.
struct DefaultsDrafts: DraftStore, @unchecked Sendable {
    let defaults: UserDefaults
    let key: String

    func readData() -> Data? { defaults.data(forKey: key) }

    func write(_ data: Data) -> Bool {
        defaults.set(data, forKey: key)
        return true
    }
}

/// Reads and writes a store's drafts off the main thread, one at a time and in order, and writes
/// only what differs from what it holds: encoding every draft and writing the file whole held up
/// the main thread each time typing paused. The file is read ahead as the app starts, so the first
/// composer finds it there.
final class DraftQueue: @unchecked Sendable {
    let store: any DraftStore
    private let queue = DispatchQueue(label: "Tether Drafts", qos: .utility)
    /// What the store holds, as last read or written. Only touched on `queue`.
    private var held: Data?
    /// The last write failed: the next save writes, changed or not. Only touched on `queue`.
    private var failed = false

    init(store: any DraftStore) {
        self.store = store
        queue.async { self.held = store.readData() }
    }

    /// The drafts the store holds, once the read ahead is done.
    func read() -> [String: String] { queue.sync { Self.decode(held) } }

    /// Writes `drafts` once what's queued before it is done, and returns at once.
    func write(_ drafts: [String: String]) {
        queue.async { self.put(drafts) }
    }

    /// Writes `drafts` and waits: at quit, and for the one move from the defaults file, which
    /// needs to know it worked.
    @discardableResult func writeAndWait(_ drafts: [String: String]) -> Bool {
        queue.sync { put(drafts) }
    }

    /// Whether the last write failed, so a save with nothing new should still write.
    var lastWriteFailed: Bool { queue.sync { failed } }

    /// Returns once the writes queued so far are done.
    func waitForWrites() { queue.sync {} }

    @discardableResult private func put(_ drafts: [String: String]) -> Bool {
        guard let data = Self.encode(drafts) else { return false }
        guard data != held || failed else { return true }
        failed = !store.write(data)
        if !failed { held = data }
        return !failed
    }

    /// Sorted keys, so the same drafts are the same bytes.
    static func encode(_ drafts: [String: String]) -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return try? encoder.encode(drafts)
    }

    static func decode(_ data: Data?) -> [String: String] {
        data.flatMap { try? JSONDecoder().decode([String: String].self, from: $0) } ?? [:]
    }
}
