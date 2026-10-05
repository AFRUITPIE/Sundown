import Foundation
import MetricKit
import Observation
import StateReporting
import SundownKit
import os

/// MetricKit, from launch: its daily metric reports and its diagnostics (hangs, crashes, CPU and
/// disk-write exceptions) kept as JSON in Caches/<bundle id>/MetricKit, the latest 30; the wait for
/// the first window's chat as an extended launch task; and the tool-call display as reported
/// state, so the reports' hang and hitch numbers come broken down by it.
///
/// Debug ▸ MetricKit ▸ Simulate MetricKit Payloads, in a run from Xcode, writes sample reports there.
@MainActor
final class Metrics {
    /// Started by the app delegate; one for the app, as MetricKit asks.
    private static var shared: Metrics?

    static func start(_ app: AppModel) {
        guard shared == nil else { return }
        let metrics = Metrics()
        shared = metrics
        metrics.start(app)
    }

    static let layoutDomain: StateReportingDomain = "com.haydenhong.Sundown.layout"
    private nonisolated static let log = Logger(subsystem: Signposts.subsystem, category: "Metrics")

    private let manager = MetricManager(enabledStateReportingDomains: [layoutDomain])
    private let layout = StateReporter.reporter(for: layoutDomain.rawValue, stableMetadata: LayoutState.self, volatileMetadata: Never.self)
    private let archive = MetricArchive.standard

    private func start(_ app: AppModel) {
        let manager = manager, archive = archive
        // Starts measuring now, not when a task gets to run: the launch is what's being timed.
        Task.immediate {
            await manager.trackLaunchTask(id: "first-chat-ready", onTrackingError: { error in
                Self.log.error("Launch task \(error.taskID, privacy: .public) not tracked: \(String(describing: error.reason), privacy: .public)")
            }) {
                await Signposts.launchFinished()
            }
        }
        // Reports arrive about once a day; encoding and writing them is kept off the main thread.
        Task.detached(priority: .utility) {
            for await report in manager.metricReports { archive.save(report, as: "metrics") }
        }
        Task.detached(priority: .utility) {
            for await report in manager.diagnosticReports { archive.save(report, as: "diagnostic-\(report.result.kind)") }
        }
        reportLayout(app)
    }

    /// The layout now, and again whenever Settings changes it. StateReporting records a transition
    /// only when the label or metadata changes, so other settings changing costs nothing.
    private func reportLayout(_ app: AppModel) {
        let appearance = withObservationTracking { app.appearance } onChange: { [weak self] in
            Task { @MainActor in self?.reportLayout(app) }
        }
        let now = LayoutState(toolCalls: appearance.toolCalls.rawValue)
        layout.reportTransition(to: now.toolCalls, stableMetadata: now)
    }
}

/// View ▸ Tool Calls: each choice a state of its own.
private struct LayoutState: ReportableMetadata {
    let toolCalls: String

    var metadataDictionary: [String: ReportableMetadataValue] {
        ["toolCalls": .init(toolCalls)]
    }
}

/// Where the reports are kept, newest last by name, the oldest removed past `limit`.
struct MetricArchive: Sendable {
    let directory: URL
    var limit = 30

    static let standard = MetricArchive(directory: URL.cachesDirectory
        .appending(path: Bundle.main.bundleIdentifier ?? Signposts.subsystem, directoryHint: .isDirectory)
        .appending(path: "MetricKit", directoryHint: .isDirectory))

    func save(_ report: some Encodable, as kind: String) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(report) else { return }
        let files = FileManager.default
        try? files.createDirectory(at: directory, withIntermediateDirectories: true)
        // Milliseconds since 1970 sort as text until the year 2286.
        let name = "\(Int(Date.now.timeIntervalSince1970 * 1000))-\(kind)-\(UUID().uuidString.prefix(8)).json"
        try? data.write(to: directory.appending(path: name), options: .atomic)
        prune()
    }

    func prune() {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false))) ?? []
        for name in names.filter({ $0.hasSuffix(".json") }).sorted().dropLast(limit) {
            try? FileManager.default.removeItem(at: directory.appending(path: name))
        }
    }
}

private extension DiagnosticResult {
    /// For the file's name.
    var kind: String {
        switch self {
        case .crash: "crash"
        case .hang: "hang"
        case .cpuException: "cpu"
        case .diskWriteException: "disk-writes"
        case .appLaunch: "launch"
        @unknown default: "other"
        }
    }
}
