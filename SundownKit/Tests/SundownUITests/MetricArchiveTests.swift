import Foundation
import Testing
@testable import SundownUI

@Suite
struct MetricArchiveTests {
    @Test func keepsTheLatestReportsOnly() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "sundown-metrics-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let archive = MetricArchive(directory: directory, limit: 3)
        for n in 0..<5 { archive.save(["report": n], as: "metrics") }
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false))
        #expect(names.count == 3)
        #expect(names.allSatisfy { $0.contains("-metrics-") && $0.hasSuffix(".json") })
    }
}
