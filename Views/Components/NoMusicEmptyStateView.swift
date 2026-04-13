import SwiftUI

struct NoMusicEmptyStateView: View {
    @EnvironmentObject var libraryManager: LibraryManager
    @StateObject private var notificationManager = NotificationManager.shared
    @State private var stableScanningState = false
    @State private var scanningStateTimer: Timer?
    @State private var showFormatsPopover = false

    // Customization options
    let context: EmptyStateContext

    enum EmptyStateContext {
        case mainWindow
        case settings

        var iconSize: CGFloat {
            switch self {
            case .mainWindow: return 80
            case .settings: return 60
            }
        }

        var spacing: CGFloat {
            switch self {
            case .mainWindow: return 24
            case .settings: return 20
            }
        }

        var titleFont: Font {
            switch self {
            case .mainWindow: return .largeTitle
            case .settings: return .title2
            }
        }
    }
    
    /// Determines if scanning state should be shown based on context and initial scan progress
    private var shouldShowScanningState: Bool {
        switch context {
        case .mainWindow:
            // During initial onboarding scan, show scanning state until threshold is reached
            if libraryManager.isInitialOnboardingScan {
                return !libraryManager.hasReachedInitialScanThreshold
            }
            // For non-initial scans, show scanning state only if no sources are configured yet
            return !libraryManager.hasConfiguredSources
        case .settings:
            // Settings always shows scanning state when scanning is active
            return true
        }
    }

    var body: some View {
        VStack(spacing: context.spacing) {
            if stableScanningState && shouldShowScanningState {
                // Show scanning animation during initial scan until threshold is reached
                scanningProgressContent
                    .transition(.opacity)
            } else if !libraryManager.hasConfiguredSources {
                // Show empty state only when no folders or remote sources exist
                emptyStateContent
                    .transition(.opacity)
            } else {
                noContentView
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.3), value: stableScanningState)
        .animation(.easeInOut(duration: 0.3), value: libraryManager.hasReachedInitialScanThreshold)
        .frame(maxWidth: context == .mainWindow ? .infinity : 500)
        .frame(maxHeight: context == .mainWindow ? .infinity : 400)
        .padding(context == .mainWindow ? 60 : 40)
        .onAppear {
            setupScanningStateObserver()
        }
        .onDisappear {
            scanningStateTimer?.invalidate()
        }
        .onChange(of: libraryManager.isScanning) { _, newValue in
            updateStableScanningState(newValue)
        }
    }

    private func setupScanningStateObserver() {
        // Initialize with current state
        stableScanningState = libraryManager.isScanning
    }

    private func updateStableScanningState(_ isScanning: Bool) {
        // Cancel any pending timer
        scanningStateTimer?.invalidate()

        if isScanning {
            // Turn on immediately
            stableScanningState = true
        } else {
            // Delay turning off to prevent flashing
            scanningStateTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { _ in
                stableScanningState = false
            }
        }
    }

    // MARK: - Empty State Content

    private var noContentView: some View {
        VStack(spacing: 16) {
            Image(systemName: Icons.musicNoteList)
                .font(.system(size: 48))
                .foregroundColor(.gray)

            Text("No music found")
                .font(.headline)
                .foregroundColor(.secondary)

            Text("Your library sources are being scanned for music files")
                .font(.subheadline)
                .foregroundColor(.secondary.opacity(0.8))
        }
    }

    private var emptyStateContent: some View {
        VStack(spacing: context.spacing) {
            // Icon with subtle animation
            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(0.1))
                    .frame(width: context.iconSize * 1.8, height: context.iconSize * 1.8)

                Image(systemName: Icons.folderBadgePlus)
                    .font(.system(size: context.iconSize, weight: .light))
                    .foregroundColor(.accentColor)
                    .symbolEffect(.pulse.byLayer, options: .repeating.speed(0.5))
            }

            VStack(spacing: 12) {
                Text("No Music Added Yet")
                    .font(context.titleFont)
                    .fontWeight(.semibold)

                VStack(spacing: 8) {
                    Text("Add local folders or configure an Emby source to get started")
                        .font(.title3)
                        .foregroundColor(.secondary)

                    Text("You can mix local folders with remote library sources")
                        .font(.subheadline)
                        .foregroundColor(.secondary.opacity(0.7))
                }
                .multilineTextAlignment(.center)
            }

            HStack(spacing: 12) {
                Button(action: { libraryManager.addFolder() }) {
                    HStack(spacing: 6) {
                        Image(systemName: Icons.plusCircleFill)
                            .font(.system(size: 16))
                        Text("Add Music Folder")
                            .font(.system(size: 14, weight: .medium))
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.accentColor)
                            .shadow(color: Color.accentColor.opacity(0.3), radius: 6, x: 0, y: 3)
                    )
                }
                .buttonStyle(PlainButtonStyle())

                Button(action: openSourcesSettings) {
                    HStack(spacing: 6) {
                        Image(systemName: "externaldrive.connected.to.line.below")
                            .font(.system(size: 16))
                        Text("Configure Emby")
                            .font(.system(size: 14, weight: .medium))
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                }
                .buttonStyle(.bordered)
            }

            // Supported formats
            Button {
                showFormatsPopover.toggle()
            } label: {
                Text("Supported formats")
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundColor(.secondary)
                    .underline()
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showFormatsPopover, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Supported Formats")
                        .font(.headline)

                    Divider()

                    ScrollView {
                        Text(AudioFormat.supportedFormatsDisplay)
                            .font(.system(size: 12, design: .monospaced))
                            .textSelection(.enabled)
                            .padding(.vertical, 4)
                    }
                    .frame(maxWidth: 320, maxHeight: 160)
                }
                .padding(12)
                .frame(width: 340)
            }
            .padding(.top, 8)
        }
        .transition(.opacity)
    }

    // MARK: - Scanning Progress Content

    private var scanningProgressContent: some View {
        VStack(spacing: 20) {
            ActivityAnimation(size: .large)

            VStack(spacing: 8) {
                Text("Scanning Music Library")
                    .font(.title2)
                    .fontWeight(.semibold)

                Text(scanningStatusText)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 350, minHeight: 40)
            }

            // Track count
            if libraryManager.hasConfiguredSources {
                Text("\(libraryManager.totalTrackCount) tracks found")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Text("This may take a few minutes for large libraries")
                .font(.caption)
                .foregroundColor(.secondary.opacity(0.7))
                .italic()
        }
        .transition(.opacity)
    }

    private func openSourcesSettings() {
        NotificationCenter.default.post(name: NSNotification.Name("OpenSettings"), object: nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            NotificationCenter.default.post(
                name: NSNotification.Name("SettingsSelectTab"),
                object: SettingsView.SettingsTab.sources
            )
        }
    }

    private var scanningStatusText: String {
        let status = notificationManager.currentActivityStatus.trimmingCharacters(in: .whitespacesAndNewlines)
        return status.isEmpty ? "Discovering your music..." : status
    }
}

// MARK: - Preview

#Preview("Main Window") {
    NoMusicEmptyStateView(context: .mainWindow)
        .environmentObject(LibraryManager())
        .frame(width: 800, height: 600)
}

#Preview("Settings") {
    NoMusicEmptyStateView(context: .settings)
        .environmentObject(LibraryManager())
        .frame(width: 600, height: 500)
}

#Preview("Scanning") {
    NoMusicEmptyStateView(context: .mainWindow)
        .environmentObject({
            let manager = LibraryManager()
            manager.isScanning = true
            return manager
        }())
        .frame(width: 800, height: 600)
}
