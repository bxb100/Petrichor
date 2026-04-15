import SwiftUI

private enum SourceActionAlert: String, Identifiable {
    case delete
    case rebuild

    var id: String { rawValue }
}

struct SourcesTabView: View {
    @EnvironmentObject var libraryManager: LibraryManager

    @State private var selectedSourceID: UUID?
    @State private var draft = LibraryDataSource()
    @State private var password = ""
    @State private var isSaving = false
    @State private var isDeleting = false
    @State private var isRebuilding = false
    @State private var activeAlert: SourceActionAlert?

    private static let portFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .none
        formatter.usesGroupingSeparator = false
        formatter.minimum = 0
        formatter.maximum = 65_535
        return formatter
    }()

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 220)

            Divider()

            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear {
            if let firstSource = libraryManager.dataSources.first {
                loadDraft(from: firstSource)
            } else {
                prepareNewSource()
            }
        }
        .onChange(of: libraryManager.dataSources.map(\.id)) { _, _ in
            if let selectedSourceID,
               let source = libraryManager.dataSources.first(where: { $0.id == selectedSourceID }) {
                loadDraft(from: source)
            } else if libraryManager.dataSources.isEmpty {
                prepareNewSource()
            }
        }
        .alert(item: $activeAlert) { alert in
            switch alert {
            case .delete:
                Alert(
                    title: Text("Delete Emby Source?"),
                    message: Text("This removes the source configuration, favorites cache, and all synced Emby tracks from Petrichor."),
                    primaryButton: .destructive(Text("Delete")) {
                        Task {
                            await deleteSelectedSource()
                        }
                    },
                    secondaryButton: .cancel()
                )
            case .rebuild:
                Alert(
                    title: Text("Rebuild Emby Index?"),
                    message: Text("This forces a full resync for the selected Emby source and rebuilds Petrichor's local index for its tracks."),
                    primaryButton: .default(Text("Rebuild")) {
                        Task {
                            await rebuildSelectedSourceIndex()
                        }
                    },
                    secondaryButton: .cancel()
                )
            }
        }
    }

    private var sidebar: some View {
        VStack(spacing: 12) {
            List(selection: $selectedSourceID) {
                ForEach(libraryManager.dataSources) { source in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(source.name.isEmpty ? "Untitled Source" : source.name)
                            .font(.system(size: 13, weight: .medium))
                        Text("\(source.connectionType.displayName) • \(source.host):\(source.port)")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                    .tag(source.id)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        loadDraft(from: source)
                    }
                }
            }
            .listStyle(.sidebar)

            HStack(spacing: 8) {
                Button(action: prepareNewSource) {
                    Label("New Source", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)

                Button(role: .destructive) {
                    activeAlert = selectedExistingSource == nil ? nil : .delete
                } label: {
                    Label("Delete", systemImage: "trash")
                }
                .buttonStyle(.bordered)
                .disabled(selectedExistingSource == nil || isDeleting)
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 12)
        }
    }

    private var detail: some View {
        ScrollView {
            Form {
                Section("Type") {
                    LabeledContent("Source Type") {
                        Text("Emby")
                            .foregroundColor(.secondary)
                    }
                }

                Section("Connection") {
                    TextField("Source Name", text: $draft.name)
                    TextField("IP or Domain", text: $draft.host)

                    HStack(alignment: .center, spacing: 12) {
                        Picker("Connection", selection: $draft.connectionType) {
                            ForEach(NetworkConnectionType.allCases) { type in
                                Text(type.displayName).tag(type)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(maxWidth: .infinity, alignment: .leading)

                        TextField(
                            "Port",
                            value: $draft.port,
                            formatter: Self.portFormatter
                        )
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 96)
                    }

                    TextField("Username", text: $draft.username)
                    SecureField("Password", text: $password)
                }

                Section("Playback & Sync") {
                    Toggle("Sync Emby favorites", isOn: $draft.syncFavorites)

                    if draft.syncFavorites {
                        HStack {
                            Text("Favorites cache TTL")
                            Spacer()
                            Stepper(value: favoritesTTLMinutes, in: 5...10080, step: 5) {
                                Text(ttlDescription)
                                    .font(.system(.body, design: .monospaced))
                            }
                            .frame(width: 220, alignment: .trailing)
                        }
                    }

                    HStack {
                        Text("Rolling cache radius")
                        Spacer()
                        Stepper(value: $draft.rollingCacheSize, in: 0...10) {
                            Text("±\(draft.rollingCacheSize) track\(draft.rollingCacheSize == 1 ? "" : "s")")
                                .font(.system(.body, design: .monospaced))
                        }
                        .frame(width: 220, alignment: .trailing)
                    }
                }

                Section("Actions") {
                    VStack(alignment: .leading, spacing: 12) {
                        LazyVGrid(
                            columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3),
                            alignment: .leading,
                            spacing: 12
                        ) {
                            Button(action: saveSource) {
                                HStack(spacing: 8) {
                                    if isSaving {
                                        ProgressView()
                                            .controlSize(.small)
                                    }
                                    Text(selectedExistingSource == nil ? "Add Source" : "Save Changes")
                                        .lineLimit(1)
                                }
                                .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(isSaving || isDeleting || isRebuilding)

                            Button("Rebuild Index") {
                                activeAlert = selectedExistingSource == nil ? nil : .rebuild
                            }
                            .frame(maxWidth: .infinity)
                            .buttonStyle(.bordered)
                            .disabled(selectedExistingSource == nil || isSaving || isDeleting || isRebuilding)

                            Button("Refresh Favorites Cache") {
                                Task {
                                    guard let source = selectedExistingSource else { return }
                                    await libraryManager.refreshFavoriteCache(for: source)
                                }
                            }
                            .frame(maxWidth: .infinity)
                            .buttonStyle(.bordered)
                            .disabled(selectedExistingSource == nil || !draft.syncFavorites || isSaving || isDeleting || isRebuilding)
                        }

                        if isRebuilding {
                            HStack(spacing: 8) {
                                ProgressView()
                                    .controlSize(.small)
                                Text("Rebuilding index...")
                                    .font(.system(size: 12))
                                    .foregroundColor(.secondary)
                            }
                        }

                        Text("Emby sources sync automatically after save and refresh every 24 hours.")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                    }

                    if let source = selectedExistingSource {
                        VStack(alignment: .leading, spacing: 6) {
                            if let lastSyncedAt = source.lastSyncedAt {
                                Text("Last sync: \(lastSyncedAt.formatted(date: .abbreviated, time: .shortened))")
                                    .font(.system(size: 12))
                                    .foregroundColor(.secondary)
                            }

                            if let favoritesUpdatedAt = source.favoritesCacheUpdatedAt, source.syncFavorites {
                                Text("Favorites cache: \(favoritesUpdatedAt.formatted(date: .abbreviated, time: .shortened))")
                                    .font(.system(size: 12))
                                    .foregroundColor(.secondary)
                            }

                            if let lastSyncError = source.lastSyncError, !lastSyncError.isEmpty {
                                Text(lastSyncError)
                                    .font(.system(size: 12))
                                    .foregroundColor(.red)
                            }
                        }
                        .padding(.top, 4)
                    }
                }
            }
            .formStyle(.grouped)
            .padding(16)
        }
    }

    private var selectedExistingSource: LibraryDataSource? {
        guard let selectedSourceID else { return nil }
        return libraryManager.dataSources.first(where: { $0.id == selectedSourceID })
    }

    private var favoritesTTLMinutes: Binding<Int> {
        Binding(
            get: { max(5, draft.favoritesCacheTTLSeconds / 60) },
            set: { draft.favoritesCacheTTLSeconds = max(5, $0) * 60 }
        )
    }

    private var ttlDescription: String {
        let minutes = max(5, draft.favoritesCacheTTLSeconds / 60)
        if minutes >= 60 && minutes % 60 == 0 {
            let hours = minutes / 60
            return "\(hours)h"
        }
        return "\(minutes)m"
    }

    private func prepareNewSource() {
        let connectionType: NetworkConnectionType = .http
        draft = LibraryDataSource(
            kind: .emby,
            name: "",
            host: "",
            port: connectionType.defaultPort,
            connectionType: connectionType,
            username: "",
            syncFavorites: false,
            favoritesCacheTTLSeconds: 3600,
            rollingCacheSize: 2
        )
        password = ""
        selectedSourceID = nil
    }

    private func loadDraft(from source: LibraryDataSource) {
        selectedSourceID = source.id
        draft = source
        password = libraryManager.passwordForDataSource(source)
    }

    private func saveSource() {
        isSaving = true
        Task {
            let didSave = await libraryManager.saveEmbySource(draft, password: password)
            await MainActor.run {
                isSaving = false
                if didSave {
                    selectedSourceID = draft.id
                }
            }
        }
    }

    private func rebuildSelectedSourceIndex() async {
        guard let source = selectedExistingSource else { return }

        await MainActor.run {
            isRebuilding = true
        }

        await libraryManager.rebuildEmbySourceIndex(for: source)

        await MainActor.run {
            isRebuilding = false
        }
    }

    private func deleteSelectedSource() async {
        guard let source = selectedExistingSource else { return }
        isDeleting = true
        await libraryManager.deleteDataSource(source)
        await MainActor.run {
            isDeleting = false
            prepareNewSource()
        }
    }
}

#Preview {
    SourcesTabView()
        .environmentObject(LibraryManager())
        .frame(width: 760, height: 520)
}
