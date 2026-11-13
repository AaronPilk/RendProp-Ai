#if SPATIAL_CAPTURE_LAB
import SwiftUI

/// The experimental build has one user-facing door for room tours. Local
/// panoramas remain usable while the separate cloud reconstruction is off.
/// This screen never changes provider availability or starts a cloud job.
struct SpatialTestingHubView: View {
    let listing: Listing
    @EnvironmentObject private var model: AppModel
    @ObservedObject private var auth = AuthStore.shared
    @State private var showWalkingCapture = false
    @State private var capability: SpatialCapability?
    @State private var capabilityError: String?
    @State private var checkingCapability = false
    @State private var capabilityRequest = UUID()

    private struct CapabilityContext: Equatable {
        let owner: String?
        let revision: UInt64
        let org: UUID?
        let listingID: UUID?
    }

    private var currentListing: Listing? {
        model.realProjects.first { $0.id == listing.id }
    }

    private var capabilityContext: CapabilityContext {
        CapabilityContext(owner: auth.userID, revision: auth.syncSessionRevision,
                          org: WorkspaceContext.selectedOrgID, listingID: currentListing?.id)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let currentListing {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("TESTFLIGHT · 3D TOURS").font(.rpKicker).foregroundStyle(Theme.accent)
                        Text("Start with a room tour").font(.rpTitle).foregroundStyle(Theme.ink)
                        Text(currentListing.address).font(.rpCaption).foregroundStyle(Theme.inkDim)
                        Text("A room tour lets you look around the property. Floor plans show the layout and measurements; they have their own card.")
                            .font(.rpBody).foregroundStyle(Theme.inkDim)
                    }
                    guidedTourCard
                    walkingCaptureCard
                    cloudCard(currentListing)
                } else {
                    Text("This listing isn't available").font(.rpHeadline).foregroundStyle(Theme.ink)
                    Text("Return to Listings and open one of your active listings to test a room tour.")
                        .font(.rpBody).foregroundStyle(Theme.inkDim)
                }
            }.padding()
        }
        .background(Theme.bg)
        .navigationTitle("3D tours")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("spatial.hub.root")
        .task(id: capabilityContext) { await checkCapability() }
        .onReceive(NotificationCenter.default.publisher(for: .rendpropWorkspaceChanged)) { _ in
            showWalkingCapture = false
            capability = nil
            Task { await checkCapability() }
        }
        .onChange(of: auth.userID) { _ in showWalkingCapture = false }
        .onDisappear { capabilityRequest = UUID() }
        .fullScreenCover(isPresented: $showWalkingCapture) { SpatialCaptureLabView() }
    }

    private var guidedTourCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Room tour · start here", systemImage: "pano")
                .font(.rpHeadline).foregroundStyle(Theme.ink)
            Text("Turn in place while the phone saves 38 photos. Preview the room, then add another viewpoint only where you need it.")
                .font(.rpBody).foregroundStyle(Theme.inkDim)
            NavigationLink { GuidedPanoramaLabView() } label: {
                Label("Capture or open a room tour", systemImage: "viewfinder")
                    .frame(maxWidth: .infinity, minHeight: 46)
            }
            .buttonStyle(.borderedProminent).tint(Theme.accent)
            .accessibilityIdentifier("spatial.hub.guided")
            Text("Open saved tours to look around and switch viewpoints. Export scan files to share the original photos for testing. These local tours stay in this iPhone's test library; they are not attached to the listing or published yet.")
                .font(.rpCaption).foregroundStyle(Theme.inkDim)
            Text("This is a photo-based preview, not a completed 3D model. Keep the app open while capturing.")
                .font(.rpCaption).foregroundStyle(Theme.inkDim)
        }.card()
    }

    private var walkingCaptureCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Walking scan · advanced test", systemImage: "viewfinder")
                .font(.rpHeadline).foregroundStyle(Theme.ink)
            Text("Walk slowly around one room to save overlapping photos and camera positions for reconstruction testing. This capture does not create a tour by itself.")
                .font(.rpBody).foregroundStyle(Theme.inkDim)
            Button { showWalkingCapture = true } label: {
                Label("Record or export a walking scan", systemImage: "camera.viewfinder")
                    .frame(maxWidth: .infinity, minHeight: 46)
            }
            .buttonStyle(.bordered).tint(Theme.accent)
            .accessibilityIdentifier("spatial.hub.walking")
            Text("Reopen or export saved scans from that screen. Walking scans also stay in this iPhone's test library; they are not attached to this listing. Nothing uploads automatically.")
                .font(.rpCaption).foregroundStyle(Theme.inkDim)
        }.card()
    }

    @ViewBuilder private func cloudCard(_ currentListing: Listing) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Full 3D reconstruction · cloud test", systemImage: "cube.transparent")
                .font(.rpHeadline).foregroundStyle(Theme.ink)
            if checkingCapability {
                ProgressView("Checking cloud availability…").font(.rpCaption)
            } else if capability?.enabled == true {
                Text("The service is available for this test. Capture, upload and review rooms before sharing any completed output.")
                    .font(.rpBody).foregroundStyle(Theme.inkDim)
                NavigationLink { SpatialTourView(listing: currentListing) } label: {
                    Label("Open cloud 3D test", systemImage: "cube.transparent")
                        .frame(maxWidth: .infinity, minHeight: 46)
                }
                .buttonStyle(.bordered).tint(Theme.accent)
                .accessibilityIdentifier("spatial.hub.cloud")
            } else {
                Text(capability == nil
                     ? "Cloud availability couldn't be confirmed. Local room tours still work above."
                     : "Cloud reconstruction isn't available right now. Local room tours still work above.")
                    .font(.rpBody).foregroundStyle(Theme.inkDim)
                if let capabilityError {
                    Text(capabilityError).font(.rpCaption).foregroundStyle(Theme.inkDim)
                }
                Button("Check cloud availability") { Task { await checkCapability() } }
                    .tint(Theme.accent)
                    .accessibilityIdentifier("spatial.hub.checkCloud")
            }
            Text("A successful scan is not proof of a usable model. Full geometry and navigation still need real-room testing.")
                .font(.rpCaption).foregroundStyle(Theme.inkDim)
        }.card()
    }

    @MainActor private func checkCapability() async {
        let context = capabilityContext
        let request = UUID()
        capabilityRequest = request
        capability = nil
        capabilityError = nil
        guard context.listingID != nil else { checkingCapability = false; return }
        checkingCapability = true
        defer { if capabilityRequest == request { checkingCapability = false } }
        do {
            let answer = try await model.api.spatialCapability()
            guard capabilityRequest == request, capabilityContext == context, !Task.isCancelled else { return }
            capability = answer
        } catch {
            guard capabilityRequest == request, capabilityContext == context, !Task.isCancelled else { return }
            capabilityError = error.localizedDescription
        }
    }
}

/// Settings uses the same listing selection rules as Home. Samples, inactive
/// listings and another member's library are not offered as destinations.
struct SpatialTestingListingPicker: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        List {
            Section {
                ForEach(model.realProjects) { listing in
                    NavigationLink { SpatialTestingHubView(listing: listing) } label: {
                        Label(listing.address, systemImage: SpaceType.current.systemImage)
                    }
                    .accessibilityIdentifier("spatial.hub.chooseListing.\(listing.id.uuidString)")
                }
                if model.realProjects.isEmpty {
                    Text("Add a listing using Get started on Home, then return here to test its room tour.")
                        .foregroundStyle(Theme.inkDim)
                }
            } header: {
                Text("Choose a listing")
            } footer: {
                Text("The same 3D tours card is also available on Home and in your listing's toolbox.")
            }
        }
        .navigationTitle("3D tours")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("spatial.hub.listingPicker")
    }
}
#endif
