import SwiftUI

struct TrackPaginationFooter: View {
    let loadedCount: Int
    let totalCount: Int?
    let pageSize: Int
    let isLoading: Bool
    let hasMore: Bool

    private var summaryText: String {
        if let totalCount {
            return "Showing \(loadedCount) of \(totalCount) tracks"
        }

        return "Showing \(loadedCount) tracks"
    }

    private var nextPageCount: Int {
        guard let totalCount else { return pageSize }
        return max(0, min(pageSize, totalCount - loadedCount))
    }

    private var statusText: String? {
        guard hasMore else { return nil }

        if isLoading {
            return "Loading \(nextPageCount) more..."
        }

        return "Scroll to load \(nextPageCount) more"
    }

    var body: some View {
        HStack(spacing: 12) {
            Text(summaryText)
                .font(.caption)
                .foregroundColor(.secondary)

            Spacer()

            if let statusText {
                HStack(spacing: 8) {
                    if isLoading {
                        ProgressView()
                            .controlSize(.small)
                    }

                    Text(statusText)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color(NSColor.windowBackgroundColor))
    }
}
