import SwiftUI

struct LibraryView: View {
    @EnvironmentObject var libraryManager: LibraryManager
    @EnvironmentObject var playlistManager: PlaylistManager

    @Binding var selectedFilterType: LibraryFilterType
    @Binding var selectedFilterItem: LibraryFilterItem?
    @Binding var pendingSearchText: String?

    @AppStorage("trackTableRowSize")
    private var trackTableRowSize: TableRowSize = .expanded

    @State private var selectedTrackID: UUID?
    @State private var cachedFilteredTracks: [Track] = []
    @State private var isLibrarySearchActive = false
    @State private var isFilterLoading = false
    @State private var isViewReady = false
    @State private var trackTableSortOrder = [KeyPathComparator(\Track.title)]
    @State private var filterUpdateTask: Task<Void, Never>?
    @State private var filteredTrackOffset = 0
    @State private var hasMoreFilteredTracks = true
    @State private var filterRequestID = UUID()
    @State private var queueHydrationTask: Task<Void, Never>?
    @Binding var pendingFilter: LibraryFilterRequest?

    var body: some View {
        if !libraryManager.shouldShowMainUI {
            NoMusicEmptyStateView(context: .mainWindow)
        } else {
            tracksListView
                .onAppear {
                    processPendingFilter()
                    updateFilteredTracks()
                }
                .onDisappear {
                    filterUpdateTask?.cancel()
                    isFilterLoading = false
                    isViewReady = false
                }
                .onChange(of: libraryManager.tracks) { _, newTracks in
                    if let currentItem = selectedFilterItem, currentItem.isAllItem {
                        selectedFilterItem = LibraryFilterItem.allItem(for: selectedFilterType, totalCount: libraryManager.totalTrackCount)
                    }
                }
                .onChange(of: selectedFilterItem) {
                    updateFilteredTracks()
                }
                .onChange(of: selectedFilterType) {
                    updateFilteredTracks()
                }
                .onChange(of: libraryManager.totalTrackCount) {
                    updateFilteredTracks()
                }
                .onChange(of: pendingFilter) {
                    processPendingFilter()
                }
                .onChange(of: libraryManager.globalSearchText) {
                    handleGlobalSearch()
                }
                .onChange(of: trackTableSortOrder) { _, _ in
                    updateFilteredTracks()
                }
                .onReceive(NotificationCenter.default.publisher(for: .libraryDataDidChange)) { _ in
                    updateFilteredTracks()
                }
        }
    }

    // MARK: - Helper Methods

    private func processPendingFilter() {
        guard let request = pendingFilter else { return }
        
        pendingFilter = nil
        selectedFilterType = request.filterType
        pendingSearchText = request.value
    }

    private func handleGlobalSearch() {
        isLibrarySearchActive = true
        Task {
            try? await Task.sleep(nanoseconds: TimeConstants.searchDebounceDuration)
            await MainActor.run {
                updateFilteredTracks()
                isLibrarySearchActive = false
            }
        }
    }

    init(
        selectedFilterType: Binding<LibraryFilterType>,
        selectedFilterItem: Binding<LibraryFilterItem?>,
        pendingSearchText: Binding<String?>,
        pendingFilter: Binding<LibraryFilterRequest?> = .constant(nil)
    ) {
        self._selectedFilterType = selectedFilterType
        self._selectedFilterItem = selectedFilterItem
        self._pendingSearchText = pendingSearchText
        self._pendingFilter = pendingFilter
    }

    // MARK: - Tracks List View

    private var tracksListView: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            TrackListHeader(
                title: headerTitle,
                sortOrder: $trackTableSortOrder,
                tableRowSize: $trackTableRowSize
            )

            Divider()

            // Tracks list content
            if isFilterLoading && cachedFilteredTracks.isEmpty {
                loadingView
            } else if cachedFilteredTracks.isEmpty && !isLibrarySearchActive {
                emptyFilterView
            } else {
                VStack(spacing: 0) {
                    TrackView(
                        tracks: cachedFilteredTracks,
                        selectedTrackID: $selectedTrackID,
                        playlistID: nil,
                        entityID: nil,
                        sortOrder: $trackTableSortOrder,
                        onPlayTrack: { track in
                            playlistManager.playTrack(track, fromTracks: cachedFilteredTracks)
                            playlistManager.currentQueueSource = .library
                            hydrateCurrentFilterQueue(
                                afterSelecting: track,
                                filterType: selectedFilterType,
                                filterItem: selectedFilterItem
                            )
                        },
                        contextMenuItems: { track, playbackManager in
                            TrackContextMenu.createMenuItems(
                                for: track,
                                playbackManager: playbackManager,
                                playlistManager: playlistManager,
                                currentContext: .library
                            )
                        },
                        hasMoreTracks: hasMoreFilteredTracks,
                        isLoadingMoreTracks: isFilterLoading,
                        onReachBottom: {
                            loadNextFilteredTracksPage()
                        }
                    )
                    .id(trackListIdentity)

                    if shouldShowPaginationFooter {
                        TrackPaginationFooter(
                            loadedCount: cachedFilteredTracks.count,
                            totalCount: currentTrackTotalCount,
                            pageSize: DatabaseConstants.trackListPageSize,
                            isLoading: isFilterLoading,
                            hasMore: hasMoreFilteredTracks
                        )
                    }
                }
            }
        }
    }

    // MARK: - Tracks List Header

    private var headerTitle: String {
        if !libraryManager.globalSearchText.isEmpty {
            return "Search Results"
        } else if let filterItem = selectedFilterItem {
            if filterItem.isAllItem {
                return "All Tracks"
            } else {
                return filterItem.name
            }
        } else {
            return "All Tracks"
        }
    }

    // MARK: - Empty Filter View

    private var emptyFilterView: some View {
        VStack(spacing: 16) {
            Image(systemName: Icons.musicNoteList)
                .font(.system(size: 48))
                .foregroundColor(.gray)

            Text(libraryManager.globalSearchText.isEmpty ? "No Tracks Found" : "No Search Results")
                .font(.headline)

            if !libraryManager.globalSearchText.isEmpty {
                Text("No tracks found matching \"\(libraryManager.globalSearchText)\"")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            } else if let filterItem = selectedFilterItem, !filterItem.isAllItem {
                Text("No tracks found for \"\(filterItem.name)\"")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            } else {
                Text("No tracks match the current filter")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private var loadingView: some View {
        VStack(spacing: 16) {
            ProgressView()
                .controlSize(.regular)

            Text("Loading Tracks")
                .font(.headline)

            Text("Updating the current library selection...")
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    // MARK: - Filtering Tracks Helper

    private func updateFilteredTracks() {
        filterUpdateTask?.cancel()
        selectedTrackID = nil
        isFilterLoading = false
        filterRequestID = UUID()
        
        if !libraryManager.globalSearchText.isEmpty {
            isFilterLoading = false
            filteredTrackOffset = 0
            hasMoreFilteredTracks = false
            var tracks = libraryManager.searchResults
            
            if let filterItem = selectedFilterItem, !filterItem.isAllItem {
                tracks = tracks.filter { track in
                    selectedFilterType.trackMatches(track, filterValue: filterItem.name)
                }
            }
            
            cachedFilteredTracks = tracks
        } else {
            if selectedFilterItem != nil {
                loadNextFilteredTracksPage(reset: true)
            } else {
                isFilterLoading = false
                cachedFilteredTracks = []
                filteredTrackOffset = 0
                hasMoreFilteredTracks = false
            }
        }
    }

    private var shouldShowPaginationFooter: Bool {
        libraryManager.globalSearchText.isEmpty && (!cachedFilteredTracks.isEmpty || hasMoreFilteredTracks)
    }

    private var currentTrackTotalCount: Int? {
        if !libraryManager.globalSearchText.isEmpty {
            return libraryManager.searchResults.count
        }

        if let selectedFilterItem {
            return selectedFilterItem.isAllItem ? libraryManager.totalTrackCount : selectedFilterItem.count
        }

        return nil
    }

    private func loadNextFilteredTracksPage(reset: Bool = false) {
        guard !libraryManager.globalSearchText.isEmpty || selectedFilterItem != nil else {
            cachedFilteredTracks = []
            filteredTrackOffset = 0
            hasMoreFilteredTracks = false
            isFilterLoading = false
            return
        }

        guard reset || !isFilterLoading else { return }
        guard reset || hasMoreFilteredTracks else { return }
        guard let selectedFilterItem else { return }

        let requestID = reset ? UUID() : filterRequestID
        let nextOffset = reset ? 0 : filteredTrackOffset
        let sortField = TrackSortField.detect(from: trackTableSortOrder)
        let ascending = TrackSortField.isAscending(from: trackTableSortOrder)
        let databaseManager = libraryManager.databaseManager
        let filterType = selectedFilterType
        let filterValue = selectedFilterItem.name

        if reset {
            filterRequestID = requestID
            cachedFilteredTracks = []
            filteredTrackOffset = 0
            hasMoreFilteredTracks = true
        }

        isFilterLoading = true

        filterUpdateTask = Task {
            let tracks = await Task.detached {
                if selectedFilterItem.isAllItem {
                    return databaseManager.getAllTracksPage(
                        limit: DatabaseConstants.trackListPageSize,
                        offset: nextOffset,
                        sortField: sortField,
                        ascending: ascending
                    )
                }

                return databaseManager.getTracksPage(
                    filterType: filterType,
                    value: filterValue,
                    limit: DatabaseConstants.trackListPageSize,
                    offset: nextOffset,
                    sortField: sortField,
                    ascending: ascending
                )
            }.value

            guard !Task.isCancelled else { return }

            await MainActor.run {
                guard filterRequestID == requestID else { return }

                if reset {
                    cachedFilteredTracks = tracks
                } else {
                    cachedFilteredTracks.append(contentsOf: tracks)
                }

                filteredTrackOffset = nextOffset + tracks.count
                hasMoreFilteredTracks = tracks.count == DatabaseConstants.trackListPageSize
                isFilterLoading = false
            }
        }
    }

    private func hydrateCurrentFilterQueue(
        afterSelecting track: Track,
        filterType: LibraryFilterType,
        filterItem: LibraryFilterItem?
    ) {
        guard libraryManager.globalSearchText.isEmpty else { return }
        guard let filterItem else { return }

        let databaseManager = libraryManager.databaseManager
        let sortField = TrackSortField.detect(from: trackTableSortOrder)
        let ascending = TrackSortField.isAscending(from: trackTableSortOrder)
        let filterName = filterItem.name
        let isAllItem = filterItem.isAllItem
        let loadedTracks = cachedFilteredTracks
        let totalTrackCount = max(loadedTracks.count, currentTrackTotalCount ?? loadedTracks.count)

        queueHydrationTask?.cancel()
        queueHydrationTask = Task {
            guard let selectedIndex = loadedTracks.firstIndex(where: { $0.id == track.id }) else { return }

            let hydrationWindow = DatabaseConstants.queueHydrationWindow(
                totalCount: totalTrackCount,
                centeredAt: selectedIndex
            )
            guard !hydrationWindow.isEmpty else { return }

            let windowAlreadyLoaded = hydrationWindow.lowerBound == 0 && hydrationWindow.upperBound <= loadedTracks.count
            var hydratedTracks: [Track] = []
            var offset = hydrationWindow.lowerBound

            if windowAlreadyLoaded {
                hydratedTracks = Array(loadedTracks[hydrationWindow])
            }

            while !windowAlreadyLoaded && offset < hydrationWindow.upperBound {
                let pageLimit = min(DatabaseConstants.trackListPageSize, hydrationWindow.upperBound - offset)
                let page = await Task.detached {
                    if isAllItem {
                        return databaseManager.getAllTracksPage(
                            limit: pageLimit,
                            offset: offset,
                            sortField: sortField,
                            ascending: ascending
                        )
                    }

                    return databaseManager.getTracksPage(
                        filterType: filterType,
                        value: filterName,
                        limit: pageLimit,
                        offset: offset,
                        sortField: sortField,
                        ascending: ascending
                    )
                }.value

                guard !Task.isCancelled else { return }

                hydratedTracks.append(contentsOf: page)

                if page.isEmpty {
                    break
                }

                offset += page.count
            }

            await MainActor.run {
                guard libraryManager.globalSearchText.isEmpty else { return }
                guard selectedFilterType == filterType else { return }
                guard selectedFilterItem?.name == filterName else { return }
                guard playlistManager.currentQueue.indices.contains(playlistManager.currentQueueIndex) else { return }
                guard playlistManager.currentQueue[playlistManager.currentQueueIndex].id == track.id else { return }

                playlistManager.replaceCurrentQueue(with: hydratedTracks, startingAt: track, source: .library)
            }
        }
    }

    private var trackListIdentity: String {
        let filterName = selectedFilterItem?.name ?? "none"
        let sortField = TrackSortField.detect(from: trackTableSortOrder).rawValue
        let sortAscending = TrackSortField.isAscending(from: trackTableSortOrder)
        return "\(selectedFilterType.rawValue)|\(filterName)|\(libraryManager.globalSearchText)|\(sortField)|\(sortAscending)"
    }
}

#Preview {
    @Previewable @State var filterType: LibraryFilterType = .artists
    @Previewable @State var filterItem: LibraryFilterItem?
    @Previewable @State var searchText: String?

    LibraryView(
        selectedFilterType: $filterType,
        selectedFilterItem: $filterItem,
        pendingSearchText: $searchText
    )
        .environmentObject({
            let coordinator = AppCoordinator()
            return coordinator.playbackManager
        }())
        .environmentObject({
            let coordinator = AppCoordinator()
            return coordinator.libraryManager
        }())
        .environmentObject({
            let coordinator = AppCoordinator()
            return coordinator.playlistManager
        }())
}
