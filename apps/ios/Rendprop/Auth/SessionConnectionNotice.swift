import SwiftUI

private struct SessionConnectionNotice: ViewModifier {
    @ObservedObject private var auth = AuthStore.shared
    var isActive: Bool
    var onCancel: (() -> Void)?

    func body(content: Content) -> some View {
        content.safeAreaInset(edge: .bottom, spacing: 0) {
            if isActive, auth.sessionConnectionState != .idle {
                VStack(alignment: .leading, spacing: 8) {
                    Label(auth.sessionConnectionState == .connecting
                          ? "Connecting…" : "Waiting for connection",
                          systemImage: "wifi.exclamationmark")
                        .font(.headline)
                    Text("Your work is saved on this phone. We'll retry automatically and continue when connected.")
                        .font(.caption)
                    HStack {
                        Button("Retry connection") { auth.retrySessionConnection() }
                            .accessibilityIdentifier("session.connection.retry")
                        if let onCancel {
                            Spacer()
                            Button("Cancel pending action", action: onCancel)
                                .accessibilityIdentifier("session.connection.cancel")
                        }
                    }
                }
                .foregroundStyle(Theme.ink)
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.bg)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("session.connection.notice")
            }
        }
    }
}

extension View {
    func sessionConnectionNotice(isActive: Bool = true, onCancel: (() -> Void)? = nil) -> some View {
        modifier(SessionConnectionNotice(isActive: isActive, onCancel: onCancel))
    }
}
