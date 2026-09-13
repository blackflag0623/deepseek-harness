import XCTest
@testable import WhaleGirl

final class ConversationProjectionTests: XCTestCase {
    func testProjectsMessagesThinkingAndToolDetailsIntoOneTurn() {
        var projection = ConversationProjection()
        projection.apply(event(
            type: "turn/start",
            seq: 0,
            data: ["turn": .number(1)]
        ))
        projection.apply(event(
            type: "user/message",
            seq: 1,
            data: [
                "source": .object(["kind": .string("user")]),
                "content": .array([
                    .object(["type": .string("text"), "text": .string("Build it")])
                ])
            ]
        ))
        projection.apply(event(
            type: "tool/call",
            seq: 2,
            data: [
                "turn": .number(1),
                "callId": .string("call-1"),
                "name": .string("view"),
                "arguments": .string(#"{"path":"README.md"}"#)
            ]
        ))
        projection.apply(event(
            type: "tool/result",
            seq: 3,
            data: [
                "turn": .number(1),
                "message": .object([
                    "content": .array([
                        .object([
                            "type": .string("tool-result"),
                            "toolCallId": .string("call-1"),
                            "content": .array([
                                .object(["type": .string("text"), "text": .string("contents")])
                            ])
                        ])
                    ])
                ])
            ]
        ))
        projection.apply(event(
            type: "assistant/message",
            seq: 4,
            data: [
                "turn": .number(1),
                "message": .object([
                    "content": .array([
                        .object(["type": .string("reasoning"), "text": .string("Inspect first")]),
                        .object(["type": .string("text"), "text": .string("Done")])
                    ])
                ])
            ]
        ))

        XCTAssertEqual(projection.turns.count, 1)
        XCTAssertEqual(projection.turns[0].messages.map(\.text), ["Build it", "Done"])
        XCTAssertEqual(projection.turns[0].reasoning, "Inspect first")
        XCTAssertEqual(projection.turns[0].tools[0].result, "contents")
        XCTAssertEqual(projection.turns[0].tools[0].state, .succeeded)
    }

    func testProjectsLiveAssistantChunks() {
        var projection = ConversationProjection()
        projection.applyAssistantFrame(.object([
            "type": .string("start"),
            "attemptId": .string("attempt-1"),
            "turn": .number(2),
            "step": .number(0)
        ]))
        projection.applyAssistantFrame(.object([
            "type": .string("chunk"),
            "attemptId": .string("attempt-1"),
            "chunk": .object(["type": .string("reasoning-delta"), "text": .string("Think")])
        ]))
        projection.applyAssistantFrame(.object([
            "type": .string("chunk"),
            "attemptId": .string("attempt-1"),
            "chunk": .object(["type": .string("text-delta"), "text": .string("Hello")])
        ]))

        XCTAssertEqual(projection.turns[0].reasoning, "Think")
        XCTAssertEqual(projection.turns[0].messages[0].text, "Hello")
        XCTAssertTrue(projection.turns[0].isStreaming)
    }

    func testKeepsAUserMessageWhenHistoryStartsAfterTurnStart() {
        var projection = ConversationProjection()
        projection.replace(with: [
            SessionHistoryRecord(
                type: "event",
                event: event(
                    type: "user/message",
                    seq: 10,
                    data: [
                        "source": .object(["kind": .string("user")]),
                        "content": .array([
                            .object(["type": .string("text"), "text": .string("Earlier prompt")])
                        ])
                    ]
                )
            ),
            SessionHistoryRecord(
                type: "event",
                event: event(
                    type: "assistant/message",
                    seq: 11,
                    data: [
                        "turn": .number(4),
                        "message": .object([
                            "content": .array([
                                .object(["type": .string("text"), "text": .string("Earlier answer")])
                            ])
                        ])
                    ]
                )
            )
        ])

        XCTAssertEqual(projection.turns.count, 1)
        XCTAssertEqual(projection.turns[0].id, 4)
        XCTAssertEqual(projection.turns[0].messages.map(\.text), ["Earlier prompt", "Earlier answer"])
    }

    private func event(
        type: String,
        seq: Int,
        data: [String: JSONValue]
    ) -> SessionEvent {
        SessionEvent(type: type, seq: seq, time: 1_000, data: .object(data))
    }
}
