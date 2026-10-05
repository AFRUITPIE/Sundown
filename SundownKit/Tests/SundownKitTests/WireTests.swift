import Foundation
import Testing
import TetherProtocol
@testable import SundownKit

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
        let delta = try #require(n.itemAgentMessageDelta, "expected a delta, got \(n)")
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
@Suite(.timeLimit(.minutes(1)))
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
        try await eventually { await transport.sent.count == 2 }

        let requests = await received.values
        let p = try #require(requests.first?.permissionRequest, "expected a permission request, got \(requests)")
        #expect(p.input["command"]?.stringValue == "ls")
        let unknown = try #require(requests.last?.unknown, "expected an unknown request, got \(requests)")
        #expect(unknown.method == "something/new")
        #expect(unknown.params["requestId"]?.stringValue == "r2")
        let answers = await transport.sent
        #expect(Set(answers.compactMap { $0["id"] }) == [.string("req-7"), .number(8)])
        #expect(answers.allSatisfy { $0["result"]?["behavior"]?.stringValue == "allow" && $0["method"] == nil })
        await client.close()
    }

    /// Streamed output waits for its frame; anything else goes at once and takes it along, in order.
    @Test func streamedOutputWaitsAndAnythingElseTakesItAlong() async throws {
        let transport = WireTransport { _, _ in nil }
        // Longer than the test: only something other than streamed output sends a batch.
        let client = RPCClient(transport: transport, batchInterval: .seconds(60))
        for line in [
            delta(seq: 2, "Hel"), delta(seq: 3, "lo"),
            #"{"method":"thread/status/changed","params":{"threadId":"t","seq":4,"status":"idle"}}"#,
            delta(seq: 5, "!"),
            #"{"method":"item/toolCall/progress","params":{"threadId":"t","seq":6,"itemId":"c","toolName":"Bash","elapsedSeconds":2}}"#,
            #"{"method":"something/new","params":{"threadId":"t","seq":7}}"#,
        ] { transport.emit(line) }
        await client.start()

        var batches: [[ServerNotification]] = []
        for await batch in client.notifications {
            batches.append(batch)
            if batches.count == 2 { break }
        }
        #expect(batches.map { $0.map(\.seq) } == [[2, 3, 4], [5, 6, 7]])
        let unknown = try #require(batches.last?.last?.unknown, "expected an unknown notification, got \(batches)")
        #expect(unknown.method == "something/new")
        #expect(unknown.params["threadId"]?.stringValue == "t")
        await client.close()
    }

    @Test func streamedOutputGoesOnItsOwnAfterAFrame() async throws {
        let transport = WireTransport { _, _ in nil }
        let client = RPCClient(transport: transport, batchInterval: .milliseconds(5))
        transport.emit(delta(seq: 2, "Hi"))
        await client.start()

        let batch = await firstBatch(client.notifications, within: .seconds(2))
        #expect(batch?.map(\.seq) == [2])
        await client.close()
    }

    /// A caller, or a prompt, sees everything the daemon sent before it.
    @Test func aResponseOrARequestTakesTheOutputBeforeItAlong() async throws {
        let transport = WireTransport { method, _ in method == "thread/list" ? ["threads": []] : nil }
        let client = RPCClient(transport: transport, batchInterval: .seconds(60))
        await client.setServerRequestHandler { _ in nil }
        await client.start()
        let notifications = client.notifications

        transport.emit(delta(seq: 2, "a"))
        _ = try await client.call(Methods.ThreadList.self, .init())
        #expect(await firstBatch(notifications, within: .seconds(2))?.map(\.seq) == [2])

        transport.emit(delta(seq: 3, "b"))
        transport.emit(#"{"id":"r","method":"question/request","params":{"threadId":"t","requestId":"r","questions":[]}}"#)
        #expect(await firstBatch(notifications, within: .seconds(2))?.map(\.seq) == [3])
        await client.close()
    }

    private func delta(seq: Int, _ text: String) -> String {
        #"{"method":"item/agentMessage/delta","params":{"threadId":"t","seq":\#(seq),"itemId":"a","delta":"\#(text)"}}"#
    }

    private func firstBatch(_ stream: AsyncStream<[ServerNotification]>, within limit: Duration) async -> [ServerNotification]? {
        await withTaskGroup(of: [ServerNotification]?.self) { group in
            group.addTask {
                var batches = stream.makeAsyncIterator()
                return await batches.next()
            }
            group.addTask {
                try? await Task.sleep(for: limit)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }
}

/// A batch's text deltas for one reply go in as one; nothing else moves.
@MainActor
@Suite
struct DeltaJoiningTests {
    private func delta(_ thread: String = "t", item: String = "a", seq: Int, _ text: String) -> ServerNotification {
        .itemAgentMessageDelta(.init(threadId: thread, seq: seq, itemId: item, delta: text))
    }

    private func status(_ thread: String = "t", seq: Int, _ status: ThreadStatus) -> ServerNotification {
        .threadStatusChanged(.init(threadId: thread, seq: seq, status: status))
    }

    @Test func runsGatherOneReplysDeltasUntilSomethingElseForItsChat() {
        let batch = [
            delta(seq: 1, "a"), delta(seq: 2, "b"), delta("other", seq: 1, "x"), delta(seq: 3, "c"),
            status(seq: 4, .idle), delta(seq: 5, "d"), delta(item: "z", seq: 6, "e"), delta(seq: 7, "f"),
            delta("other", seq: 2, "y"),
        ]
        let runs = HostConnection.textRuns(in: batch).map { $0.map { "\($0.threadId!):\($0.seq!)" } }
        #expect(runs == [["t:1", "t:2", "t:3"], ["other:1", "other:2"], ["t:4"], ["t:5"], ["t:6"], ["t:7"]])
    }

    @Test func joiningKeepsTheOrderAndTheLastSeq() throws {
        let deltas = (1...4).map { ItemAgentMessageDeltaNotification(threadId: "t", seq: $0 + 10, itemId: "a", delta: "\($0)") }
        let joined = try #require(HostConnection.joining(deltas, after: 10))
        #expect(joined.delta == "1234")
        #expect(joined.seq == 14)
        #expect(joined.itemId == "a")
        // Those it has already seen are left out, as one at a time would.
        #expect(HostConnection.joining(deltas, after: 12)?.delta == "34")
        #expect(HostConnection.joining(deltas, after: 14) == nil)
        #expect(HostConnection.joining(deltas, after: 0)?.delta == "1234")
        let unordered = [11, 9, 12].map { ItemAgentMessageDeltaNotification(threadId: "t", seq: $0, itemId: "a", delta: "\($0)") }
        #expect(HostConnection.joining(unordered, after: 0)?.delta == "1112")
    }

    /// Applied as a batch, the reply ends as it would have one notification at a time.
    @Test func aBatchEndsAsOneAtATimeWould() {
        let batch = [
            .itemStarted(.init(threadId: "t", seq: 1, item: .agentMessage(.init(id: "a", createdAt: 1, text: "")))),
            delta(seq: 2, "Hel"), delta(seq: 3, "lo"), delta("other", seq: 1, "?"), delta(seq: 4, " you"),
            .itemUpdated(.init(threadId: "t", seq: 5, item: .agentMessage(.init(id: "a", createdAt: 1, text: "Hi")))),
            delta(seq: 6, " there"), status(seq: 7, .running), delta(seq: 8, "!"),
            // A replay's overlap is dropped, as ever.
            delta(seq: 8, "!"),
        ]
        let batched = HostConnection(host: HostConfig(name: "wire", kind: .local))
        batched.route(batch)
        let single = HostConnection(host: HostConfig(name: "wire", kind: .local))
        for n in batch { single.route([n]) }

        for connection in [batched, single] {
            let thread = connection.thread("t")
            #expect(text(of: "a", in: thread) == "Hi there!")
            #expect(thread.lastSeq == 8)
            #expect(thread.status == .running)
            #expect(thread.streamingReplyID == "a")
            #expect(text(of: "a", in: thread) == textInBox(of: "a", in: thread))
        }
    }

    private func text(of id: String, in thread: ThreadModel) -> String? {
        for case .agentMessage(let m) in thread.items where m.id == id { return m.text }
        return nil
    }

    private func textInBox(of id: String, in thread: ThreadModel) -> String? {
        guard let item = thread.items.first(where: { $0.id == id }), case .agentMessage(let m) = thread.box(for: item).item else { return nil }
        return m.text
    }
}

/// A long reply streamed a token at a time grows in place, in the transcript and in its box, rather
/// than being copied whole for each token.
@MainActor
@Suite
struct StreamedTextTests {
    @Test func aReplyGrowsInPlace() throws {
        let thread = ThreadModel(id: "t")
        thread.loadHistory(items: [.agentMessage(.init(id: "a", createdAt: 1, text: String(repeating: "x", count: 100_000)))],
                           turns: [], seq: 1)
        var storage: [UInt] = [], box: [UInt] = []
        let deltas = 2_000
        for i in 0..<deltas {
            thread.apply(.itemAgentMessageDelta(.init(threadId: "t", seq: i + 2, itemId: "a", delta: "0123456789")))
            try storage.append(#require(address(of: thread.items[0])))
            try box.append(#require(address(of: thread.box(for: thread.items[0]).item)))
        }
        // Copied, the text is somewhere else after every delta: the copy is made while the old one
        // is still held. Grown in place, it moves only when it outgrows its capacity.
        func moves(_ addresses: [UInt]) -> Int { zip(addresses, addresses.dropFirst()).count { $0 != $1 } }
        #expect(moves(storage) < 20)
        #expect(moves(box) < 20)
        let text: String? = if case .agentMessage(let m) = thread.items[0] { m.text } else { nil }
        #expect(text?.utf8.count == 100_000 + 10 * deltas)
        #expect(thread.lastSeq == deltas + 1)
    }

    private func address(of item: Item) -> UInt? {
        guard case .agentMessage(let m) = item else { return nil }
        return m.text.utf8.withContiguousStorageIfAvailable { UInt(bitPattern: $0.baseAddress) } ?? nil
    }
}

/// A host's connection over the wire: what it asks the daemon for, and what it makes of what comes back.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)))
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
        try await eventually { thread.lastSeq == 9 }

        #expect(thread.status == .idle)
        await connection.disconnect()
    }

    /// A prompt still waiting in a deleted chat is let go: its answer task in the client ends, and
    /// a late answer goes nowhere.
    @Test func deletingAChatLetsGoOfItsPrompt() async throws {
        let transport = WireTransport(responder: daemon)
        let connection = connection(transport)
        await connection.connect()
        let thread = connection.thread("t")
        transport.emit(#"{"id":"req-1","method":"permission/request","params":{"threadId":"t","requestId":"p","toolUseId":"u","toolName":"Bash","input":{}}}"#)
        try await eventually { thread.pending.count == 1 }
        let prompt = thread.pending[0]

        await connection.delete(thread)

        #expect(thread.pending.isEmpty)
        #expect(!connection.chats.contains { $0 === thread })
        prompt.respond(["behavior": "allow"])
        try await Task.sleep(for: .milliseconds(100))
        #expect(await !transport.sent.contains { $0["id"] == .string("req-1") })
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

