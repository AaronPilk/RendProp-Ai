import SwiftUI

struct WorkspacePickerView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = WorkspaceStore.shared
    @State private var storageError: String?
    var body: some View {
        List {
            Section {
                ForEach(store.selectionChoices) { workspace in
                    Button {
                        Task {
                            guard model.prepareWorkspaceSwitch() else { storageError = "Couldn’t save this listing library’s local changes. Nothing was switched. Free some iPhone storage and try again."; return }
                            storageError = nil
                            if await store.select(workspace) { await model.refreshCloudWorkspace(); dismiss() }
                        }
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(workspace.displayName).foregroundStyle(Theme.ink)
                                Text(workspace.roleLabel).font(.caption).foregroundStyle(Theme.inkDim)
                                if store.workspaces.filter({ $0.displayName.caseInsensitiveCompare(workspace.displayName) == .orderedSame }).count > 1 {
                                    Text("Library ID · \(workspace.id.uuidString.lowercased().suffix(8))")
                                        .font(.caption2).foregroundStyle(Theme.inkDim)
                                }
                            }
                            Spacer()
                            if store.selected?.id == workspace.id { Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.accent) }
                        }
                    }
                    .disabled(store.isSwitching || model.workspaceSwitchIsBusy)
                    .accessibilityIdentifier("workspace.select.\(workspace.id.uuidString.lowercased())")
                }
            } header: { Text("Agents’ listings") } footer: {
                Text("Choose whose listings to view. Each agent keeps a private library. Your subscription stays with the account that manages it; switching listings does not move purchases or saved work.")
            }
            if model.workspaceSwitchIsBusy {
                Section { Text("An upload or save is finishing. Wait for it to complete before switching.").foregroundStyle(Theme.inkDim) }
            }
            if let storageError { Section { Text(storageError).foregroundStyle(Theme.warn) } }
            if let message = store.errorMessage {
                Section { Text(message).foregroundStyle(Theme.warn); Button("Try again") { Task { await store.refresh() } } }
            }
            if store.isLoading || store.isSwitching { ProgressView() }
        }
        .navigationTitle("Switch agent")
        .task { await store.refresh() }
        .refreshable { await store.refresh() }
    }
}

struct WorkspaceEntry: View {
    @EnvironmentObject private var model: AppModel
    var showsRecoveryChoice = true
    @ObservedObject private var store = WorkspaceStore.shared
    @ObservedObject private var auth = AuthStore.shared

    private var presentation: WorkspaceEntryPresentation {
        .mode(canSwitch: store.canSwitchAgentLibraries, choices: store.selectionChoices.count,
              selected: store.selected != nil, showsRecovery: showsRecoveryChoice)
    }
    private var entryLabel: some View {
        HStack(spacing: 10) {
            Image(systemName: "building.2.crop.circle").foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 3) {
                Text(store.displayName).font(.subheadline.weight(.semibold))
                Text(presentation == .switchAgent ? "Agents’ listings · tap to switch" : "Your listings · reconnect")
                    .font(.caption).foregroundStyle(Theme.inkDim)
                if presentation == .reconnect, let message = store.errorMessage {
                    Text(message).font(.caption).foregroundStyle(Theme.warn)
                }
            }
            Spacer()
            if store.isLoading { ProgressView() }
            else { Image(systemName: presentation == .switchAgent ? "chevron.right" : "arrow.clockwise").font(.caption).foregroundStyle(Theme.inkDim) }
        }
    }
    var body: some View {
        Group {
            if Config.useLiveBackend {
                if presentation == .switchAgent {
                    NavigationLink { WorkspacePickerView() } label: { entryLabel }
                        .buttonStyle(.plain).accessibilityIdentifier("workspace.current")
                } else if presentation == .reconnect {
                    Button { Task { await store.refresh(); await model.refreshCloudWorkspace() } } label: { entryLabel }
                        .buttonStyle(.plain).disabled(store.isLoading)
                        .accessibilityIdentifier("workspace.reconnect")
                }
            }
        }
        // Keep refreshing memberships when the single-account control is hidden.
        .task(id: auth.userID) {
            if Config.useLiveBackend { await store.refresh() }
        }
    }
}
