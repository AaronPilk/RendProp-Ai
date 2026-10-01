import SwiftUI

struct WorkspacePickerView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = WorkspaceStore.shared
    @State private var storageError: String?
    var body: some View {
        List {
            Section {
                ForEach(store.workspaces) { workspace in
                    Button {
                        Task {
                            guard model.prepareWorkspaceSwitch() else { storageError = "Couldn’t save this workspace’s local changes. Nothing was switched. Free some iPhone storage and try again."; return }
                            storageError = nil
                            if await store.select(workspace) { await model.refreshCloudWorkspace(); dismiss() }
                        }
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(workspace.displayName).foregroundStyle(Theme.ink)
                                Text(workspace.roleLabel).font(.caption).foregroundStyle(Theme.inkDim)
                            }
                            Spacer()
                            if store.selected?.id == workspace.id { Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.accent) }
                        }
                    }
                    .disabled(store.isSwitching || model.workspaceSwitchIsBusy)
                    .accessibilityIdentifier("workspace.select.\(workspace.id.uuidString.lowercased())")
                }
            } header: { Text("Your workspaces") } footer: {
                Text("New homes, branding and plan changes use the workspace you choose. Existing work stays with its original workspace.")
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
        .navigationTitle("Workspace")
        .task { await store.refresh() }
        .refreshable { await store.refresh() }
    }
}

struct WorkspaceEntry: View {
    @ObservedObject private var store = WorkspaceStore.shared
    @ObservedObject private var auth = AuthStore.shared
    var body: some View {
        if Config.useLiveBackend {
            NavigationLink { WorkspacePickerView() } label: {
                HStack(spacing: 10) {
                    Image(systemName: "building.2.crop.circle").foregroundStyle(Theme.accent)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(store.displayName).font(.subheadline.weight(.semibold))
                        Text("Workspace · tap to change").font(.caption).foregroundStyle(Theme.inkDim)
                    }
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(Theme.inkDim)
                }
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("workspace.current")
            .task(id: auth.userID) { await store.refresh() }
        }
    }
}
