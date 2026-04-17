import SwiftUI

struct OnlineTabView: View {
    @EnvironmentObject private var sourceManager: SourceManager

    @AppStorage("lastfmUsername")
    private var lastfmUsername: String = ""

    @AppStorage("scrobblingEnabled")
    private var scrobblingEnabled: Bool = true

    @AppStorage("loveSyncEnabled")
    private var loveSyncEnabled: Bool = true

    @AppStorage("onlineLyricsEnabled")
    private var onlineLyricsEnabled: Bool = false

    @AppStorage("artistInfoFetchEnabled")
    private var artistInfoFetchEnabled: Bool = false

    @State private var isAuthenticating = false
    @State private var showLoveSyncInfo = false
    @State private var showLastFMDisconnectConfirmation = false
    @State private var pendingSourceDisconnect: SourceAccountRecord?

    @State private var selectedSourceKind: SourceKind = .emby
    @State private var sourceBaseURL = ""
    @State private var sourceUsername = ""
    @State private var sourceSecret = ""
    @State private var sourceDisplayName = ""

    private var isConnected: Bool {
        !lastfmUsername.isEmpty
    }

    private var canConnectSource: Bool {
        !sourceBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !sourceUsername.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !sourceSecret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !sourceManager.isWorking
    }

    private var cachedLastFMAvatar: NSImage? {
        guard let data = UserDefaults.standard.data(forKey: "lastfmAvatarData"),
              let image = NSImage(data: data) else {
            return nil
        }
        return image
    }

    var body: some View {
        Form {
            Section {
                lastfmSection
            } header: {
                Text("Last.fm")
            }

            Section {
                sourcesSection
            } header: {
                Text("Sources")
            } footer: {
                Text("Connect Emby or Navidrome servers. Credentials are stored in Keychain.")
            }

            Section {
                onlineFeaturesSection
            } header: {
                Text("Lyrics & Metadata")
            }
        }
        .formStyle(.grouped)
        .padding(5)
        .onAppear {
            sourceManager.loadAccounts()
        }
        .alert("Disconnect from Last.fm?", isPresented: $showLastFMDisconnectConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Disconnect", role: .destructive) {
                disconnectLastFM()
            }
        } message: {
            Text("Your listening activity will no longer be scrobbled to Last.fm once you disconnect.")
        }
        .alert(
            pendingSourceDisconnect.map { "Disconnect \($0.displayName)?" } ?? "Disconnect Source?",
            isPresented: .init(
                get: { pendingSourceDisconnect != nil },
                set: { isPresented in
                    if !isPresented {
                        pendingSourceDisconnect = nil
                    }
                }
            )
        ) {
            Button("Cancel", role: .cancel) { }
            Button("Disconnect", role: .destructive) {
                guard let account = pendingSourceDisconnect else { return }
                pendingSourceDisconnect = nil
                Task {
                    await sourceManager.disconnect(account: account)
                }
            }
        } message: {
            if let account = pendingSourceDisconnect {
                Text("The \(account.kind.displayName) account will be removed from Petrichor.")
            }
        }
    }

    // MARK: - Last.fm Section

    @ViewBuilder
    private var lastfmSection: some View {
        if isConnected {
            connectedLastFMView
        } else {
            disconnectedLastFMView
        }
    }

    private var connectedLastFMView: some View {
        Group {
            HStack {
                Group {
                    if let avatar = cachedLastFMAvatar {
                        Image(nsImage: avatar)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: 32, height: 32)
                            .clipShape(Circle())
                    } else {
                        Image(systemName: Icons.personFill)
                            .font(.system(size: 32))
                            .foregroundColor(.secondary)
                    }
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(lastfmUsername)
                        .font(.system(size: 13, weight: .medium))
                    Text("Connected")
                        .font(.system(size: 11))
                        .foregroundColor(.green)
                }

                Spacer()

                Button {
                    showLastFMDisconnectConfirmation = true
                } label: {
                    Text("Disconnect")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.plain)
                .background(Color.red)
                .cornerRadius(5)
            }
            .padding(.vertical, 4)

            Toggle("Enable scrobbling", isOn: $scrobblingEnabled)
                .help("Track your listening history on Last.fm")

            Toggle(isOn: $loveSyncEnabled) {
                HStack(spacing: 4) {
                    Text("Sync favorites as Loved tracks")

                    Button {
                        showLoveSyncInfo.toggle()
                    } label: {
                        Image(systemName: "questionmark.circle")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .popover(isPresented: $showLoveSyncInfo, arrowEdge: .trailing) {
                        Text("Tracks you favorite in Petrichor will be loved on Last.fm. Loved tracks on Last.fm won't sync back to Petrichor.")
                            .font(.system(size: 12))
                            .padding(10)
                            .frame(width: 220)
                    }
                }
            }
        }
    }

    private var disconnectedLastFMView: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("Not connected")
                    .font(.system(size: 13, weight: .medium))
                Text("Connect your Last.fm account to start scrobbling")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }

            Spacer()

            Button(action: startAuthentication) {
                if isAuthenticating {
                    ProgressView()
                        .scaleEffect(0.7)
                        .frame(width: 60)
                } else {
                    Text("Connect")
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(isAuthenticating)
        }
        .padding(.vertical, 4)
    }

    // MARK: - Sources Section

    @ViewBuilder
    private var sourcesSection: some View {
        if sourceManager.sourceAccounts.isEmpty {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("No remote sources connected")
                        .font(.system(size: 13, weight: .medium))
                    Text("Add an Emby or Navidrome server to start syncing a remote library.")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }

                Spacer()
            }
            .padding(.vertical, 4)
        } else {
            ForEach(sourceManager.sourceAccounts) { account in
                sourceAccountRow(account)
            }
        }

        sourceConnectionForm

        if let lastErrorMessage = sourceManager.lastErrorMessage {
            Text(lastErrorMessage)
                .font(.system(size: 11))
                .foregroundColor(.red)
        }
    }

    private func sourceAccountRow(_ account: SourceAccountRecord) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(account.displayName)
                            .font(.system(size: 13, weight: .medium))

                        Text(account.kind.displayName)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(.accentColor)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Color.accentColor.opacity(0.12))
                            .clipShape(Capsule())
                    }

                    Text(account.baseURL)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Text(account.username)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }

                Spacer()

                if sourceManager.isWorking(for: account.id) {
                    ProgressView()
                        .controlSize(.small)
                }

                Button("Sync") {
                    Task {
                        await sourceManager.sync(account: account)
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(sourceManager.isWorking)

                Button("Verify") {
                    Task {
                        await sourceManager.validate(account: account)
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(sourceManager.isWorking)

                Button("Disconnect") {
                    pendingSourceDisconnect = account
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .tint(.red)
                .disabled(sourceManager.isWorking)
            }

            if let lastSyncAt = account.lastSyncAt {
                Text("Last sync \(lastSyncAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private var sourceConnectionForm: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add Source")
                .font(.system(size: 13, weight: .semibold))

            Picker("Provider", selection: $selectedSourceKind) {
                ForEach(SourceKind.remoteCases, id: \.self) { kind in
                    Text(kind.displayName).tag(kind)
                }
            }
            .pickerStyle(.segmented)
            .disabled(sourceManager.isWorking)

            TextField("Server URL", text: $sourceBaseURL)
                .textFieldStyle(.roundedBorder)
                .disabled(sourceManager.isWorking)

            TextField("Username", text: $sourceUsername)
                .textFieldStyle(.roundedBorder)
                .disabled(sourceManager.isWorking)

            SecureField("Password", text: $sourceSecret)
                .textFieldStyle(.roundedBorder)
                .disabled(sourceManager.isWorking)

            TextField("Display name (optional)", text: $sourceDisplayName)
                .textFieldStyle(.roundedBorder)
                .disabled(sourceManager.isWorking)

            HStack {
                Spacer()

                Button(action: connectSource) {
                    if sourceManager.isConnecting {
                        ProgressView()
                            .controlSize(.small)
                            .frame(width: 80)
                    } else {
                        Text("Connect Source")
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(!canConnectSource)
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - Online Features Section

    private var onlineFeaturesSection: some View {
        Group {
            Toggle("Fetch lyrics from internet when unavailable", isOn: $onlineLyricsEnabled)
                .help("Automatically search for lyrics online when no local lyrics are found")

            Toggle("Fetch artist image and bio from internet", isOn: $artistInfoFetchEnabled)
                .help("Automatically download artist photos and bios from online sources")
        }
    }

    // MARK: - Actions

    private func startAuthentication() {
        guard let scrobbleManager = AppCoordinator.shared?.scrobbleManager,
              let authURL = scrobbleManager.authenticationURL() else {
            return
        }

        isAuthenticating = true
        NSWorkspace.shared.open(authURL)
        Logger.info("Opened Last.fm authorization page")

        // Reset authenticating state after a delay.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            isAuthenticating = false
        }
    }

    private func connectSource() {
        Task {
            let didConnect = await sourceManager.connect(
                kind: selectedSourceKind,
                baseURLString: sourceBaseURL,
                username: sourceUsername,
                secret: sourceSecret,
                displayName: sourceDisplayName
            )

            guard didConnect else { return }

            sourceBaseURL = ""
            sourceUsername = ""
            sourceSecret = ""
            sourceDisplayName = ""
        }
    }

    private func disconnectLastFM() {
        lastfmUsername = ""
        scrobblingEnabled = true
        loveSyncEnabled = true

        UserDefaults.standard.removeObject(forKey: "lastfmAvatarData")
        KeychainManager.delete(key: KeychainManager.Keys.lastfmSessionKey)

        Logger.info("Disconnected from Last.fm")
        NotificationManager.shared.addMessage(.info, "Disconnected from Last.fm")
    }
}

#Preview {
    let libraryManager = LibraryManager()

    return OnlineTabView()
        .environmentObject(SourceManager(databaseManager: libraryManager.databaseManager))
        .frame(width: 600, height: 500)
}
