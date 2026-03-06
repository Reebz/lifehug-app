import SwiftUI

@Observable
@MainActor
final class ModelState {
    var downloadProgress: Double = 0
    var status: ModelStatus = .notDownloaded
    var isLoaded: Bool = false

    enum ModelStatus {
        case notDownloaded
        case downloading
        case loading
        case ready
        case error(String)
    }
}
