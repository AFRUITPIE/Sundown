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

/// The members of a JSON-RPC message, found without decoding it.
@Suite
struct WireMessageTests {
    private func message(_ line: String) -> WireMessage? { WireMessage(Data(line.utf8)) }
    private func text(_ data: Data?) -> String? { data.map { String(decoding: $0, as: UTF8.self) } }

    @Test func aResponse() throws {
        let m = try #require(message(#"{"id":7,"result":{"a":[1,2,{"b":"}]"}],"c":null}}"#))
        #expect(text(m.id) == "7")
        #expect(text(m.result) == #"{"a":[1,2,{"b":"}]"}],"c":null}"#)
        #expect(m.method == nil && m.params == nil && m.error == nil)
    }

    @Test func anErrorResponse() throws {
        let m = try #require(message(#"{"id":12,"error":{"code":-32010,"message":"Thread \"x\" not found"}}"#))
        #expect(text(m.id) == "12")
        #expect(text(m.error) == #"{"code":-32010,"message":"Thread \"x\" not found"}"#)
        #expect(m.result == nil)
    }

    @Test func aNotificationDecodesStraightFromItsParams() throws {
        let line = #"{"method":"item/agentMessage/delta","params":{"threadId":"t","seq":3,"itemId":"i","delta":"a \"quote\", {brace} [x] \\ back\\\\"}}"#
        let m = try #require(message(line))
        #expect(m.method == "item/agentMessage/delta")
        #expect(m.id == nil)
        let n = try ServerNotification(method: m.method!, params: try #require(m.params))
        guard case .itemAgentMessageDelta(let delta) = n else {
            Issue.record("expected a delta, got \(n)")
            return
        }
        #expect(delta.delta == #"a "quote", {brace} [x] \ back\\"#)
        #expect(delta.seq == 3)
    }

    @Test func aServerRequestKeepsItsID() throws {
        let m = try #require(message(#"{"id":"req-1","method":"permission/request","params":{"threadId":"t"}}"#))
        #expect(text(m.id) == #""req-1""#)
        #expect(m.method == "permission/request")
        #expect(text(m.params) == #"{"threadId":"t"}"#)
    }

    @Test func membersInAnyOrderWithSpaceBetween() throws {
        let m = try #require(message(" { \"params\" : [ ] ,\t\"unknown\" : true , \"method\" : \"x/y\" , \"n\": -1.5e3 }\r"))
        #expect(m.method == "x/y")
        #expect(text(m.params) == "[ ]")
    }

    @Test func escapesInKeysAndMethodsAreRead() throws {
        let m = try #require(message(#"{"id":3,"method":"thread\/started","s":"ends in a backslash\\","result":{}}"#))
        #expect(text(m.id) == "3")
        #expect(m.method == "thread/started")
        #expect(text(m.result) == "{}")
    }

    @Test func aMethodThatIsntAStringIsNone() throws {
        let m = try #require(message(#"{"id":1,"method":42,"result":null}"#))
        #expect(m.method == nil)
        #expect(text(m.result) == "null")
    }

    @Test func linesThatArentOneObjectAreDropped() {
        for line in ["", "[1,2]", #"{"id":1"#, #"{"id":}"#, #"{"id":1} x"#, #"{"a":"unterminated}"#,
                     #"{"a":{"b":1}"#, #"{"a":1,}"#, #"{id:1}"#, #"{"a":x}"#] {
            #expect(message(line) == nil, "\(line)")
        }
        #expect(message("{}") != nil)
    }
}

/// The client over a transport that answers its calls.
@Suite
struct RPCClientTests {
    @Test func aCallSendsItsTypedParamsAndDecodesItsResult() async throws {
        let transport = WireTransport { method, params in
            guard method == "thread/list" else { return nil }
            return ["threads": [["threadId": "a", "cwd": "/w", "updatedAt": 5, "status": "idle", "title": "One"]]]
        }
        let client = RPCClient(transport: transport)
        await client.start()

        let result = try await client.call(Methods.ThreadList.self, .init(limit: 20))

        #expect(result.threads.map(\.threadId) == ["a"])
        #expect(result.threads.first?.title == "One")
        let sent = try #require(await transport.sent.first)
        #expect(sent["id"]?.intValue == 1)
        #expect(sent["method"]?.stringValue == "thread/list")
        #expect(sent["params"]?["limit"]?.intValue == 20)
        await client.close()
    }

    @Test func anErrorResponseThrowsItsCodeAndMessage() async throws {
        let transport = WireTransport { _, _ in nil }
        let client = RPCClient(transport: transport)
        await client.start()

        let error = await #expect(throws: RPCError.self) {
            _ = try await client.call(Methods.ThreadDelete.self, .init(threadId: "gone"))
        }
        #expect(error?.code == -32601)
        #expect(error?.message == "not scripted")
        await client.close()
    }

    @Test func aServerRequestIsAnsweredWithItsOwnID() async throws {
        let transport = WireTransport { _, _ in nil }
        let client = RPCClient(transport: transport)
        let received = Received<ServerRequest>()
        await client.setServerRequestHandler { request in
            await received.append(request)
            return ["behavior": "allow"]
        }
        await client.start()

        transport.emit(#"{"id":"req-7","method":"permission/request","params":{"threadId":"t","requestId":"r","toolUseId":"u","toolName":"Bash","input":{"command":"ls"}}}"#)
        transport.emit(#"{"id":8,"method":"something/new","params":{"threadId":"t","requestId":"r2"}}"#)
        try await waitUntil { await transport.sent.count == 2 }

        let requests = await received.values
        guard case .permissionRequest(let p) = requests.first else {
            Issue.record("expected a permission request, got \(requests)")
            return
        }
        #expect(p.input["command"]?.stringValue == "ls")
        guard case .unknown(let method, let params) = requests.last else {
            Issue.record("expected an unknown request, got \(requests)")
            return
        }
        #expect(method == "something/new")
        #expect(params["requestId"]?.stringValue == "r2")
        let answers = await transport.sent
        #expect(Set(answers.compactMap { $0["id"] }) == [.string("req-7"), .number(8)])
        #expect(answers.allSatisfy { $0["result"]?["behavior"]?.stringValue == "allow" && $0["method"] == nil })
        await client.close()
    }
}

/// A host's connection over the wire: what it asks the daemon for, and what it makes of what comes back.
@MainActor
@Suite(.serialized)
struct HostWireTests {
    @Test func itOptsOutOfWhatNothingReads() async throws {
        let transport = WireTransport(responder: daemon)
        let connection = connection(transport)
        await connection.connect()

        let initialize = try #require(await transport.sent.first { $0["method"]?.stringValue == "initialize" })
        let optedOut = initialize["params"]?["capabilities"]?["optOutNotificationMethods"]?.arrayValue?.compactMap(\.stringValue)
        #expect(Set(optedOut ?? []) == [
            "item/reasoning/delta", "item/toolCall/inputDelta", "thread/tokenUsage/updated", "thread/queuedInput",
            "thread/commandsChanged", "thread/notification", "thread/hook", "thread/rawEvent", "thread/stderr",
        ])
        await connection.disconnect()
    }

    /// What the daemon leaves out still takes its seqs: the next one a chat gets skips them.
    @Test func aChatTakesTheSeqsSkippedForIt() async throws {
        let transport = WireTransport(responder: daemon)
        let connection = connection(transport)
        await connection.connect()
        let thread = connection.thread("t")

        transport.emit(["method": "thread/status/changed", "params": ["threadId": "t", "seq": 3, "status": "running"]])
        transport.emit(["method": "thread/status/changed", "params": ["threadId": "t", "seq": 9, "status": "idle"]])
        try await waitUntil { thread.lastSeq == 9 }

        #expect(thread.status == .idle)
        await connection.disconnect()
    }

    private func connection(_ transport: WireTransport) -> HostConnection {
        HostConnection(host: HostConfig(name: "wire", kind: .ssh(destination: "wire")), transportProvider: { _ in transport })
    }
}

/// Enough of a daemon for a connection to come up.
@Sendable private func daemon(_ method: String, _ params: JSONValue) -> JSONValue? {
    switch method {
    case "initialize":
        let result = InitializeResult(
            serverInfo: .init(name: "tether", version: "test"),
            protocolVersion: tetherProtocolVersion,
            host: .init(hostname: "wire", platform: "linux", arch: "arm64", home: "/home/dev", pid: 1, mode: .daemon),
            claude: .init(path: "/usr/bin/claude", version: "test"))
        return try? JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(result))
    case "thread/list": return ["threads": []]
    case "project/list": return ["projects": []]
    case "model/list": return ["models": []]
    case "thread/delete": return [:]
    default: return nil
    }
}

/// Lines in and out: what the client sent, and a responder for its calls (nil answers with an error).
private actor WireTransport: Transport {
    typealias Responder = @Sendable (_ method: String, _ params: JSONValue) -> JSONValue?

    private let responder: Responder
    private let stream: AsyncThrowingStream<Data, any Error>
    private let continuation: AsyncThrowingStream<Data, any Error>.Continuation
    private(set) var sent: [JSONValue] = []

    init(responder: @escaping Responder) {
        self.responder = responder
        (stream, continuation) = AsyncThrowingStream.makeStream()
    }

    nonisolated func lines() -> AsyncThrowingStream<Data, any Error> { stream }

    func send(_ line: Data) async throws {
        let message = try JSONDecoder().decode(JSONValue.self, from: line)
        sent.append(message)
        guard let id = message["id"], let method = message["method"]?.stringValue else { return }
        if let result = responder(method, message["params"] ?? [:]) {
            emit(["id": id, "result": result])
        } else {
            emit(["id": id, "error": ["code": -32601, "message": "not scripted"]])
        }
    }

    func close() async { continuation.finish() }

    nonisolated func emit(_ line: String) {
        continuation.yield(Data(line.utf8))
    }

    nonisolated func emit(_ message: JSONValue) {
        continuation.yield(try! JSONEncoder().encode(message))
    }
}

private actor Received<Value: Sendable> {
    private(set) var values: [Value] = []
    func append(_ value: Value) { values.append(value) }
}

private enum WireTestError: Error { case timeout }

private func waitUntil(isolation: isolated (any Actor)? = #isolation, _ condition: () async -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(2)
    while await !condition() {
        if ContinuousClock.now > deadline { throw WireTestError.timeout }
        try await Task.sleep(for: .milliseconds(5))
    }
}
