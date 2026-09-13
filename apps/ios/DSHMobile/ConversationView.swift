import MarkdownUI
import SwiftUI
import UIKit

struct ConversationView: View {
    let store: AppStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            ConnectionBanner(
                state: store.connectionState,
                attempt: store.reconnectAttempt
            )
            if store.isConversationLoading {
                ProgressView("Loading conversation history…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if store.conversation.turns.isEmpty {
                ContentUnavailableView(
                    "No conversation yet",
                    systemImage: "sparkles",
                    description: Text("Send a message to start this dsh session.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                TimelineView(
                    turns: store.conversation.turns,
                    hasOlderHistory: store.hasOlderHistory,
                    isLoadingOlder: store.isLoadingOlder,
                    loadOlder: {
                        Task { await store.loadOlderHistory() }
                    }
                )
            }
        }
        .background {
            ZStack {
                DSHStyle.canvas
                DSHStyle.oceanGradient.opacity(0.055)
                    .ignoresSafeArea()
            }
        }
        .navigationTitle(store.selectedSession?.displayTitle ?? "Conversation")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            ComposerView(store: store)
        }
        .animation(reduceMotion ? nil : .snappy(duration: 0.2), value: store.conversation)
    }
}

private struct ConnectionBanner: View {
    let state: AppStore.ConnectionState
    let attempt: Int

    var body: some View {
        if state == .reconnecting {
            HStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                    .tint(DSHStyle.warning)
                VStack(alignment: .leading, spacing: 2) {
                    Text(
                        attempt > 0
                            ? "Reconnecting automatically · attempt \(attempt + 1)"
                            : "Reconnecting automatically…"
                    )
                        .font(.caption.weight(.semibold))
                    Text("No action needed. The Host session is still running.")
                        .font(.caption2)
                }
                Spacer()
            }
            .foregroundStyle(DSHStyle.warning)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .background(DSHStyle.warning.opacity(0.10))
            .accessibilityElement(children: .combine)
        } else if state == .suspended {
            EmptyView()
        }
    }
}

private struct TimelineView: View {
    let turns: [TurnPresentation]
    let hasOlderHistory: Bool
    let isLoadingOlder: Bool
    let loadOlder: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 16) {
                    if hasOlderHistory {
                        Button(action: loadOlder) {
                            HStack(spacing: 7) {
                                if isLoadingOlder {
                                    ProgressView()
                                        .controlSize(.small)
                                } else {
                                    Image(systemName: "clock.arrow.trianglehead.counterclockwise.rotate.90")
                                }
                                Text(isLoadingOlder ? "Loading earlier messages…" : "Load earlier messages")
                            }
                            .font(.subheadline.weight(.semibold))
                        }
                        .disabled(isLoadingOlder)
                    }
                    ForEach(turns) { turn in
                        TurnView(turn: turn)
                            .id(turn.id)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 16)
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: turns) {
                guard let last = turns.last, last.isStreaming || last.state == .running else { return }
                if reduceMotion {
                    proxy.scrollTo("bottom", anchor: .bottom)
                } else {
                    withAnimation(.easeOut(duration: 0.18)) {
                        proxy.scrollTo("bottom", anchor: .bottom)
                    }
                }
            }
            .task {
                await Task.yield()
                proxy.scrollTo("bottom", anchor: .bottom)
            }
        }
    }
}

private struct TurnView: View {
    let turn: TurnPresentation

    var body: some View {
        VStack(spacing: 10) {
            ForEach(turn.messages.filter { $0.role == .user }) { message in
                MessageBubble(message: message, streaming: false)
            }
            if !turn.reasoning.isEmpty || !turn.tools.isEmpty || turn.state == .running {
                ProcessDisclosure(turn: turn)
            }
            ForEach(turn.messages.filter { $0.role == .assistant }) { message in
                MessageBubble(
                    message: message,
                    streaming: turn.isStreaming && message.id.hasPrefix("live-")
                )
            }
            if case let .failed(message) = turn.state {
                Label(message ?? "This turn failed.", systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

private struct MessageBubble: View {
    let message: ChatMessage
    let streaming: Bool
    @State private var selectingText = false

    var body: some View {
        HStack(alignment: .bottom) {
            if message.role == .user { Spacer(minLength: 46) }
            VStack(alignment: .leading, spacing: 8) {
                if message.role == .assistant {
                    HStack(spacing: 7) {
                        Image("WhaleMascot")
                            .resizable()
                            .scaledToFill()
                            .frame(width: 22, height: 22)
                            .clipShape(Circle())
                        Text("鲸鱼娘")
                            .font(.caption.bold())
                            .foregroundStyle(DSHStyle.accent)
                    }
                }
                MarkdownDocument(
                    id: message.id,
                    source: message.text,
                    role: message.role
                )
                if streaming {
                    TypingIndicator()
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: 680, alignment: .leading)
            .foregroundStyle(message.role == .user ? .white : .primary)
            .background(
                message.role == .user ? DSHStyle.action : DSHStyle.surface,
                in: RoundedRectangle(cornerRadius: 17, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 17, style: .continuous)
                    .stroke(
                        message.role == .user
                            ? DSHStyle.accent.opacity(0.35)
                            : DSHStyle.border
                    )
            }
            .shadow(
                color: message.role == .user
                    ? DSHStyle.accent.opacity(0.12)
                    : Color.black.opacity(0.08),
                radius: 12,
                y: 5
            )
            if message.role == .assistant { Spacer(minLength: 20) }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(message.role == .user ? "You" : "鲸鱼娘")
        .contextMenu {
            Button {
                UIPasteboard.general.string = message.text
                WhaleDiagnostics.interaction.debug("message copied")
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }
            Button {
                selectingText = true
                WhaleDiagnostics.interaction.debug("message text selection opened")
            } label: {
                Label("Select Text", systemImage: "selection.pin.in.out")
            }
        }
        .sheet(isPresented: $selectingText) {
            TextSelectionView(
                title: message.role == .user ? "Your Message" : "鲸鱼娘",
                text: message.text
            )
        }
    }

}

private final class CachedMarkdownDocument: NSObject {
    let source: String
    let content: MarkdownContent

    init(source: String) {
        self.source = source
        content = MarkdownContent(source)
    }
}

@MainActor
private enum MarkdownRenderCache {
    private static let cache: NSCache<NSString, CachedMarkdownDocument> = {
        let cache = NSCache<NSString, CachedMarkdownDocument>()
        cache.countLimit = 160
        cache.totalCostLimit = 6 * 1_024 * 1_024
        return cache
    }()

    static func document(id: String, source: String) -> MarkdownContent {
        let key = id as NSString
        if let cached = cache.object(forKey: key), cached.source == source {
            return cached.content
        }
        let document = CachedMarkdownDocument(source: source)
        cache.setObject(document, forKey: key, cost: source.utf8.count)
        return document.content
    }
}

@MainActor
private struct MarkdownDocument: View {
    let role: ChatMessage.Role
    private let document: MarkdownContent

    init(id: String, source: String, role: ChatMessage.Role) {
        self.role = role
        document = MarkdownRenderCache.document(id: id, source: source)
    }

    private var theme: Theme {
        Theme.gitHub
            .text {
                ForegroundColor(role == .user ? .white : .primary)
                BackgroundColor(nil)
                FontSize(16)
            }
            .codeBlock { configuration in
                configuration.label
                    .fixedSize(horizontal: false, vertical: true)
                    .markdownTextStyle {
                        FontFamilyVariant(.monospaced)
                        FontSize(.em(0.9))
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        role == .user
                            ? Color.white.opacity(0.12)
                            : DSHStyle.canvas.opacity(0.78)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 9))
                    .markdownMargin(top: 0, bottom: 16)
            }
            .table { configuration in
                ScrollView(.horizontal) {
                    configuration.label
                        .fixedSize(horizontal: true, vertical: true)
                }
                .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
                .markdownMargin(top: 0, bottom: 16)
                .accessibilityLabel("Table")
            }
    }

    var body: some View {
        Markdown(document)
            .markdownTheme(theme)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct TextSelectionView: View {
    let title: String
    let text: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            SelectableText(text: text)
                .padding(.horizontal, 8)
                .background(DSHStyle.canvas)
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}

private struct SelectableText: UIViewRepresentable {
    let text: String

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.isEditable = false
        view.isSelectable = true
        view.isScrollEnabled = true
        view.backgroundColor = .clear
        view.font = .preferredFont(forTextStyle: .body)
        view.adjustsFontForContentSizeCategory = true
        view.textContainerInset = UIEdgeInsets(top: 16, left: 12, bottom: 24, right: 12)
        view.textContainer.lineFragmentPadding = 0
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        guard view.text != text else { return }
        view.text = text
    }
}

private struct ProcessDisclosure: View {
    let turn: TurnPresentation
    @State private var expanded: Bool

    init(turn: TurnPresentation) {
        self.turn = turn
        _expanded = State(initialValue: turn.state == .running)
    }

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 10) {
                if !turn.reasoning.isEmpty {
                    DetailBlock(
                        title: "Thinking",
                        icon: "brain.head.profile",
                        text: turn.reasoning,
                        state: turn.isStreaming ? .running : .succeeded
                    )
                }
                ForEach(turn.tools) { tool in
                    ToolRow(tool: tool)
                }
            }
            .padding(.top, 10)
        } label: {
            HStack(spacing: 9) {
                ActivityGlyph(active: turn.state == .running)
                Text(summary)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(stateLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .padding(12)
        .background(
            LinearGradient(
                colors: [DSHStyle.surface, DSHStyle.raised.opacity(0.72)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 15)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 15)
                .stroke(DSHStyle.accent.opacity(turn.state == .running ? 0.35 : 0.12))
        }
        .onChange(of: turn.state) {
            if turn.state == .running { expanded = true }
        }
    }

    private var summary: String {
        if turn.tools.isEmpty {
            return turn.reasoning.isEmpty ? "Working" : "Thinking"
        }
        return "\(turn.tools.count) tool \(turn.tools.count == 1 ? "call" : "calls")"
    }

    private var stateLabel: String {
        switch turn.state {
        case .running: return "Running"
        case .completed: return "Done"
        case .cancelled: return "Stopped"
        case .failed: return "Failed"
        case .interrupted: return "Interrupted"
        }
    }
}

private struct ToolRow: View {
    let tool: ToolActivity
    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 8) {
                if !tool.arguments.isEmpty {
                    Text(tool.arguments)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                }
                if let result = tool.result, !result.isEmpty {
                    Divider()
                    Text(result)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 8)
        } label: {
            HStack {
                Image(systemName: toolIcon)
                    .foregroundStyle(toolColor)
                Text(tool.name)
                    .font(.system(.subheadline, design: .monospaced, weight: .medium))
                    .lineLimit(1)
                Spacer()
                Text(toolState)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(toolColor)
            }
        }
        .padding(10)
        .background(DSHStyle.canvas.opacity(0.78), in: RoundedRectangle(cornerRadius: 11))
        .overlay {
            RoundedRectangle(cornerRadius: 11)
                .stroke(DSHStyle.border)
        }
    }

    private var toolIcon: String {
        switch tool.state {
        case .running: return "gearshape.2.fill"
        case .succeeded: return "checkmark.circle.fill"
        case .failed: return "xmark.octagon.fill"
        }
    }

    private var toolColor: Color {
        switch tool.state {
        case .running: return DSHStyle.accent
        case .succeeded: return DSHStyle.success
        case .failed: return .red
        }
    }

    private var toolState: String {
        switch tool.state {
        case .running: return "Running"
        case .succeeded: return "Done"
        case .failed: return "Failed"
        }
    }
}

private struct DetailBlock: View {
    let title: String
    let icon: String
    let text: String
    let state: ToolActivity.State

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Label(title, systemImage: icon)
                .font(.caption.bold())
                .foregroundStyle(state == .running ? DSHStyle.accent : .secondary)
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ActivityGlyph: View {
    let active: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    var body: some View {
        ZStack {
            if active && !reduceMotion {
                Circle()
                    .fill(DSHStyle.accent.opacity(0.18))
                    .frame(width: 24, height: 24)
                    .scaleEffect(pulse ? 1.25 : 0.75)
            }
            Circle()
                .fill(active ? DSHStyle.accent : DSHStyle.success)
                .frame(width: 8, height: 8)
        }
        .frame(width: 24, height: 24)
        .task(id: active) {
            guard active, !reduceMotion else {
                pulse = false
                return
            }
            withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                pulse = true
            }
        }
    }
}

private struct TypingIndicator: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase = false

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3) { index in
                Circle()
                    .fill(DSHStyle.accent)
                    .frame(width: 5, height: 5)
                    .opacity(phase ? 1 : 0.35)
                    .animation(
                        reduceMotion
                            ? nil
                            : .easeInOut(duration: 0.55)
                                .repeatForever()
                                .delay(Double(index) * 0.12),
                        value: phase
                    )
            }
        }
        .accessibilityLabel("Receiving response")
        .onAppear { phase = true }
    }
}

private struct ComposerView: View {
    let store: AppStore
    @FocusState private var focused: Bool

    private var isRunning: Bool {
        store.conversation.turns.last?.state == .running
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 9) {
            TextField("Message dsh", text: Bindable(store).composerText, axis: .vertical)
                .lineLimit(1...6)
                .focused($focused)
                .textFieldStyle(.plain)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(DSHStyle.surface, in: RoundedRectangle(cornerRadius: 18))
                .overlay {
                    RoundedRectangle(cornerRadius: 18)
                        .stroke(DSHStyle.border)
                }
            Button {
                if isRunning {
                    store.cancel()
                } else {
                    store.send()
                }
            } label: {
                Image(systemName: isRunning ? "stop.fill" : "arrow.up")
                    .font(.body.bold())
                    .foregroundStyle(.white)
                    .frame(width: 48, height: 48)
                    .background(
                        isRunning ? Color.red : DSHStyle.action,
                        in: Circle()
                    )
            }
            .buttonStyle(.plain)
            .disabled(
                isRunning
                    ? store.isCancelling
                    : store.composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || store.isSending
            )
            .accessibilityLabel(isRunning ? "Stop Agent" : "Send message")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(DSHStyle.surface.opacity(0.94))
        .overlay(alignment: .top) {
            Rectangle()
                .fill(DSHStyle.border)
                .frame(height: 1)
        }
    }
}
