// Synthetic renderer fixture. No customer media, camera, provider or Photos writes.
import Foundation
import SwiftUI
struct EnhancedPhoto: Identifiable, Hashable, Sendable {
    let id: String
    let originalURL: URL
    let enhancedURL: URL
    var savedVersion: PhotoVersionHistory.Version? {
        guard let index = try? PhotoVersionHistory.load(directory: enhancedURL.deletingLastPathComponent()) else { return nil }
        return index.versions[id] ?? index.versions.values.first { $0.imageFile == enhancedURL.lastPathComponent }
    }
}
@MainActor final class AuthStore: ObservableObject {
    static let shared = AuthStore()
    @Published var userID: String? = "test"
    var syncSessionRevision: UInt64 = 1
}
@MainActor enum WorkspaceContext { static var selectedOrgID: UUID? { nil } }
struct ShareSheet: View {
    let items: [Any]
    var body: some View { EmptyView() }
}

extension Notification.Name { static let rendpropWorkspaceChanged = Notification.Name("testWorkspaceChanged") }
