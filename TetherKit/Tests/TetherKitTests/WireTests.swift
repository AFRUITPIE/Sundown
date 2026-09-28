import Foundation
import Testing
import TetherProtocol
@testable import TetherKit

/// Lines from the daemon, as the transport splits them.
@Suite
struct LineSplitterTests {
    private func split(_ chunks: [String], into splitter: inout LineSplitter) -> [String] {
        var lines: [String] = []
        for chunk in chunks {
            splitter.split(Data(chunk.utf8)) { lines.append(String(decoding: $0, as: UTF8.self)) }
        }
        return lines
    }

    @Test func severalLinesInOneChunk() {
        var splitter = LineSplitter()
        #expect(split(["a\nbb\nccc\n"], into: &splitter) == ["a", "bb", "ccc"])
        #expect(splitter.partial.isEmpty)
    }

    @Test func aLineSplitAcrossChunks() {
        var splitter = LineSplitter()
        #expect(split(["{\"a\"", ":1", "}\n{\"b\":", "2}\n{\"c"], into: &splitter) == ["{\"a\":1}", "{\"b\":2}"])
        #expect(String(decoding: splitter.partial, as: UTF8.self) == "{\"c")
        #expect(split([":3}\n"], into: &splitter) == ["{\"c:3}"])
        #expect(splitter.partial.isEmpty)
    }

    @Test func emptyLinesAreSkipped() {
        var splitter = LineSplitter()
        #expect(split(["\n\na\n", "\n", "b", "\n\n"], into: &splitter) == ["a", "b"])
    }

    /// A long line comes out whole, in the buffer it was gathered in, and the splitter keeps
    /// nothing of it afterwards: only what follows its newline.
    @Test func aHugeLineIsHandedOverAndItsBufferLetGo() {
        var splitter = LineSplitter()
        let piece = Data(repeating: UInt8(ascii: "x"), count: 64 * 1024)
        var lines: [Data] = []
        for _ in 0..<128 { splitter.split(piece) { lines.append($0) } }
        #expect(lines.isEmpty)
        #expect(splitter.partial.count == 128 * piece.count)

        splitter.split(Data("x\nnext".utf8)) { lines.append($0) }
        #expect(lines.count == 1)
        #expect(lines.first?.count == 128 * piece.count + 1)
        #expect(lines.first?.allSatisfy { $0 == UInt8(ascii: "x") } == true)
        #expect(String(decoding: splitter.partial, as: UTF8.self) == "next")
    }

    @Test func chunksArriveAtAnyBoundary() {
        let text = (0..<200).map { "{\"n\":\($0),\"s\":\"\(String(repeating: "é", count: $0 % 7))\"}" }.joined(separator: "\n") + "\n"
        let bytes = Data(text.utf8)
        for size in [1, 2, 3, 7, 64, 1000, bytes.count] {
            var splitter = LineSplitter()
            var lines: [String] = []
            var start = bytes.startIndex
            while start < bytes.endIndex {
                let end = min(start + size, bytes.endIndex)
                splitter.split(bytes[start..<end]) { lines.append(String(decoding: $0, as: UTF8.self)) }
                start = end
            }
            #expect(lines == text.split(separator: "\n").map(String.init), "chunks of \(size)")
            #expect(splitter.partial.isEmpty)
        }
    }
}
