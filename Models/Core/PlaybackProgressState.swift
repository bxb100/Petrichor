import Foundation

class PlaybackProgressState: ObservableObject {
    @Published var currentTime: Double = 0
    @Published var bufferedProgress: Double = 0
}
