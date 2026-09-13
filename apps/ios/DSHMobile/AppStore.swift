import Foundation
import Observation

@MainActor
@Observable
final class AppStore {
    enum ConnectionState: Equatable {
        case unconfigured
        case connecting
        case connected
        case reconnecting
        case suspended
        case failed(String)
    }

    private(set) var connectionState: ConnectionState = .unconfigured
    private(set) var sessions: [SessionSummary] = []
    private(set) var selectedSessionId: String?
    private(set) var conversation = ConversationProjection()
    private(set) var isConversationLoading = false
    private(set) var isLoadingOlder = false
    private(set) var hasOlderHistory = false
    private(set) var reconnectAttempt = 0
    private(set) var isSending = false
    private(set) var isCancelling = false
    private(set) var conversationError: String?
    private(set) var conversationErrorAllowsRetry = true
    var composerText = ""

    private let client: HostClient
    private var followTask: Task<Void, Never>?
    private var followQuiescenceTask: Task<Void, Never>?
    private var resumeTask: Task<Void, Never>?
    private var durableRecords: [SessionHistoryRecord] = []
    private var historyCursor = -1
    private var followGeneration = 0
    private var isConfigured = false
    private var isApplicationActive = true
    private let defaults: UserDefaults
    private let lastSessionKey = "whale-girl-last-session-id"

    init(
        client: HostClient = HostClient(),
        defaults: UserDefaults = .standard
    ) {
        self.client = client
        self.defaults = defaults
    }

    var selectedSession: SessionSummary? {
        sessions.first { $0.sessionId == selectedSessionId }
    }

    var groupedSessions: [(cwd: String, sessions: [SessionSummary])] {
        let grouped = Dictionary(grouping: sessions) { $0.cwd ?? "" }
        return grouped.map { cwd, sessions in
            (cwd, sessions.sorted { $0.updatedAt > $1.updatedAt })
        }.sorted { left, right in
            (left.sessions.first?.updatedAt ?? 0) > (right.sessions.first?.updatedAt ?? 0)
        }
    }

    func connect(address: String) async {
        guard connectionState != .connecting else { return }
        WhaleDiagnostics.session.debug("connect requested")
        connectionState = .connecting
        resumeTask?.cancel()
        followTask?.cancel()
        followGeneration += 1
        do {
            _ = try await client.configure(address: address)
            isConfigured = true
            connectionState = .connected
            try await refreshSessions()
            WhaleDiagnostics.session.debug("connect completed")
        } catch {
            isConfigured = false
            connectionState = .failed(error.localizedDescription)
            let fields = WhaleDiagnostics.errorFields(error)
            WhaleDiagnostics.session.error(
                "connect failed domain=\(fields.domain, privacy: .public) code=\(fields.code)"
            )
        }
    }

    func refreshSessions() async throws {
        let value: SessionListValue = try await client.call(
            "session/list",
            args: ["_request": .object([:])]
        )
        sessions = value.items
        WhaleDiagnostics.session.debug("Session list installed count=\(value.items.count)")
        #if DEBUG
        if selectedSessionId == nil,
           ProcessInfo.processInfo.environment["WHALE_GIRL_HOST_URL"] != nil,
           let first = sessions.first {
            WhaleDiagnostics.console("session", "diagnostic Host auto-selected first Session")
            selectSession(first.sessionId)
        }
        #endif
        if selectedSessionId == nil,
           let restored = defaults.string(forKey: lastSessionKey),
           sessions.contains(where: { $0.sessionId == restored }) {
            selectSession(restored)
        }
        if let selectedSessionId,
           !sessions.contains(where: { $0.sessionId == selectedSessionId }) {
            selectSession(nil)
        }
    }

    func createSession(cwd: String) async {
        let trimmed = cwd.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            let value: SessionCreateValue = try await client.call(
                "session/create",
                args: ["request": .object(["cwd": .string(trimmed)])]
            )
            try await refreshSessions()
            selectSession(value.sessionId)
        } catch {
            conversationErrorAllowsRetry = true
            conversationError = error.localizedDescription
        }
    }

    func selectSession(_ sessionId: String?) {
        guard selectedSessionId != sessionId else { return }
        WhaleDiagnostics.interaction.debug(
            "Session selection changed hasSelection=\(sessionId != nil)"
        )
        followTask?.cancel()
        followGeneration += 1
        selectedSessionId = sessionId
        if let sessionId {
            defaults.set(sessionId, forKey: lastSessionKey)
        } else {
            defaults.removeObject(forKey: lastSessionKey)
        }
        conversation = ConversationProjection()
        conversationError = nil
        durableRecords = []
        historyCursor = -1
        hasOlderHistory = false
        isConversationLoading = sessionId != nil
        guard let sessionId, isApplicationActive else { return }
        startFollowing(sessionId)
    }

    func loadOlderHistory() async {
        guard let selectedSessionId,
              hasOlderHistory,
              !isLoadingOlder,
              conversation.turns.last?.state != .running,
              let beforeSeq = durableRecords.first?.event.seq else { return }
        isLoadingOlder = true
        WhaleDiagnostics.interaction.debug("older history requested")
        defer { isLoadingOlder = false }
        do {
            let page: SessionPage = try await client.call(
                "session/page",
                args: [
                    "request": .object([
                        "address": .object([
                            "kind": .string("session"),
                            "sessionId": .string(selectedSessionId)
                        ]),
                        "throughSeq": .number(Double(historyCursor)),
                        "beforeSeq": .number(Double(beforeSeq)),
                        "maxMessages": .number(80)
                    ])
                ]
            )
            let existing = Set(durableRecords.map(\.event.seq))
            durableRecords = page.records.filter { !existing.contains($0.event.seq) }
                + durableRecords
            durableRecords.sort { $0.event.seq < $1.event.seq }
            conversation.replace(with: durableRecords)
            hasOlderHistory = page.hasMore
            WhaleDiagnostics.session.debug(
                "older history installed records=\(page.records.count) hasMore=\(page.hasMore)"
            )
        } catch {
            conversationErrorAllowsRetry = true
            conversationError = error.localizedDescription
            let fields = WhaleDiagnostics.errorFields(error)
            WhaleDiagnostics.session.error(
                "older history failed domain=\(fields.domain, privacy: .public) code=\(fields.code)"
            )
        }
    }

    func send() {
        let text = composerText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let selectedSessionId, !isSending else { return }
        composerText = ""
        isSending = true
        WhaleDiagnostics.interaction.debug("prompt submission started")
        Task {
            defer { isSending = false }
            do {
                let _: AcceptedValue = try await client.call(
                    "session/prompt",
                    args: [
                        "request": .object([
                            "requestId": .string(UUID().uuidString.lowercased()),
                            "sessionId": .string(selectedSessionId),
                            "mode": .string("queue"),
                            "content": .array([
                                .object(["type": .string("text"), "text": .string(text)])
                            ]),
                            "clientTimeZone": .string(TimeZone.current.identifier)
                        ])
                    ]
                )
                WhaleDiagnostics.interaction.debug("prompt submission accepted")
            } catch {
                composerText = text
                conversationErrorAllowsRetry = true
                conversationError = error.localizedDescription
                let fields = WhaleDiagnostics.errorFields(error)
                WhaleDiagnostics.interaction.error(
                    "prompt submission failed domain=\(fields.domain, privacy: .public) code=\(fields.code)"
                )
            }
        }
    }

    func cancel() {
        guard let selectedSessionId, !isCancelling else { return }
        isCancelling = true
        WhaleDiagnostics.interaction.debug("turn cancellation requested")
        Task {
            defer { isCancelling = false }
            do {
                let _: AcceptedValue = try await client.call(
                    "session/cancel",
                    args: [
                        "request": .object(["sessionId": .string(selectedSessionId)])
                    ]
                )
                WhaleDiagnostics.interaction.debug("turn cancellation accepted")
            } catch {
                conversationErrorAllowsRetry = true
                conversationError = error.localizedDescription
            }
        }
    }

    func dismissError() {
        conversationError = nil
        conversationErrorAllowsRetry = true
    }

    func retrySelectedSession() {
        conversationError = nil
        reconnectAttempt = 0
        guard let selectedSessionId, isApplicationActive else { return }
        connectionState = .reconnecting
        startFollowing(selectedSessionId)
    }

    func applicationDidEnterBackground() {
        guard isApplicationActive else { return }
        WhaleDiagnostics.lifecycle.debug(
            "entering background generation=\(self.followGeneration)"
        )
        WhaleDiagnostics.console(
            "lifecycle",
            "entering background generation=\(followGeneration)"
        )
        isApplicationActive = false
        resumeTask?.cancel()
        resumeTask = nil
        followGeneration += 1
        let task = followTask
        followTask = nil
        task?.cancel()
        followQuiescenceTask = Task {
            await task?.value
        }
        if isConfigured {
            connectionState = .suspended
        }
    }

    func applicationDidBecomeActive() {
        guard !isApplicationActive else { return }
        WhaleDiagnostics.lifecycle.debug(
            "becoming active generation=\(self.followGeneration)"
        )
        WhaleDiagnostics.console(
            "lifecycle",
            "becoming active generation=\(followGeneration)"
        )
        isApplicationActive = true
        guard isConfigured else { return }
        let quiescence = followQuiescenceTask
        followQuiescenceTask = nil
        if let selectedSessionId {
            reconnectAttempt = 0
            connectionState = .reconnecting
            resumeTask = Task {
                await quiescence?.value
                guard !Task.isCancelled,
                      isApplicationActive,
                      self.selectedSessionId == selectedSessionId else { return }
                WhaleDiagnostics.lifecycle.debug(
                    "background follower quiescent; starting replacement"
                )
                WhaleDiagnostics.console(
                    "lifecycle",
                    "old follower quiescent; starting replacement"
                )
                startFollowing(selectedSessionId)
            }
        } else {
            connectionState = .connected
        }
        Task {
            do {
                try await refreshSessions()
            } catch {
                guard !HostClientError.isTransient(error) else { return }
                conversationError = actionableMessage(for: error)
            }
        }
    }

    private func startFollowing(_ sessionId: String) {
        guard isApplicationActive else { return }
        followTask?.cancel()
        followGeneration += 1
        let generation = followGeneration
        WhaleDiagnostics.session.debug("starting follower generation=\(generation)")
        WhaleDiagnostics.console("session", "starting follower generation=\(generation)")
        followTask = Task {
            await follow(sessionId: sessionId, generation: generation)
        }
    }

    private func follow(sessionId: String, generation: Int) async {
        var delay: UInt64 = 1
        while !Task.isCancelled,
              generation == followGeneration,
              isApplicationActive,
              selectedSessionId == sessionId {
            do {
                if delay > 1 { connectionState = .reconnecting }
                let stream = await client.stream(
                    "session/follow",
                    args: [
                        "request": .object([
                            "address": .object([
                                "kind": .string("session"),
                                "sessionId": .string(sessionId)
                            ]),
                            "maxMessages": .number(80),
                            "assistantStream": .bool(true)
                        ])
                    ]
                )
                WhaleDiagnostics.console("session", "follower starting stream for \(sessionId)")
                for try await value in stream {
                    guard generation == followGeneration,
                          isApplicationActive,
                          selectedSessionId == sessionId else {
                        WhaleDiagnostics.console("session", "follower frame dropped: stale generation/session")
                        return
                    }
                    WhaleDiagnostics.console(
                        "session",
                        "follower generation=\(generation) received frame value type=\(value.objectValue?["type"]?.stringValue ?? "unknown")"
                    )
                    do {
                        let frame = try await client.decode(SessionFollowFrame.self, from: value)
                        WhaleDiagnostics.session.debug(
                            "follower generation=\(generation) decoded frame successfully"
                        )
                        WhaleDiagnostics.console(
                            "session",
                            "follower generation=\(generation) decoded frame successfully"
                        )
                        apply(frame)
                        connectionState = .connected
                        reconnectAttempt = 0
                        delay = 1
                    } catch {
                        WhaleDiagnostics.console("session", "follower generation=\(generation) decode error: \(error)")
                        throw error
                    }
                }
            } catch is CancellationError {
                WhaleDiagnostics.console("session", "follower generation=\(generation) cancelled")
                return
            } catch {
                guard !Task.isCancelled,
                      generation == followGeneration,
                      isApplicationActive,
                      selectedSessionId == sessionId else { return }
                guard HostClientError.isTransient(error) else {
                    let value = error as NSError
                    WhaleDiagnostics.session.error(
                        "follower generation=\(generation) terminal domain=\(value.domain, privacy: .public) code=\(value.code)"
                    )
                    WhaleDiagnostics.console(
                        "session",
                        "follower generation=\(generation) terminal domain=\(value.domain) code=\(value.code) desc=\(error.localizedDescription)"
                    )
                    connectionState = .connected
                    isConversationLoading = false
                    conversationErrorAllowsRetry = errorAllowsRetry(error)
                    conversationError = actionableMessage(for: error)
                    return
                }
                connectionState = .reconnecting
                reconnectAttempt += 1
                let value = error as NSError
                WhaleDiagnostics.session.debug(
                    "follower generation=\(generation) retrying domain=\(value.domain, privacy: .public) code=\(value.code) delay=\(delay)"
                )
                WhaleDiagnostics.console(
                    "session",
                    "follower generation=\(generation) retry domain=\(value.domain) code=\(value.code) delay=\(delay) desc=\(error.localizedDescription)"
                )
                try? await Task.sleep(for: .seconds(delay))
                delay = min(delay * 2, 8)
            }
        }
    }

    private func actionableMessage(for error: Error) -> String {
        if case HostClientError.unauthenticated = error {
            return "The Host authorization expired. Return to Sessions, open the connection settings, and paste a fresh URL from dsh web."
        }
        if case HostClientError.httpStreamUnavailable = error {
            return "This dsh Host predates native HTTP streaming. Update and restart dsh on the development machine, then reopen this Session."
        }
        return "\(error.localizedDescription)\n\nCheck the Host or network, then tap Retry."
    }

    private func errorAllowsRetry(_ error: Error) -> Bool {
        switch error as? HostClientError {
        case .unauthenticated, .httpStreamUnavailable:
            return false
        default:
            return true
        }
    }

    private func apply(_ frame: SessionFollowFrame) {
        switch frame {
        case let .snapshot(snapshot):
            WhaleDiagnostics.session.debug(
                "installed snapshot cursor=\(snapshot.cursor) records=\(snapshot.records.count)"
            )
            WhaleDiagnostics.console(
                "session",
                "snapshot installed cursor=\(snapshot.cursor) records=\(snapshot.records.count)"
            )
            durableRecords = snapshot.records
            historyCursor = snapshot.cursor
            hasOlderHistory = snapshot.hasMore
            conversation.replace(with: durableRecords)
            isConversationLoading = false
            conversationError = nil
            if let attempt = snapshot.assistantStream?.activeAttempt {
                conversation.applyAssistantFrame(.object([
                    "type": .string("start"),
                    "attemptId": .string(attempt.attemptId),
                    "turn": .number(Double(attempt.turn)),
                    "step": .number(Double(attempt.step))
                ]))
                for record in attempt.stream {
                    applyCompactStreamRecord(record, attemptId: attempt.attemptId)
                }
            }
        case let .event(event):
            if !durableRecords.contains(where: { $0.event.seq == event.seq }) {
                durableRecords.append(SessionHistoryRecord(type: "event", event: event))
            }
            conversation.apply(event)
            if event.type == "session/title" {
                Task { try? await refreshSessions() }
            }
        case let .assistantStream(frame):
            conversation.applyAssistantFrame(frame)
        }
    }

    private func applyCompactStreamRecord(_ record: JSONValue, attemptId: String) {
        guard let value = record.objectValue,
              let type = value["type"]?.stringValue else { return }
        let memberKey = type == "tool-call-chunks" ? "args" : "texts"
        guard let members = value[memberKey]?.arrayValue else { return }
        let chunkType: String
        switch type {
        case "text-chunks":
            chunkType = "text-delta"
        case "reasoning-chunks":
            chunkType = "reasoning-delta"
        default:
            return
        }
        for member in members {
            guard let text = member.stringValue else { continue }
            conversation.applyAssistantFrame(.object([
                "type": .string("chunk"),
                "attemptId": .string(attemptId),
                "chunk": .object(["type": .string(chunkType), "text": .string(text)])
            ]))
        }
    }
}
