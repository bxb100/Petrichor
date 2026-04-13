import SwiftUI

struct SourcesTabView: View {
    @EnvironmentObject var libraryManager: LibraryManager

    @State private var selectedSourceID: UUID?
    @State private var draft = LibraryDataSource()
    @State private var password = ""
    @State private var isSaving = false
    @State private var isDeleting = false
    @State private var showDeleteConfirmation = false

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
        .alert("Delete Emby Source?", isPresented: $showDeleteConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Delete", role: .destructive) {
                Task {
                    await deleteSelectedSource()
                }
            }
        } message: {
            Text("This removes the source configuration, favorites cache, and all synced Emby tracks from Petrichor.")
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
                    showDeleteConfirmation = selectedExistingSource != nil
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

                    HStack {
                        Picker("Connection", selection: $draft.connectionType) {
                            ForEach(NetworkConnectionType.allCases) { type in
                                Text(type.displayName).tag(type)
                            }
                        }
                        .pickerStyle(.segmented)

                        TextField(
                            "Port",
                            value: $draft.port,
                            format: .number
                        )
                        .frame(width: 90)
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
                        Text("Rolling cache size")
                        Spacer()
                        Stepper(value: $draft.rollingCacheSize, in: 0...10) {
                            Text("\(draft.rollingCacheSize) track\(draft.rollingCacheSize == 1 ? "" : "s")")
                                .font(.system(.body, design: .monospaced))
                        }
                        .frame(width: 220, alignment: .trailing)
                    }
                }

                Section("Actions") {
                    HStack(spacing: 12) {
                        Button(action: saveSource) {
                            if isSaving {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Text(selectedExistingSource == nil ? "Add Source" : "Save Changes")
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(isSaving)

                        Button("Sync Library Now") {
                            Task {
                                await syncSelectedSource(forceFavoriteRefresh: false)
                            }
                        }
                        .buttonStyle(.bordered)
                        .disabled(selectedExistingSource == nil || isSaving)

                        Button("Refresh Favorites Cache") {
                            Task {
                                guard let source = selectedExistingSource else { return }
                                await libraryManager.refreshFavoriteCache(for: source)
                            }
                        }
                        .buttonStyle(.bordered)
                        .disabled(selectedExistingSource == nil || !draft.syncFavorites || isSaving)
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

    private func syncSelectedSource(forceFavoriteRefresh: Bool) async {
        guard let source = selectedExistingSource else { return }
        await libraryManager.syncEmbySource(source, forceFavoriteRefresh: forceFavoriteRefresh, showNotifications: true)
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
