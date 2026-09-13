import Foundation

enum JSONValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:
            try container.encodeNil()
        case let .bool(value):
            try container.encode(value)
        case let .number(value):
            try container.encode(value)
        case let .string(value):
            try container.encode(value)
        case let .array(value):
            try container.encode(value)
        case let .object(value):
            try container.encode(value)
        }
    }

    var objectValue: [String: JSONValue]? {
        guard case let .object(value) = self else { return nil }
        return value
    }

    var arrayValue: [JSONValue]? {
        guard case let .array(value) = self else { return nil }
        return value
    }

    var stringValue: String? {
        guard case let .string(value) = self else { return nil }
        return value
    }

    var integerValue: Int? {
        guard case let .number(value) = self, value.rounded() == value else { return nil }
        return Int(value)
    }
}

struct SessionSummary: Decodable, Identifiable, Equatable, Sendable {
    let sessionId: String
    let updatedAt: Int64
    let running: Bool
    let blank: Bool
    let cwd: String?
    let title: String?

    var id: String { sessionId }

    private enum CodingKeys: String, CodingKey {
        case sessionId
        case updatedAt
        case running
        case blank
        case cwd
        case projections
    }

    private struct Projections: Decodable {
        let values: [String: JSONValue]
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sessionId = try container.decode(String.self, forKey: .sessionId)
        updatedAt = try container.decode(Int64.self, forKey: .updatedAt)
        running = try container.decode(Bool.self, forKey: .running)
        blank = try container.decode(Bool.self, forKey: .blank)
        cwd = try container.decodeIfPresent(String.self, forKey: .cwd)
        title = try container.decodeIfPresent(Projections.self, forKey: .projections)?
            .values["title"]?.stringValue
    }

    var displayTitle: String {
        if let title, !title.isEmpty { return title }
        if let cwd, !cwd.isEmpty {
            let name = URL(fileURLWithPath: cwd).lastPathComponent
            if !name.isEmpty { return name }
        }
        return String(sessionId.prefix(8))
    }

    var workspaceTitle: String {
        guard let cwd, !cwd.isEmpty else { return "No working directory" }
        let name = URL(fileURLWithPath: cwd).lastPathComponent
        return name.isEmpty ? cwd : name
    }
}

struct SessionListValue: Decodable {
    let items: [SessionSummary]
}

struct SessionCreateValue: Decodable {
    let sessionId: String
}

struct AcceptedValue: Decodable {
    let accepted: Bool
}

struct SessionEvent: Decodable, Equatable, Sendable {
    let type: String
    let seq: Int
    let time: Int64
    let data: JSONValue
}

struct SessionHistoryRecord: Decodable, Equatable, Sendable {
    let type: String
    let event: SessionEvent
}

struct SessionPage: Decodable, Equatable, Sendable {
    let records: [SessionHistoryRecord]
    let hasMore: Bool
}

struct SessionFollowSnapshot: Decodable, Equatable, Sendable {
    let cursor: Int
    let records: [SessionHistoryRecord]
    let hasMore: Bool
    let assistantStream: AssistantStreamBaseline?
}

struct AssistantStreamBaseline: Decodable, Equatable, Sendable {
    let revision: Int
    let activeAttempt: AssistantStreamAttempt?
}

struct AssistantStreamAttempt: Decodable, Equatable, Sendable {
    let attemptId: String
    let turn: Int
    let step: Int
    let stream: [JSONValue]
}

enum SessionFollowFrame: Decodable, Equatable, Sendable {
    case snapshot(SessionFollowSnapshot)
    case event(SessionEvent)
    case assistantStream(JSONValue)

    private enum CodingKeys: String, CodingKey {
        case type
        case cursor
        case records
        case hasMore
        case assistantStream
        case event
        case frame
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .type) {
        case "snapshot":
            self = .snapshot(SessionFollowSnapshot(
                cursor: try container.decode(Int.self, forKey: .cursor),
                records: try container.decode([SessionHistoryRecord].self, forKey: .records),
                hasMore: try container.decode(Bool.self, forKey: .hasMore),
                assistantStream: try container.decodeIfPresent(
                    AssistantStreamBaseline.self,
                    forKey: .assistantStream
                )
            ))
        case "event":
            self = .event(try container.decode(SessionEvent.self, forKey: .event))
        case "assistant-stream":
            self = .assistantStream(try container.decode(JSONValue.self, forKey: .frame))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type,
                in: container,
                debugDescription: "Unknown session follow frame"
            )
        }
    }
}

struct ChatMessage: Identifiable, Equatable, Sendable {
    enum Role: Sendable {
        case user
        case assistant
    }

    let id: String
    let role: Role
    var text: String
}

struct ToolActivity: Identifiable, Equatable, Sendable {
    enum State: Equatable, Sendable {
        case running
        case succeeded
        case failed
    }

    let id: String
    let name: String
    let arguments: String
    var result: String?
    var state: State
}

struct TurnPresentation: Identifiable, Equatable, Sendable {
    enum State: Equatable, Sendable {
        case running
        case completed
        case cancelled
        case failed(String?)
        case interrupted
    }

    let id: Int
    var startedAt: Int64
    var messages: [ChatMessage] = []
    var reasoning = ""
    var tools: [ToolActivity] = []
    var state: State = .running
    var isStreaming = false
}

struct ConversationProjection: Equatable, Sendable {
    private static let provisionalTurnId = Int.min

    private(set) var turns: [TurnPresentation] = []
    private var turnIndices: [Int: Int] = [:]
    private var toolLocations: [String: (turn: Int, index: Int)] = [:]
    private var pendingHumanMessages: [ChatMessage] = []
    private var liveAttemptId: String?
    private var liveMessageId: String?

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.turns == rhs.turns
    }

    mutating func replace(with records: [SessionHistoryRecord]) {
        self = ConversationProjection()
        for record in records where record.type == "event" {
            apply(record.event)
        }
        if !pendingHumanMessages.isEmpty {
            turns.append(TurnPresentation(
                id: Self.provisionalTurnId,
                startedAt: 0,
                messages: pendingHumanMessages
            ))
            turnIndices[Self.provisionalTurnId] = turns.count - 1
            pendingHumanMessages.removeAll()
        }
    }

    mutating func apply(_ event: SessionEvent) {
        guard let data = event.data.objectValue else { return }
        switch event.type {
        case "turn/start":
            guard let turn = data["turn"]?.integerValue else { return }
            _ = ensureTurn(turn, time: event.time)
        case "turn/end":
            guard let turn = data["turn"]?.integerValue else { return }
            let index = ensureTurn(turn, time: event.time)
            let kind = data["reason"]?.objectValue?["kind"]?.stringValue
            switch kind {
            case "completed":
                turns[index].state = .completed
            case "aborted":
                turns[index].state = .cancelled
            case "interrupted":
                turns[index].state = .interrupted
            case "error":
                let message = data["reason"]?.objectValue?["error"]?
                    .objectValue?["message"]?.stringValue
                turns[index].state = .failed(message)
            default:
                turns[index].state = .failed(nil)
            }
            turns[index].isStreaming = false
        case "user/message":
            guard data["source"]?.objectValue?["kind"]?.stringValue == "user" else { return }
            let text = textContent(data["content"])
            guard !text.isEmpty else { return }
            let message = ChatMessage(id: "event-\(event.seq)", role: .user, text: text)
            if let index = turns.indices.last {
                appendMessage(message, to: index)
            } else {
                pendingHumanMessages.append(message)
            }
        case "assistant/message":
            guard let turn = data["turn"]?.integerValue,
                  let message = data["message"]?.objectValue else { return }
            let index = ensureTurn(turn, time: event.time)
            let blocks = message["content"]?.arrayValue ?? []
            let text = textContent(.array(blocks))
            let reasoning = reasoningContent(.array(blocks))
            if !reasoning.isEmpty {
                turns[index].reasoning = reasoning
            }
            turns[index].messages.removeAll { $0.id.hasPrefix("live-") }
            if !text.isEmpty {
                appendMessage(
                    ChatMessage(id: "event-\(event.seq)", role: .assistant, text: text),
                    to: index
                )
            }
            turns[index].isStreaming = false
            liveAttemptId = nil
            liveMessageId = nil
        case "tool/call":
            guard let turn = data["turn"]?.integerValue,
                  let callId = data["callId"]?.stringValue,
                  let name = data["name"]?.stringValue else { return }
            let index = ensureTurn(turn, time: event.time)
            if toolLocations[callId] == nil {
                turns[index].tools.append(ToolActivity(
                    id: callId,
                    name: name,
                    arguments: data["arguments"]?.stringValue ?? "",
                    state: .running
                ))
                toolLocations[callId] = (turn, turns[index].tools.count - 1)
            }
        case "tool/result":
            guard let message = data["message"]?.objectValue,
                  let content = message["content"]?.arrayValue,
                  let block = content.first?.objectValue,
                  let callId = block["toolCallId"]?.stringValue,
                  let location = toolLocations[callId],
                  let turnIndex = turnIndices[location.turn],
                  turns[turnIndex].tools.indices.contains(location.index) else { return }
            turns[turnIndex].tools[location.index].result = textContent(block["content"])
            turns[turnIndex].tools[location.index].state =
                block["isError"] == .bool(true) ? .failed : .succeeded
        default:
            break
        }
    }

    mutating func applyAssistantFrame(_ frame: JSONValue) {
        guard let value = frame.objectValue,
              let type = value["type"]?.stringValue else { return }
        switch type {
        case "start":
            guard let turn = value["turn"]?.integerValue,
                  let attemptId = value["attemptId"]?.stringValue else { return }
            let index = ensureTurn(turn, time: Int64(Date().timeIntervalSince1970 * 1_000))
            liveAttemptId = attemptId
            liveMessageId = "live-\(attemptId)"
            turns[index].isStreaming = true
        case "chunk":
            guard value["attemptId"]?.stringValue == liveAttemptId,
                  let chunk = value["chunk"]?.objectValue,
                  let chunkType = chunk["type"]?.stringValue,
                  let turnIndex = turns.indices.last else { return }
            if chunkType == "text-delta", let text = chunk["text"]?.stringValue {
                appendLiveText(text, turnIndex: turnIndex)
            } else if chunkType == "reasoning-delta", let text = chunk["text"]?.stringValue {
                turns[turnIndex].reasoning += text
            } else if chunkType == "block-end",
                      let block = chunk["block"]?.objectValue,
                      block["type"]?.stringValue == "text",
                      let text = block["text"]?.stringValue,
                      turns[turnIndex].messages.last?.id != liveMessageId {
                appendLiveText(text, turnIndex: turnIndex)
            }
        case "end":
            if let turnIndex = turns.indices.last {
                turns[turnIndex].isStreaming = false
            }
        default:
            break
        }
    }

    private mutating func ensureTurn(_ turn: Int, time: Int64) -> Int {
        if let index = turnIndices[turn] { return index }
        if let provisionalIndex = turnIndices.removeValue(forKey: Self.provisionalTurnId) {
            let pending = turns.remove(at: provisionalIndex).messages
            rebuildTurnIndices()
            turns.append(TurnPresentation(
                id: turn,
                startedAt: time,
                messages: pending
            ))
        } else {
            turns.append(TurnPresentation(
                id: turn,
                startedAt: time,
                messages: pendingHumanMessages
            ))
            pendingHumanMessages.removeAll()
        }
        let index = turns.count - 1
        turnIndices[turn] = index
        return index
    }

    private mutating func rebuildTurnIndices() {
        turnIndices = Dictionary(uniqueKeysWithValues: turns.enumerated().map {
            ($0.element.id, $0.offset)
        })
    }

    private mutating func appendMessage(_ message: ChatMessage, to turnIndex: Int) {
        if let index = turns[turnIndex].messages.firstIndex(where: { $0.id == message.id }) {
            turns[turnIndex].messages[index] = message
        } else {
            turns[turnIndex].messages.append(message)
        }
    }

    private mutating func appendLiveText(_ text: String, turnIndex: Int) {
        guard let liveMessageId else { return }
        if let index = turns[turnIndex].messages.firstIndex(where: { $0.id == liveMessageId }) {
            turns[turnIndex].messages[index].text += text
        } else {
            turns[turnIndex].messages.append(
                ChatMessage(id: liveMessageId, role: .assistant, text: text)
            )
        }
    }
}

private func textContent(_ value: JSONValue?) -> String {
    guard let blocks = value?.arrayValue else { return "" }
    return blocks.compactMap { block in
        guard let object = block.objectValue else { return nil }
        switch object["type"]?.stringValue {
        case "text":
            return object["text"]?.stringValue
        case "tool-result":
            return textContent(object["content"])
        default:
            return nil
        }
    }.joined()
}

private func reasoningContent(_ value: JSONValue?) -> String {
    guard let blocks = value?.arrayValue else { return "" }
    return blocks.compactMap { block in
        guard let object = block.objectValue,
              object["type"]?.stringValue == "reasoning" else { return nil }
        return object["text"]?.stringValue
    }.joined()
}
