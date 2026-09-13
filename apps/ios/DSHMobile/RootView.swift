import SwiftUI

struct RootView: View {
    let store: AppStore
    @Binding var hostURL: String

    var body: some View {
        Group {
            switch store.connectionState {
            case .unconfigured, .connecting, .failed:
                ConnectionView(store: store, hostURL: $hostURL)
            case .connected, .reconnecting, .suspended:
                SessionNavigationView(store: store, hostURL: $hostURL)
            }
        }
        .background(DSHStyle.canvas)
        .alert(
            "鲸鱼娘 needs attention",
            isPresented: Binding(
                get: { store.conversationError != nil },
                set: { if !$0 { store.dismissError() } }
            )
        ) {
            if store.conversationErrorAllowsRetry {
                Button("Retry") { store.retrySelectedSession() }
            }
            Button("Dismiss", role: .cancel) { store.dismissError() }
        } message: {
            Text(store.conversationError ?? "")
        }
        .task {
            #if DEBUG
            let startupURL = ProcessInfo.processInfo.environment["WHALE_GIRL_HOST_URL"]
                .flatMap { $0.isEmpty ? nil : $0 } ?? hostURL
            #else
            let startupURL = hostURL
            #endif
            guard !startupURL.isEmpty, store.connectionState == .unconfigured else { return }
            await store.connect(address: startupURL)
        }
    }
}

private struct ConnectionView: View {
    let store: AppStore
    @Binding var hostURL: String
    @State private var address = ""

    private var failure: String? {
        guard case let .failed(message) = store.connectionState else { return nil }
        return message
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 28) {
                    Spacer(minLength: 36)
                    ZStack {
                        Circle()
                            .fill(DSHStyle.accent.opacity(0.18))
                            .frame(width: 118, height: 118)
                            .blur(radius: 16)
                        Image("WhaleMascot")
                            .resizable()
                            .scaledToFill()
                            .frame(width: 96, height: 96)
                            .clipShape(RoundedRectangle(cornerRadius: 25, style: .continuous))
                            .overlay {
                                RoundedRectangle(cornerRadius: 25, style: .continuous)
                                    .stroke(.white.opacity(0.35), lineWidth: 1)
                            }
                            .shadow(color: DSHStyle.accent.opacity(0.32), radius: 22, y: 8)
                    }
                    VStack(spacing: 8) {
                        Text("连接鲸鱼娘")
                            .font(.largeTitle.bold())
                        Text("The model, tools, and source stay on your development machine. This app only presents and controls its sessions.")
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    VStack(alignment: .leading, spacing: 12) {
                        TextField("Paste the URL printed by dsh web", text: $address)
                            .textContentType(.URL)
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .padding(14)
                            .background(DSHStyle.raised, in: RoundedRectangle(cornerRadius: 14))
                            .overlay {
                                RoundedRectangle(cornerRadius: 14)
                                    .stroke(DSHStyle.border)
                            }
                        if let failure {
                            Label(failure, systemImage: "exclamationmark.triangle.fill")
                                .font(.footnote)
                                .foregroundStyle(.red)
                        }
                        Button {
                            hostURL = cleanAddress(address)
                            Task { await store.connect(address: address) }
                        } label: {
                            HStack {
                                if store.connectionState == .connecting {
                                    ProgressView().tint(.white)
                                }
                                Text(store.connectionState == .connecting ? "Connecting" : "Connect")
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(DSHStyle.action)
                        .controlSize(.large)
                        .disabled(
                            address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                || store.connectionState == .connecting
                        )
                    }
                    .padding(18)
                    .background(DSHStyle.surface, in: RoundedRectangle(cornerRadius: 20))
                    .overlay {
                        RoundedRectangle(cornerRadius: 20)
                            .stroke(DSHStyle.border)
                    }
                    .shadow(color: DSHStyle.accent.opacity(0.10), radius: 24, y: 12)
                }
                .padding(24)
            }
            .background {
                ZStack {
                    DSHStyle.canvas
                    DSHStyle.oceanGradient.opacity(0.12)
                        .ignoresSafeArea()
                }
            }
        }
        .onAppear {
            if address.isEmpty { address = hostURL }
        }
    }

    private func cleanAddress(_ value: String) -> String {
        guard var components = URLComponents(string: value) else { return value }
        components.query = nil
        components.fragment = nil
        components.path = ""
        return components.string ?? value
    }
}

private struct SessionNavigationView: View {
    let store: AppStore
    @Binding var hostURL: String
    @State private var search = ""
    @State private var showingNewSession = false
    @State private var showingConnection = false
    @State private var expandedCWDs: Set<String> = []

    var body: some View {
        NavigationSplitView {
            List(selection: Binding(
                get: { store.selectedSessionId },
                set: { store.selectSession($0) }
            )) {
                ForEach(filteredGroups, id: \.cwd) { group in
                    Section {
                        ForEach(visibleSessions(in: group)) { session in
                            NavigationLink(value: session.sessionId) {
                                SessionRow(session: session)
                            }
                        }
                        if search.isEmpty, group.sessions.count > 5 {
                            Button {
                                withAnimation(.snappy(duration: 0.2)) {
                                    toggleExpanded(group.cwd)
                                }
                            } label: {
                                Label(
                                    expandedCWDs.contains(group.cwd)
                                        ? "Show less"
                                        : "Show \(group.sessions.count - 5) more",
                                    systemImage: expandedCWDs.contains(group.cwd)
                                        ? "chevron.up.circle"
                                        : "chevron.down.circle"
                                )
                                .font(.subheadline.weight(.semibold))
                                .frame(maxWidth: .infinity, alignment: .center)
                                .padding(.vertical, 5)
                            }
                            .accessibilityHint(
                                expandedCWDs.contains(group.cwd)
                                    ? "Collapse this working directory"
                                    : "Reveal older sessions in this working directory"
                            )
                        }
                    } header: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(group.sessions.first?.workspaceTitle ?? "Workspace")
                            if !group.cwd.isEmpty {
                                Text(group.cwd)
                                    .font(.caption2)
                                    .textCase(nil)
                                    .lineLimit(1)
                            }
                        }
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(DSHStyle.canvas)
            .searchable(text: $search, prompt: "Search sessions or paths")
            .navigationTitle("鲸鱼娘")
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    Button {
                        Task { try? await store.refreshSessions() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .accessibilityLabel("Refresh sessions")
                    Button {
                        showingNewSession = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("New session")
                }
                ToolbarItem(placement: .bottomBar) {
                    Button {
                        showingConnection = true
                    } label: {
                        Label(connectionLabel, systemImage: connectionIcon)
                    }
                }
            }
        } detail: {
            if store.selectedSessionId == nil {
                ContentUnavailableView(
                    "Select a session",
                    systemImage: "bubble.left.and.bubble.right",
                    description: Text("Sessions from every working directory are available in the sidebar.")
                )
            } else {
                ConversationView(store: store)
            }
        }
        .sheet(isPresented: $showingNewSession) {
            NewSessionView(store: store, isPresented: $showingNewSession)
        }
        .sheet(isPresented: $showingConnection) {
            NavigationStack {
                ConnectionView(store: store, hostURL: $hostURL)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Done") { showingConnection = false }
                        }
                    }
            }
        }
    }

    private var filteredGroups: [(cwd: String, sessions: [SessionSummary])] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return store.groupedSessions }
        return store.groupedSessions.compactMap { group in
            let sessions = group.sessions.filter {
                $0.displayTitle.localizedCaseInsensitiveContains(query)
                    || ($0.cwd?.localizedCaseInsensitiveContains(query) == true)
            }
            return sessions.isEmpty ? nil : (group.cwd, sessions)
        }
    }

    private var connectionLabel: String {
        store.connectionState == .reconnecting ? "Reconnecting" : "Connected"
    }

    private var connectionIcon: String {
        store.connectionState == .reconnecting
            ? "wifi.exclamationmark"
            : "checkmark.circle.fill"
    }

    private func visibleSessions(
        in group: (cwd: String, sessions: [SessionSummary])
    ) -> [SessionSummary] {
        search.isEmpty && !expandedCWDs.contains(group.cwd)
            ? Array(group.sessions.prefix(5))
            : group.sessions
    }

    private func toggleExpanded(_ cwd: String) {
        if expandedCWDs.contains(cwd) {
            expandedCWDs.remove(cwd)
        } else {
            expandedCWDs.insert(cwd)
        }
    }
}

private struct SessionRow: View {
    let session: SessionSummary

    var body: some View {
        HStack(spacing: 11) {
            Circle()
                .fill(session.running ? DSHStyle.accent : Color.secondary.opacity(0.24))
                .frame(width: 8, height: 8)
                .overlay {
                    if session.running {
                        Circle()
                            .stroke(DSHStyle.accent.opacity(0.3), lineWidth: 5)
                    }
                }
            VStack(alignment: .leading, spacing: 4) {
                Text(session.displayTitle)
                    .font(.body.weight(.semibold))
                    .lineLimit(2)
                Text(session.blank ? "Empty session" : relativeDate(session.updatedAt))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .background(DSHStyle.surface, in: RoundedRectangle(cornerRadius: 16))
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .stroke(session.running ? DSHStyle.accent.opacity(0.38) : DSHStyle.border)
        }
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))
    }

    private func relativeDate(_ milliseconds: Int64) -> String {
        let date = Date(timeIntervalSince1970: Double(milliseconds) / 1_000)
        return date.formatted(.relative(presentation: .named))
    }
}

private struct NewSessionView: View {
    let store: AppStore
    @Binding var isPresented: Bool
    @State private var cwd = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Working directory on the Host") {
                    TextField("/absolute/path/to/project", text: $cwd)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                Section {
                    Text("The path is resolved and validated by the dsh Host. No project files move to this iPhone.")
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("New Session")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { isPresented = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        Task {
                            await store.createSession(cwd: cwd)
                            if store.selectedSessionId != nil { isPresented = false }
                        }
                    }
                    .disabled(cwd.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}
