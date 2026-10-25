import SwiftUI
import AVKit

/// Presentation only. A selection or a rendered ready state is never authority
/// to submit paid work; the typed service owns admission and accepted receipts.
enum AerialOpeningPhase: Equatable {
    case choosing, checkingPhoto, costReview, generating, stopping, review, ready, stopped
    case needsAttention(String)

    var isBusy: Bool {
        switch self {
        case .checkingPhoto, .generating, .stopping: return true
        default: return false
        }
    }

    var allowsPhotoChanges: Bool {
        switch self {
        case .choosing, .costReview, .stopped: return true
        default: return false
        }
    }
}

struct AerialOpeningPhotoChoice: Identifiable, Equatable {
    enum Eligibility: Equatable {
        case unchecked, checking, eligible
        case ineligible(String)
    }
    let id: String
    let title: String
    let url: URL
    var eligibility: Eligibility = .unchecked
    var sourceWidth = 0
    var sourceHeight = 0
}

struct AerialOpeningPreview: Equatable {
    let id: String
    let sourcePhoto: AerialOpeningPhotoChoice
    let localVideoURL: URL?
    let aspectRatio: Double
    let durationLabel: String
    let disclosure: String
}

struct AerialOpeningPresentation: Equatable {
    var phase: AerialOpeningPhase = .choosing
    var photos: [AerialOpeningPhotoChoice] = []
    var selectedPhotoID: String?
    var opening: AerialOpeningPreview?
    var includeOpening = false
    var orderedVideoPhotos: [AerialOpeningPhotoChoice] = []
    /// Off until the actual typed service, quote and catalogue are integrated.
    var dispatchAvailable = false
    var hasSavedOpenings = false
    var canStopSavedRequest = false
    var quotedCost: String?
    var quotedDisclosure: String?
    var processorAllowed = false
    var quotedPhotoID: String?
    var aspect = "16:9"
    var reviewedCrop: AerialOpeningReviewedCrop?
    var cropPhotoID: String?
    var quotedCrop: AerialOpeningReviewedCrop?
    var quotedAspect: String?
    var availabilityMessage: String?
    var generationProgress: NativeGenerationProgress?

    var selectedPhoto: AerialOpeningPhotoChoice? { photos.first { $0.id == selectedPhotoID } }
    var hasReviewedCrop: Bool {
        guard let photo = selectedPhoto, let crop = reviewedCrop else { return false }
        return cropPhotoID == photo.id && crop.sourceWidth == photo.sourceWidth &&
            crop.sourceHeight == photo.sourceHeight && crop.isValid(aspect: aspect)
    }
    var canCheckPhoto: Bool {
        guard dispatchAvailable, hasReviewedCrop, let selectedPhoto else { return false }
        switch selectedPhoto.eligibility {
        case .ineligible, .checking: return false
        default: return true
        }
    }
    var canMakeOpening: Bool {
        processorAllowed && dispatchAvailable && phase == .costReview && selectedPhoto?.eligibility == .eligible &&
        hasReviewedCrop && quotedPhotoID == selectedPhotoID && quotedCrop == reviewedCrop && quotedAspect == aspect &&
        quotedCost?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }
}

/// Optional callbacks make disconnected states visibly unavailable. None of
/// these callbacks has a default that creates work, changes media or succeeds.
struct AerialOpeningActions {
    var choosePhoto: ((String) -> Void)?
    var chooseAspect: ((String) -> Void)?
    var changeCrop: ((AerialOpeningReviewedCrop) -> Void)?
    var addPhoto: (() -> Void)?
    var checkPhoto: (() -> Void)?
    var makeOpening: (() -> Void)?
    var setProcessorAllowed: ((Bool) -> Void)?
    var stop: (() -> Void)?
    var checkStatus: (() -> Void)?
    var review: (() -> Void)?
    var setIncluded: ((Bool) -> Void)?
    var chooseAnother: (() -> Void)?
    var openSaved: (() -> Void)?
    var close: (() -> Void)?
}

/// Events from this screen cannot turn an inactive or source-stale presentation
/// into paid work. The service still validates its durable quote and identity.
enum AerialOpeningInteraction {
    static func choosePhoto(_ id: String, state: AerialOpeningPresentation, actions: AerialOpeningActions) {
        guard state.phase.allowsPhotoChanges, state.photos.contains(where: { $0.id == id }) else { return }
        actions.choosePhoto?(id)
    }
    static func chooseAspect(_ aspect: String, state: AerialOpeningPresentation, actions: AerialOpeningActions) {
        guard state.phase.allowsPhotoChanges, ["16:9", "9:16"].contains(aspect) else { return }
        actions.chooseAspect?(aspect)
    }
    static func changeCrop(_ crop: AerialOpeningReviewedCrop, state: AerialOpeningPresentation, actions: AerialOpeningActions) {
        guard state.phase.allowsPhotoChanges, let photo = state.selectedPhoto,
              crop.sourceWidth == photo.sourceWidth, crop.sourceHeight == photo.sourceHeight,
              crop.isValid(aspect: state.aspect) else { return }
        actions.changeCrop?(crop)
    }
    static func addPhoto(state: AerialOpeningPresentation, actions: AerialOpeningActions) {
        guard state.phase.allowsPhotoChanges else { return }
        actions.addPhoto?()
    }
    static func checkPhoto(state: AerialOpeningPresentation, actions: AerialOpeningActions) {
        guard state.phase == .choosing || state.phase == .stopped, state.canCheckPhoto else { return }
        actions.checkPhoto?()
    }
    static func makeOpening(state: AerialOpeningPresentation, actions: AerialOpeningActions) {
        guard state.canMakeOpening else { return }
        actions.makeOpening?()
    }
    static func stop(state: AerialOpeningPresentation, actions: AerialOpeningActions) {
        guard state.phase == .checkingPhoto || state.phase == .generating else { return }
        actions.stop?()
    }
    static func setIncluded(_ included: Bool, state: AerialOpeningPresentation, actions: AerialOpeningActions) {
        guard state.phase == .ready, state.opening != nil else { return }
        actions.setIncluded?(included)
    }
}

struct AerialOpeningView: View {
    @Environment(\.dismiss) private var dismiss
    let listingTitle: String
    let state: AerialOpeningPresentation
    var actions = AerialOpeningActions()
    var isPresentedModally = false

    @ViewBuilder var body: some View {
        if isPresentedModally {
            NavigationStack {
                navigationContent
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button {
                                if let close = actions.close { close() } else { dismiss() }
                            } label: { Label("Close", systemImage: "xmark") }
                            .accessibilityHint("Closes this screen. Saved work stays with the home.")
                            .accessibilityIdentifier("aerialOpening.close")
                        }
                    }
            }
            .interactiveDismissDisabled(state.phase.isBusy)
        } else {
            navigationContent
        }
    }

    private var navigationContent: some View {
        ScrollView {
            AerialOpeningContent(listingTitle: listingTitle, state: state, actions: actions)
                .padding(20)
        }
        .background(Theme.bg)
        .navigationTitle("Aerial intro")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            AerialOpeningFooter(state: state, actions: actions)
                .padding(.horizontal, 20).padding(.vertical, 12)
                .background(.bar)
        }
    }
}

/// Kept separate from navigation so source-bound layout fixtures can render
/// the actual content at compact and accessibility sizes without live services.
struct AerialOpeningContent: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let listingTitle: String
    let state: AerialOpeningPresentation
    let actions: AerialOpeningActions

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            introduction
            if state.hasSavedOpenings, let openSaved = actions.openSaved {
                Button(action: openSaved) { Label("Choose a saved opening", systemImage: "play.rectangle.on.rectangle").font(.rpBody.weight(.semibold)).frame(maxWidth: .infinity) }
                    .buttonStyle(RendpropPillButtonStyle()).disabled(state.phase.isBusy)
                    .accessibilityIdentifier("aerialOpening.saved")
            }
            status
            if let progress = state.generationProgress {
                NativeGenerationProgressView(progress: progress).padding(16).modifier(RendpropContentSurface())
            }
            if let opening = state.opening { openingCard(opening) }
            if state.phase != .ready || state.opening == nil {
                photoChooser
                if state.selectedPhoto != nil { framing }
            }
            if state.opening != nil { sequence }
            if let message = state.availabilityMessage, !message.isEmpty {
                Label(message, systemImage: "info.circle")
                    .font(.rpCaption).foregroundStyle(Theme.inkDim)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: state.selectedPhotoID)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: state.includeOpening)
    }

    private var introduction: some View {
        let guideLayout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 14))
            : AnyLayout(HStackLayout(alignment: .top, spacing: 14))
        return VStack(alignment: .leading, spacing: 14) {
            Text(listingTitle).font(.rpCaption).foregroundStyle(Theme.inkDim)
                .lineLimit(2)
            Label(state.opening == nil ? "Start outside" : "Your opening", systemImage: state.opening == nil ? "house" : "airplane.departure")
                .font(.rpTitle).foregroundStyle(Theme.ink)
                .accessibilityAddTraits(.isHeader)
            Text(state.opening == nil ? "Choose the front of this home for one AI opening shot." : "Review the opening and choose whether it starts your video.")
                .font(.rpBody).foregroundStyle(Theme.inkDim)
                .fixedSize(horizontal: false, vertical: true)
            if state.opening == nil { guideLayout {
                Image(systemName: "house.fill")
                    .font(.system(size: 32, weight: .regular))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 68, height: 68)
                    .background(Theme.accentSoft, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 5) {
                    Label("Show the whole front", systemImage: "checkmark.circle.fill")
                        .font(.rpBody.weight(.semibold)).foregroundStyle(Theme.ink)
                    Text("Use an exterior view. An indoor room, doorway or balcony alone won’t work.")
                        .font(.rpCaption).foregroundStyle(Theme.inkDim)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } }
        }
    }

    @ViewBuilder private var status: some View {
        if state.generationProgress == nil {
        switch state.phase {
        case .choosing, .ready: EmptyView()
        case .checkingPhoto:
            statusCard("Preparing your photo", detail: "Saving your unchanged original and checking the opening setup.", symbol: nil)
        case .costReview:
            VStack(alignment: .leading, spacing: 10) {
                Label(state.selectedPhoto?.eligibility == .eligible ? "Original photo ready" : "Review exterior photo", systemImage: "checkmark.shield")
                    .font(.rpHeadline).foregroundStyle(Theme.ink)
                if let disclosure = state.quotedDisclosure {
                    Text(disclosure).font(.rpCaption).foregroundStyle(Theme.inkDim)
                        .fixedSize(horizontal: false, vertical: true)
                    Toggle(isOn: Binding(get: { state.processorAllowed }, set: { actions.setProcessorAllowed?($0) })) {
                        Text("Allow processing under these terms")
                            .font(.rpBody).fixedSize(horizontal: false, vertical: true)
                    }.tint(Theme.accent).accessibilityIdentifier("aerialOpening.processorPermission")
                }
                Text("Making other videos can reuse this opening.")
                    .font(.rpCaption).foregroundStyle(Theme.inkDim)
                    .fixedSize(horizontal: false, vertical: true)
            }.padding(18).modifier(RendpropContentSurface())
        case .generating:
            statusCard("Making your opening", detail: "You can leave this screen. The saved request stays with this home.", symbol: nil)
        case .stopping:
            statusCard("Confirming the stop", detail: "Waiting for the server to confirm. Your saved photos stay safe.", symbol: nil)
        case .review:
            statusCard("Review the opening", detail: "Check that it still shows your home before using it.", symbol: "play.rectangle")
        case .stopped:
            statusCard("Stopped", detail: "Your saved work is kept. Choose a photo when you’re ready to continue.", symbol: "pause.circle")
        case .needsAttention(let message):
            statusCard("Opening needs attention", detail: message, symbol: "exclamationmark.circle")
        }
        }
    }

    private func statusCard(_ title: String, detail: String, symbol: String?) -> some View {
        HStack(alignment: .top, spacing: 12) {
            if let symbol {
                Image(systemName: symbol).font(.title3).foregroundStyle(Theme.accent).accessibilityHidden(true)
            } else {
                ProgressView().tint(Theme.accent).accessibilityLabel("In progress")
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.rpHeadline).foregroundStyle(Theme.ink)
                    .accessibilityAddTraits(.isHeader)
                Text(detail).font(.rpBody).foregroundStyle(Theme.inkDim)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18).modifier(RendpropContentSurface())
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("aerialOpening.status")
    }

    private var photoChooser: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Front exterior photo").font(.rpHeadline).foregroundStyle(Theme.ink)
                .accessibilityAddTraits(.isHeader)
            if state.photos.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "photo.badge.plus").font(.system(size: 32, weight: .regular))
                        .foregroundStyle(Theme.accent).accessibilityHidden(true)
                    Text("Add a photo of the front of this home.")
                        .font(.rpBody).foregroundStyle(Theme.inkDim)
                        .multilineTextAlignment(.center)
                }.frame(maxWidth: .infinity).padding(.vertical, 18)
            } else {
                LazyVGrid(columns: dynamicTypeSize.isAccessibilitySize
                          ? [GridItem(.flexible(), alignment: .top)] : [GridItem(.flexible(), spacing: 12, alignment: .top), GridItem(.flexible(), spacing: 12, alignment: .top)], spacing: 16) {
                    ForEach(state.photos) { photo in
                        photoButton(photo)
                    }
                }
            }
            Button { AerialOpeningInteraction.addPhoto(state: state, actions: actions) } label: {
                Label("Add exterior photo", systemImage: "photo.badge.plus")
                    .font(.rpBody.weight(.semibold)).frame(maxWidth: .infinity)
            }
            .buttonStyle(RendpropPillButtonStyle())
            .disabled(!state.phase.allowsPhotoChanges || actions.addPhoto == nil)
            .accessibilityIdentifier("aerialOpening.addPhoto")
            Text("Choosing an intro photo keeps your listing’s photo selection unchanged.")
                .font(.rpCaption).foregroundStyle(Theme.inkDim)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(18).modifier(RendpropContentSurface())
    }

    private func photoButton(_ photo: AerialOpeningPhotoChoice) -> some View {
        let selected = state.selectedPhotoID == photo.id
        return Button { AerialOpeningInteraction.choosePhoto(photo.id, state: state, actions: actions) } label: {
            VStack(alignment: .leading, spacing: 8) {
                AerialOpeningPhotoThumbnail(url: photo.url)
                    .aspectRatio(1.25, contentMode: .fit)
                    .overlay(alignment: .topTrailing) {
                        Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 23, weight: .semibold))
                            .foregroundStyle(selected ? Theme.accent : Theme.ink)
                            .padding(6).background(.regularMaterial, in: Circle()).padding(8)
                            .accessibilityHidden(true)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(selected ? Theme.accent : Theme.border, lineWidth: selected ? 2 : 0.75))
                Text(photo.title).font(.rpBody.weight(.semibold)).foregroundStyle(Theme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                eligibility(photo.eligibility)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!state.phase.allowsPhotoChanges || actions.choosePhoto == nil)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityHint("Chooses only the photo for the opening clip.")
        .accessibilityIdentifier("aerialOpening.photo." + photo.id)
    }

    @ViewBuilder private func eligibility(_ value: AerialOpeningPhotoChoice.Eligibility) -> some View {
        switch value {
        case .unchecked:
            Text("Check before creating").font(.rpCaption).foregroundStyle(Theme.inkDim)
                .fixedSize(horizontal: false, vertical: true)
        case .checking:
            Label("Checking exterior", systemImage: "clock").font(.rpCaption).foregroundStyle(Theme.inkDim)
        case .eligible:
            Label("Original photo ready", systemImage: "checkmark.shield")
                .font(.rpCaption).foregroundStyle(Theme.inkDim)
        case .ineligible(let reason):
            Label(reason, systemImage: "exclamationmark.circle")
                .font(.rpCaption).foregroundStyle(Theme.inkDim)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var framing: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Opening shape").font(.rpHeadline).foregroundStyle(Theme.ink)
                .accessibilityAddTraits(.isHeader)
            if dynamicTypeSize.isAccessibilitySize {
                VStack(spacing: 10) { shapeChoices }
            } else {
                HStack(spacing: 10) { shapeChoices }
            }
            if let photo = state.selectedPhoto, let crop = state.reviewedCrop, state.hasReviewedCrop {
                AerialOpeningFramingPreview(photo: photo, crop: crop, enabled: state.phase.allowsPhotoChanges && actions.changeCrop != nil) { changed in
                    AerialOpeningInteraction.changeCrop(changed, state: state, actions: actions)
                }
                Text("Drag the frame to show the front of the home. This is the crop used for the opening.")
                    .font(.rpCaption).foregroundStyle(Theme.inkDim)
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    if let centered = AerialOpeningReviewedCrop.centered(sourceWidth: photo.sourceWidth, sourceHeight: photo.sourceHeight, aspect: state.aspect) {
                        AerialOpeningInteraction.changeCrop(centered, state: state, actions: actions)
                    }
                } label: {
                    Label("Center frame", systemImage: "viewfinder").font(.rpBody.weight(.semibold)).frame(maxWidth: .infinity)
                }
                .buttonStyle(RendpropPillButtonStyle())
                .disabled(!state.phase.allowsPhotoChanges || actions.changeCrop == nil)
                .accessibilityIdentifier("aerialOpening.centerCrop")
            } else {
                Label("This framing needs a full-size original photo. Choose another exterior photo if its size cannot be checked.", systemImage: "photo")
                    .font(.rpCaption).foregroundStyle(Theme.inkDim)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(18).modifier(RendpropContentSurface())
    }

    @ViewBuilder private var shapeChoices: some View {
        ForEach(["16:9", "9:16"], id: \.self) { aspect in
            Button { AerialOpeningInteraction.chooseAspect(aspect, state: state, actions: actions) } label: {
                Label(aspect == "16:9" ? "Wide" : "Tall", systemImage: aspect == "16:9" ? "rectangle" : "iphone")
                    .font(.rpBody.weight(.semibold)).frame(maxWidth: .infinity)
            }
            .buttonStyle(RendpropPillButtonStyle(selected: state.aspect == aspect))
            .disabled(!state.phase.allowsPhotoChanges || actions.chooseAspect == nil)
            .accessibilityAddTraits(state.aspect == aspect ? .isSelected : [])
            .accessibilityIdentifier("aerialOpening.aspect." + (aspect == "16:9" ? "wide" : "tall"))
        }
    }

    private func openingCard(_ opening: AerialOpeningPreview) -> some View {
        let headerLayout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 8))
        return VStack(alignment: .leading, spacing: 14) {
            headerLayout {
                Label("Opening clip", systemImage: "airplane.departure")
                    .font(.rpHeadline).foregroundStyle(Theme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                if !dynamicTypeSize.isAccessibilitySize { Spacer(minLength: 8) }
                Text(opening.durationLabel).font(.rpCaption).foregroundStyle(Theme.inkDim)
            }
            if let url = opening.localVideoURL {
                AerialOpeningPlayer(url: url, aspectRatio: opening.aspectRatio)
            } else {
                AerialOpeningPhotoThumbnail(url: opening.sourcePhoto.url)
                    .aspectRatio(opening.aspectRatio, contentMode: .fit)
                    .overlay(alignment: .bottomLeading) {
                        if !dynamicTypeSize.isAccessibilitySize {
                            Label("Source photo", systemImage: "photo")
                                .font(.rpCaption.weight(.semibold)).padding(8)
                                .background(.regularMaterial, in: Capsule()).padding(10)
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                Text("Open the saved clip to watch it.").font(.rpCaption).foregroundStyle(Theme.inkDim)
            }
            if state.phase == .ready {
                Toggle(isOn: Binding(get: { state.includeOpening }, set: { AerialOpeningInteraction.setIncluded($0, state: state, actions: actions) })) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Use as the opening").font(.rpBody.weight(.semibold))
                            .fixedSize(horizontal: false, vertical: true)
                        Text("Optional · plays first").font(.rpCaption).foregroundStyle(Theme.inkDim)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .tint(Theme.accent).disabled(actions.setIncluded == nil)
                .accessibilityIdentifier("aerialOpening.included")
            }
            Label(opening.disclosure, systemImage: "info.circle")
                .font(.rpCaption).foregroundStyle(Theme.inkDim)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(18).modifier(RendpropContentSurface())
    }

    private var sequence: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Video order").font(.rpHeadline).foregroundStyle(Theme.ink)
                .accessibilityAddTraits(.isHeader)
            if state.includeOpening, let opening = state.opening {
                sequenceRow(photo: opening.sourcePhoto, title: "First · Opening clip", subtitle: opening.durationLabel, symbol: "airplane.departure")
                    .accessibilityIdentifier("aerialOpening.first")
            }
            if state.orderedVideoPhotos.isEmpty {
                Label("Your selected video photos", systemImage: "photo.stack")
                    .font(.rpBody).foregroundStyle(Theme.inkDim)
            } else {
                ForEach(Array(state.orderedVideoPhotos.enumerated()), id: \.element.id) { index, photo in
                    sequenceRow(photo: photo, title: "Photo \(index + 1)", subtitle: photo.title, symbol: "photo")
                }
            }
            Text(state.includeOpening ? "The aerial plays first. Your photos keep their order and timing." : "The opening is off. Your video starts with your selected photos.")
                .font(.rpCaption).foregroundStyle(Theme.inkDim)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(18).modifier(RendpropContentSurface())
    }

    private func sequenceRow(photo: AerialOpeningPhotoChoice, title: String, subtitle: String, symbol: String) -> some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
            : AnyLayout(HStackLayout(alignment: .center, spacing: 12))
        return layout {
            AerialOpeningPhotoThumbnail(url: photo.url).frame(width: 68, height: 68)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                Label(title, systemImage: symbol).font(.rpBody.weight(.semibold)).foregroundStyle(Theme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                Text(subtitle).font(.rpCaption).foregroundStyle(Theme.inkDim)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

struct AerialOpeningFooter: View {
    @Environment(\.dismiss) private var dismiss
    let state: AerialOpeningPresentation
    let actions: AerialOpeningActions

    var body: some View {
        VStack(spacing: 8) {
            switch state.phase {
            case .choosing, .stopped:
                action("Prepare this photo", symbol: "checkmark.shield", enabled: state.canCheckPhoto && actions.checkPhoto != nil, id: "check", perform: { AerialOpeningInteraction.checkPhoto(state: state, actions: actions) })
            case .checkingPhoto, .generating:
                action("Stop", symbol: "stop.circle", enabled: actions.stop != nil, id: "stop", perform: { AerialOpeningInteraction.stop(state: state, actions: actions) })
            case .stopping:
                action("Confirming stop…", symbol: "clock", enabled: false, id: "stopping", perform: nil)
            case .costReview:
                action("Make opening", symbol: "sparkles", enabled: state.canMakeOpening && actions.makeOpening != nil, id: "make", perform: { AerialOpeningInteraction.makeOpening(state: state, actions: actions) })
            case .review:
                action("Use this opening", symbol: "checkmark", enabled: actions.review != nil, id: "review", perform: actions.review)
                if let stop = actions.stop { Button("Don't use this opening", action: stop).buttonStyle(RendpropPillButtonStyle()) }
            case .ready:
                action("Done", symbol: "checkmark", enabled: true, id: "done", perform: actions.close ?? { dismiss() })
                if let chooseAnother = actions.chooseAnother { Button("Choose another exterior", action: chooseAnother).buttonStyle(RendpropPillButtonStyle()) }
            case .needsAttention:
                action("Check saved request", symbol: "arrow.clockwise", enabled: actions.checkStatus != nil, id: "checkStatus", perform: actions.checkStatus)
                if state.canStopSavedRequest, let stop = actions.stop {
                    Button("Stop saved request", action: stop).buttonStyle(RendpropPillButtonStyle())
                        .accessibilityIdentifier("aerialOpening.stopSaved")
                }
            }
        }
    }

    private func action(_ title: String, symbol: String, enabled: Bool, id: String, perform: (() -> Void)?) -> some View {
        Button { perform?() } label: {
            Label(title, systemImage: symbol).font(.rpBody.weight(.semibold))
                .frame(maxWidth: .infinity)
                .fixedSize(horizontal: false, vertical: true)
        }
        .buttonStyle(RendpropPillButtonStyle(prominent: true))
        .disabled(!enabled)
        .accessibilityIdentifier("aerialOpening." + id)
    }
}

private struct AerialOpeningPhotoThumbnail: View {
    let url: URL
    @State private var image: UIImage?
    var body: some View {
        GeometryReader { bounds in
            Group {
                if let image {
                    Image(uiImage: image).resizable().scaledToFit()
                } else {
                    Image(systemName: "photo").font(.title2).foregroundStyle(Theme.inkDim)
                }
            }
            .frame(width: bounds.size.width, height: bounds.size.height)
            .background(Theme.fillSubtle)
        }
        .accessibilityHidden(true)
        .task(id: url) {
            let requested = url
            image = ImageThumbnails.cached(requested, maxPixel: 800)
            let loaded = await ImageThumbnails.load(requested, maxPixel: 800)
            guard !Task.isCancelled, requested == url else { return }
            image = loaded
        }
    }
}

private struct AerialOpeningPlayer: View {
    let url: URL
    let aspectRatio: Double
    @State private var player: AVPlayer?
    var body: some View {
        Group {
            if let player { VideoPlayer(player: player) }
            else { ProgressView("Opening saved clip…") }
        }
        .aspectRatio(aspectRatio, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .task(id: url) { player?.pause(); player = AVPlayer(url: url) }
        .onDisappear { player?.pause() }
        .accessibilityLabel("Saved aerial opening video")
    }
}

private struct AerialOpeningFramingPreview: View {
    let photo: AerialOpeningPhotoChoice
    let crop: AerialOpeningReviewedCrop
    let enabled: Bool
    let changed: (AerialOpeningReviewedCrop) -> Void
    @State private var dragStart: AerialOpeningReviewedCrop?

    var body: some View {
        GeometryReader { bounds in
            let frame = CGRect(x: Double(crop.x) / Double(crop.sourceWidth) * bounds.size.width,
                               y: Double(crop.y) / Double(crop.sourceHeight) * bounds.size.height,
                               width: Double(crop.width) / Double(crop.sourceWidth) * bounds.size.width,
                               height: Double(crop.height) / Double(crop.sourceHeight) * bounds.size.height)
            AerialOpeningPhotoThumbnail(url: photo.url)
                .overlay {
                    Path { path in path.addRect(CGRect(origin: .zero, size: bounds.size)); path.addRect(frame) }
                        .fill(.black.opacity(0.38), style: FillStyle(eoFill: true))
                        .allowsHitTesting(false)
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 4).strokeBorder(Theme.accent, lineWidth: 3)
                        .frame(width: frame.width, height: frame.height)
                        .background(Color.clear.contentShape(Rectangle()))
                        .position(x: frame.midX, y: frame.midY)
                        .gesture(DragGesture().onChanged { value in
                            guard enabled, bounds.size.width > 0, bounds.size.height > 0 else { return }
                            let start = dragStart ?? crop
                            if dragStart == nil { dragStart = crop }
                            changed(start.translated(x: Int((value.translation.width / bounds.size.width * Double(crop.sourceWidth)).rounded()),
                                                     y: Int((value.translation.height / bounds.size.height * Double(crop.sourceHeight)).rounded())))
                        }.onEnded { _ in dragStart = nil })
                }
        }
        .aspectRatio(Double(crop.sourceWidth) / Double(crop.sourceHeight), contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Opening framing")
        .accessibilityValue("\(crop.width > crop.height ? "Wide" : "Tall"), \(crop.width) by \(crop.height) source pixels")
        .accessibilityHint("Adjusts the frame within the original photo.")
        .accessibilityAdjustableAction { direction in
            guard enabled else { return }
            let horizontal = crop.sourceWidth > crop.width
            let step = max(1, (horizontal ? crop.sourceWidth - crop.width : crop.sourceHeight - crop.height) / 10)
            let delta: Int
            switch direction { case .increment: delta = step; case .decrement: delta = -step; @unknown default: return }
            changed(crop.translated(x: horizontal ? delta : 0, y: horizontal ? 0 : delta))
        }
        .accessibilityIdentifier("aerialOpening.framing")
    }
}

/// Owns only the new durable opening flow. Legacy aerial recovery remains in
/// AerialIntroSheet; its receipts are neither migrated nor silently resubmitted.
@MainActor final class AerialOpeningController: ObservableObject {
    @Published var state = AerialOpeningPresentation()
    @Published private(set) var catalogueEntries: [AerialOpeningCatalogue.Entry] = []
    var catalogueContext: PropertyVideoJobContext? { context }
    private let listing: Listing
    private weak var model: AppModel?
    private var context: PropertyVideoJobContext?
    private var physicalOrgID: UUID?
    private var sessionRevision: UInt64?
    private var consentRevision: UInt64?
    private var originals: [AerialOpeningService.Original] = []
    private var saved: AerialOpeningJournal?
    private var polling: Task<Void, Never>?
    private var task: Task<Void, Never>?
    private var accepted: PropertyVideoAcceptedOpening?
    private var preparationID: UUID?
    init(listing: Listing) { self.listing = listing }

    func load(model: AppModel, expectedOperationID: UUID? = nil) async {
        guard context == nil else { return }
        self.model = model
        do {
            guard !listing.isSample, let actor = AuthStore.shared.userID.flatMap(UUID.init(uuidString:)),
                  let org = WorkspaceContext.selectedOrgID, let current = model.listings.first(where: { $0.id == listing.id }),
                  let server = current.serverID, let physical = current.serverOrgID, current.cloudUnavailable != true else {
                throw PropertyVideoJobStore.Failure.identityChanged
            }
            context = PropertyVideoJobContext(localListingID: listing.id, listingID: server, actorID: actor, orgID: org)
            physicalOrgID = physical; sessionRevision = AuthStore.shared.syncSessionRevision; consentRevision = AIConsent.shared.revocationRevision
            try requireCurrent()
            if let expectedOperationID {
                guard let pending = try AerialOpeningStore.load(context!), pending.manifest.operationID == expectedOperationID else {
                    throw PropertyVideoJobStore.Failure.invalidReceipt
                }
            }
            let localListingID = listing.id
            originals = try await Task.detached(priority: .utility) { try AerialOpeningService.originals(listingID: localListingID) }.value
            try requireCurrent()
            state.photos = originals.enumerated().map { number, original in
                .init(id: original.photoID, title: "Photo \(number + 1)", url: original.url, sourceWidth: original.width, sourceHeight: original.height)
            }
            state.dispatchAvailable = true
            if let context, let pending = try AerialOpeningStore.load(context) {
                guard pending.physicalOrgID == physical, expectedOperationID == nil || pending.manifest.operationID == expectedOperationID else { throw PropertyVideoJobStore.Failure.invalidReceipt }
                saved = pending; state.generationProgress = pending.dispatched ? pending.generationProgress() : nil
                state.selectedPhotoID = pending.sourcePhotoID; state.aspect = pending.manifest.aspect
                state.reviewedCrop = pending.manifest.reviewedCrop; state.cropPhotoID = pending.sourcePhotoID
                if pending.dispatched {
                    if pending.status?.state == "accepted", AerialOpeningStore.selection(context, aspect: state.aspect) != nil {
                        state.selectedPhotoID = nil
                        await loadAccepted()
                    } else { await refresh() }
                    return
                }
            }
            await loadAccepted()
        } catch { fail(error) }
    }
    private func requireCurrent() throws {
        try Task.checkCancellation()
        guard let context, context.hasCurrentIdentity, AuthStore.shared.syncSessionRevision == sessionRevision, AIConsent.shared.revocationRevision == consentRevision,
              let current = model?.listings.first(where: { $0.id == context.localListingID }), current.cloudUnavailable != true,
              current.serverID == context.listingID, current.serverOrgID == physicalOrgID else { throw PropertyVideoJobStore.Failure.identityChanged }
    }
    func choose(_ id: String) {
        guard state.phase.allowsPhotoChanges, state.photos.contains(where: { $0.id == id }) else { return }
        state.selectedPhotoID = id; resetQuote()
        if let photo = state.selectedPhoto { state.reviewedCrop = .centered(sourceWidth: photo.sourceWidth, sourceHeight: photo.sourceHeight, aspect: state.aspect); state.cropPhotoID = id }
    }
    func aspect(_ value: String) {
        guard state.phase.allowsPhotoChanges, ["16:9", "9:16"].contains(value) else { return }
        state.aspect = value; resetQuote(); state.hasSavedOpenings = false; catalogueEntries = []
        Task { await loadAccepted() }
        if let photo = state.selectedPhoto { state.reviewedCrop = .centered(sourceWidth: photo.sourceWidth, sourceHeight: photo.sourceHeight, aspect: value); state.cropPhotoID = photo.id }
    }
    func crop(_ crop: AerialOpeningReviewedCrop) {
        guard state.phase.allowsPhotoChanges, let photo = state.selectedPhoto, crop.sourceWidth == photo.sourceWidth,
              crop.sourceHeight == photo.sourceHeight, crop.isValid(aspect: state.aspect) else { return }
        state.reviewedCrop = crop; resetQuote()
    }
    private func resetQuote() {
        state.generationProgress = nil
        state.phase = .choosing; state.processorAllowed = false; state.quotedCost = nil; state.quotedDisclosure = nil
        state.quotedPhotoID = nil; state.quotedCrop = nil; state.quotedAspect = nil
    }
    func prepare() {
        guard state.canCheckPhoto, let original = originals.first(where: { $0.photoID == state.selectedPhotoID }),
              let crop = state.reviewedCrop, let context, let physical = physicalOrgID, let api = model?.api else { return }
        let operation = UUID(); preparationID = operation
        state.phase = .checkingPhoto
        task = Task { @MainActor in
            do {
                try requireCurrent()
                // A new operation is still unsubmitted. Raw original registration
                // and a quote never dispatch video generation.
                let aspect = state.aspect
                let source = try await AerialOpeningService.register(original, operationID: operation, context: context, physicalOrgID: physical, api: api, requireCurrent: requireCurrent)
                try requireCurrent()
                guard preparationID == operation, state.selectedPhotoID == original.photoID, state.reviewedCrop == crop, state.aspect == aspect else { throw PropertyVideoJobStore.Failure.identityChanged }
                let manifest = AerialOpeningManifest(operationID: operation, listingID: context.listingID, expectedOrgID: context.orgID, source: source, aspect: aspect, reviewedCrop: crop)
                let reply = try await AerialOpeningService.quote(manifest, context: context)
                try requireCurrent()
                guard preparationID == operation else { return }
                let journal = AerialOpeningJournal(context: context, physicalOrgID: physical, manifest: manifest, quote: reply.quote, disclosure: reply.disclosure, sourcePhotoID: original.photoID)
                try AerialOpeningStore.save(journal); saved = journal
                if let index = state.photos.firstIndex(where: { $0.id == original.photoID }) { state.photos[index].eligibility = .eligible }
                state.quotedPhotoID = original.photoID; state.quotedCrop = crop; state.quotedAspect = aspect
                state.quotedDisclosure = reply.disclosure
                state.quotedCost = String(format: "Up to $%.2f processing estimate", ceil(reply.quote.maximumTotalCents) / 100)
                preparationID = nil; state.processorAllowed = false; state.phase = .costReview
            } catch is CancellationError {
                if preparationID == operation { preparationID = nil; state.phase = .stopped }
            } catch {
                if preparationID == operation { preparationID = nil; fail(error) }
            }
        }
    }
    func make() {
        guard state.canMakeOpening, var journal = saved, !journal.dispatched else { return }
        guard journal.quote.isValid(for: journal.manifest) else {
            resetQuote(); state.availabilityMessage = "This setup check expired. Prepare the photo again before creating your opening."
            return
        }
        do {
            try requireCurrent(); journal.dispatched = true; journal.dispatchedAt = Date()
            try AerialOpeningStore.save(journal); saved = journal; state.generationProgress = journal.generationProgress(); state.phase = .generating
        } catch { fail(error); return }
        let submitted = journal, permission = state.processorAllowed
        task = Task { @MainActor in
            do {
                try requireCurrent()
                let result = try await AerialOpeningService.submit(submitted, permission: permission)
                try requireCurrent(); try await receive(result)
                startPolling()
            } catch { if saved?.manifest == submitted.manifest { fail(error) } }
        }
    }
    func refresh() async {
        guard let journal = saved, journal.dispatched else { return }
        do {
            try requireCurrent()
            let result = try await AerialOpeningService.refresh(journal)
            try requireCurrent()
            guard saved?.manifest == journal.manifest else { return }
            guard let result else { try receiveUnadmittedStop(for: journal.manifest); return }
            try await receive(result)
            if saved?.stopRequested == true, result.state != "accepted", !result.isTerminal {
                guard let current = saved else { return }
                let stopped = try await AerialOpeningService.cancel(current)
                try requireCurrent()
                if let stopped { try await receive(stopped) } else { try receiveUnadmittedStop(for: current.manifest) }
            }
            startPolling()
        } catch { if saved?.manifest == journal.manifest { fail(error) } }
    }
    func stop() {
        if state.phase == .checkingPhoto || saved?.dispatched != true {
            preparationID = nil; task?.cancel(); state.phase = .stopped; return
        }
        polling?.cancel()
        guard var journal = saved else { return }
        do {
            try requireCurrent(); journal.stopRequested = true
            try AerialOpeningStore.save(journal); saved = journal; state.generationProgress = journal.generationProgress(); state.phase = .stopping
        } catch { fail(error); return }
        let stopping = journal
        task = Task { @MainActor in
            do {
                try requireCurrent()
                let status = try await AerialOpeningService.cancel(stopping)
                try requireCurrent()
                guard saved?.manifest == stopping.manifest else { return }
                guard let status else { try receiveUnadmittedStop(for: stopping.manifest); return }
                try await receive(status)
                if !status.isTerminal { startPolling() }
            } catch { if saved?.manifest == stopping.manifest { fail(error) } }
        }
    }
    private func startPolling() {
        guard let journal = saved, journal.dispatched, journal.status?.isTerminal != true,
              journal.status?.state != "ready_for_acceptance", journal.status?.state != "ambiguous" else { return }
        polling?.cancel()
        polling = Task { @MainActor in
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 6_000_000_000) } catch { return }
                guard let saved, saved.status?.isTerminal != true, saved.status?.state != "ready_for_acceptance" else { return }
                do {
                    try requireCurrent()
                    let status = try await AerialOpeningService.refresh(saved)
                    try requireCurrent()
                    guard self.saved?.manifest == saved.manifest else { return }
                    guard let status else { try receiveUnadmittedStop(for: saved.manifest); return }
                    try await receive(status)
                    if status.state == "ambiguous" { return }
                } catch { if self.saved?.manifest == saved.manifest { fail(error) }; return }
            }
        }
    }
    private func receiveUnadmittedStop(for manifest: AerialOpeningManifest) throws {
        guard var journal = saved, journal.manifest == manifest else { return }
        journal.stopRequested = true; journal.notAdmittedCancelled = true
        try AerialOpeningStore.save(journal); saved = journal; state.generationProgress = journal.generationProgress(); state.phase = .stopped; state.canStopSavedRequest = false
        state.availabilityMessage = "The server confirmed this request was cancelled before admission. No video was generated."
    }
    private func receive(_ result: AerialOpeningStatus) async throws {
        try requireCurrent(); guard var journal = saved else { throw PropertyVideoJobStore.Failure.invalidReceipt }
        guard result.operationID == journal.manifest.operationID, result.manifest == journal.manifest, result.quote == journal.quote else { return }
        if let previous = journal.status, previous.isTerminal, previous.state != result.state {
            throw PropertyVideoJobStore.Failure.invalidReceipt
        }
        state.canStopSavedRequest = !result.isTerminal
        var durable = result; durable.previewURL = nil
        journal.recordConfirmedStatus(durable, at: Date()); try AerialOpeningStore.save(journal); saved = journal; state.generationProgress = journal.generationProgress()
        if result.state == "accepted", let opening = result.opening {
            if await restoreExplicitChoice(insteadOf: opening) { return }
            let preview = try await previewValue(result)
            guard saved?.manifest == result.manifest else { return }
            if await restoreExplicitChoice(insteadOf: opening) { return }
            let included = try AerialOpeningStore.retainAcceptance(opening, context: journal.context)
            accepted = opening; state.opening = preview; state.includeOpening = included; state.phase = .ready
        } else if result.state == "ready_for_acceptance", !journal.stopRequested {
            if state.phase == .ready, accepted != nil { return }
            let choice = AerialOpeningStore.selection(journal.context, aspect: result.manifest.aspect), phase = state.phase
            let preview = try await previewValue(result)
            guard saved?.manifest == result.manifest, state.phase == phase,
                  AerialOpeningStore.selection(journal.context, aspect: result.manifest.aspect) == choice else { return }
            state.opening = preview; state.phase = .review
        } else if ["failed", "ineligible"].contains(result.state) {
            state.availabilityMessage = result.message ?? "This photo could not produce an opening. Your original is kept."
            state.phase = .stopped
        } else if result.state == "cancelled" { state.phase = .stopped }
        else if result.state == "ambiguous" { state.phase = .needsAttention("The provider request is unresolved. Check this saved request; do not start another.") }
        else { state.phase = journal.stopRequested ? .stopping : .generating }
    }
    private func restoreExplicitChoice(insteadOf opening: PropertyVideoAcceptedOpening) async -> Bool {
        guard let context, let choice = AerialOpeningStore.selection(context, aspect: opening.aspect), choice.reference != opening.reference else { return false }
        if state.phase == .ready, accepted?.reference == choice.reference {
            state.includeOpening = choice.included
        } else if preparationID == nil {
            state.selectedPhotoID = nil; state.phase = .choosing
            await loadAccepted()
        }
        return true
    }
    private func previewValue(_ status: AerialOpeningStatus) async throws -> AerialOpeningPreview {
        guard let context else { throw PropertyVideoJobStore.Failure.invalidReceipt }
        let url = try await AerialOpeningService.preview(status, context: context, requireCurrent: requireCurrent)
        try requireCurrent()
        let original = originals.first(where: { $0.sha256 == status.manifest.source.sha256 && $0.bytes == status.manifest.source.bytes })
        let photo = state.photos.first(where: { $0.id == original?.photoID }) ?? .init(id: status.manifest.source.photoAssetID.uuidString, title: "Saved front exterior", url: url)
        return .init(id: status.aerialJobID.uuidString, sourcePhoto: photo, localVideoURL: url,
            aspectRatio: status.manifest.aspect == "16:9" ? 16.0 / 9.0 : 9.0 / 16.0, durationLabel: String(format: "%.2f seconds", Double(status.candidate?.visibleFrames ?? 0) / 24), disclosure: status.opening?.disclosure ?? saved?.disclosure ?? "AI-generated opening")
    }
    func accept() {
        guard state.phase == .review, let journal = saved else { return }
        let choiceBefore = AerialOpeningStore.selection(journal.context, aspect: journal.manifest.aspect)
        task = Task { @MainActor in
            do {
                try requireCurrent()
                let opening = try await AerialOpeningService.accept(journal)
                try requireCurrent()
                guard saved?.manifest == journal.manifest else { return }
                guard AerialOpeningStore.selection(journal.context, aspect: journal.manifest.aspect) == choiceBefore else { await refresh(); return }
                accepted = opening
                try AerialOpeningStore.select(opening, included: true, context: journal.context)
                state.includeOpening = true; state.phase = .ready
                await refresh()
            } catch { if saved?.manifest == journal.manifest { fail(error) } }
        }
    }
    func setIncluded(_ value: Bool) {
        do { try requireCurrent(); guard let accepted, let context else { return }; try AerialOpeningStore.select(accepted, included: value, context: context); state.includeOpening = value }
        catch { fail(error) }
    }
    private func loadAccepted() async {
        guard let context, let physicalOrgID else { return }
        let aspect = state.aspect
        let choice = AerialOpeningStore.selection(context, aspect: aspect)
        let canRestore = state.phase == .choosing && state.selectedPhotoID == nil
        do {
            let catalogue = try await AerialOpeningService.catalogue(context: context, physicalOrgID: physicalOrgID, aspect: aspect)
            try requireCurrent()
            guard state.aspect == aspect else { return }
            catalogueEntries = catalogue.accepted; state.hasSavedOpenings = !catalogue.accepted.isEmpty
            guard canRestore, state.phase == .choosing, state.selectedPhotoID == nil, let choice, let entry = catalogue.accepted.first(where: { $0.opening.reference == choice.reference }) else { return }
            let preview = try await AerialOpeningService.preview(reference: entry.opening.reference, url: entry.previewURL, context: context, requireCurrent: requireCurrent)
            try requireCurrent()
            guard state.aspect == aspect, state.phase == .choosing, state.selectedPhotoID == nil,
                  AerialOpeningStore.selection(context, aspect: aspect) == choice else { return }
            accepted = entry.opening
            let original = originals.first(where: { $0.sha256 == entry.opening.reference.source.sha256 && $0.bytes == entry.opening.reference.source.bytes })
            let photo = state.photos.first(where: { $0.id == original?.photoID }) ?? .init(id: entry.opening.reference.source.photoAssetID.uuidString, title: "Saved front exterior", url: preview)
            state.selectedPhotoID = original?.photoID
            state.opening = .init(id: entry.opening.reference.aerialJobID.uuidString, sourcePhoto: photo, localVideoURL: preview,
                aspectRatio: entry.opening.aspect == "16:9" ? 16.0 / 9.0 : 9.0 / 16.0,
                durationLabel: String(format: "%.2f seconds", entry.opening.durationS), disclosure: entry.opening.disclosure)
            state.includeOpening = choice.included
            state.phase = .ready
            state.availabilityMessage = "This accepted opening is saved with the home. Make a Listing video with it, then select that video for the website. A recorded walkthrough is unchanged."
        } catch { fail(error) }
    }
    func chooseAccepted(_ entry: AerialOpeningCatalogue.Entry, preview: URL) {
        do {
            try requireCurrent(); guard let context, let physicalOrgID, catalogueEntries.contains(where: { $0.opening == entry.opening }) else { return }
            _ = try entry.opening.checked(actorID: context.actorID, physicalOrgID: physicalOrgID, selectedLibraryOrgID: context.orgID, listingID: context.listingID, aspect: state.aspect)
            try AerialOpeningStore.select(entry.opening, included: true, context: context); accepted = entry.opening; state.generationProgress = nil
            let original = originals.first(where: { $0.sha256 == entry.opening.reference.source.sha256 && $0.bytes == entry.opening.reference.source.bytes })
            let source = state.photos.first(where: { $0.id == original?.photoID }) ?? .init(id: entry.opening.reference.source.photoAssetID.uuidString, title: "Saved front exterior", url: preview)
            state.opening = .init(id: entry.opening.reference.aerialJobID.uuidString, sourcePhoto: source, localVideoURL: preview,
                aspectRatio: state.aspect == "16:9" ? 16.0 / 9.0 : 9.0 / 16.0, durationLabel: String(format: "%.2f seconds", entry.opening.durationS), disclosure: entry.opening.disclosure)
            state.includeOpening = true; state.phase = .ready
        } catch { fail(error) }
    }
    func verifyCatalogueContext() throws { try requireCurrent() }
    private func fail(_ error: Error) {
        polling?.cancel()
        state.availabilityMessage = error.localizedDescription
        state.generationProgress = saved?.dispatched == true ? saved?.generationProgress(checkFailed: true) : nil
        state.canStopSavedRequest = saved?.dispatched == true && saved?.status?.isTerminal != true && saved?.notAdmittedCancelled != true
        state.phase = saved?.dispatched == true && saved?.status?.isTerminal != true && saved?.notAdmittedCancelled != true
            ? .needsAttention(error.localizedDescription) : .stopped
        if (try? requireCurrent()) == nil {
            state.dispatchAvailable = false; state.photos = []; state.opening = nil; state.quotedDisclosure = nil; state.hasSavedOpenings = false; catalogueEntries = []; state.canStopSavedRequest = false
            state.generationProgress = nil
            state.phase = .needsAttention("Your account or workspace changed. Reopen this home's aerial intro to continue.")
        }
    }
    func chooseAnother() {
        guard state.phase == .ready else { return }
        state.opening = nil; state.generationProgress = nil; state.phase = .choosing; state.availabilityMessage = nil
    }
    func identityChanged() { if (try? requireCurrent()) == nil { fail(PropertyVideoJobStore.Failure.identityChanged) } }
    func reloadPhotos() async {
        do {
            try requireCurrent()
            let id = listing.id
            originals = try await Task.detached(priority: .utility) { try AerialOpeningService.originals(listingID: id) }.value
            try requireCurrent()
            state.photos = originals.enumerated().map { number, original in
                .init(id: original.photoID, title: "Photo \(number + 1)", url: original.url, sourceWidth: original.width, sourceHeight: original.height)
            }
        } catch { fail(error) }
    }
    func disappear() { polling?.cancel() }
}

struct AerialOpeningScreen: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var auth = AuthStore.shared
    let listing: Listing
    let isPresentedModally: Bool
    let expectedOperationID: UUID?
    @StateObject private var controller: AerialOpeningController
    @State private var showPhotos = false
    @State private var showSaved = false
    init(listing: Listing, isPresentedModally: Bool = false, expectedOperationID: UUID? = nil) {
        self.listing = listing
        self.isPresentedModally = isPresentedModally
        self.expectedOperationID = expectedOperationID
        _controller = StateObject(wrappedValue: AerialOpeningController(listing: listing))
    }
    var body: some View {
        AerialOpeningView(listingTitle: listing.address, state: controller.state, actions: .init(
            choosePhoto: controller.choose, chooseAspect: controller.aspect, changeCrop: controller.crop, addPhoto: { showPhotos = true },
            checkPhoto: controller.prepare, makeOpening: controller.make,
            setProcessorAllowed: { controller.state.processorAllowed = $0 }, stop: controller.stop,
            checkStatus: { Task { await controller.refresh() } }, review: controller.accept,
            setIncluded: controller.setIncluded, chooseAnother: controller.chooseAnother, openSaved: { showSaved = true }, close: { dismiss() }), isPresentedModally: isPresentedModally)
            .sheet(isPresented: $showSaved) {
                if let context = controller.catalogueContext {
                    AerialOpeningAcceptedPicker(entries: controller.catalogueEntries, context: context, requireCurrent: controller.verifyCatalogueContext) { entry, url in controller.chooseAccepted(entry, preview: url) }
                }
            }
            .sheet(isPresented: $showPhotos, onDismiss: { Task { await controller.reloadPhotos() } }) {
                NavigationStack {
                    PhotoStudioView(listing: listing, entry: .photos)
                        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { showPhotos = false } } }
                }.environmentObject(model)
            }
            .task { await controller.load(model: model, expectedOperationID: expectedOperationID) }
            .onChange(of: auth.syncSessionRevision) { _ in controller.identityChanged() }
            .onReceive(NotificationCenter.default.publisher(for: .rendpropWorkspaceChanged)) { _ in controller.identityChanged() }
            .onDisappear { controller.disappear() }
    }
}

/// Choosing an accepted clip is an ordinary per-video action. Catalogue order
/// never silently replaces a saved older choice or an off preference.
struct AerialOpeningAcceptedPicker: View {
    @Environment(\.dismiss) private var dismiss
    let entries: [AerialOpeningCatalogue.Entry]
    let context: PropertyVideoJobContext
    let requireCurrent: @MainActor () throws -> Void
    let onSelect: (AerialOpeningCatalogue.Entry, URL) -> Void
    @State private var chosen: AerialOpeningCatalogue.Entry?
    @State private var previewURL: URL?
    @State private var preparing = false
    @State private var error: String?
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("Choose the opening").font(.rpTitle).foregroundStyle(Theme.ink)
                    Text("One accepted front-of-home clip plays first. Your photos keep their order and timing.")
                        .font(.rpBody).foregroundStyle(Theme.inkDim).fixedSize(horizontal: false, vertical: true)
                    ForEach(entries, id: \.opening.reference.aerialJobID) { entry in
                        Button { load(entry) } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                Label(String(format: "Opening · %.2f seconds", entry.opening.durationS), systemImage: chosen?.opening == entry.opening ? "checkmark.circle.fill" : "play.rectangle")
                                    .font(.rpBody.weight(.semibold))
                                Text(entry.opening.acceptedAt.prefix(10)).font(.rpCaption)
                            }.fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
                        }.buttonStyle(RendpropPillButtonStyle(selected: chosen?.opening == entry.opening))
                            .disabled(preparing).accessibilityIdentifier("aerialOpening.saved." + entry.opening.reference.aerialJobID.uuidString)
                    }
                    if preparing { ProgressView("Opening preview…").font(.rpBody) }
                    if let chosen, let previewURL {
                        AerialOpeningPlayer(url: previewURL, aspectRatio: chosen.opening.aspect == "16:9" ? 16.0 / 9.0 : 9.0 / 16.0)
                        Text(chosen.opening.disclosure).font(.rpCaption).foregroundStyle(Theme.inkDim).fixedSize(horizontal: false, vertical: true)
                    }
                    if let error { Text(error).font(.rpCaption).foregroundStyle(Theme.warn).fixedSize(horizontal: false, vertical: true) }
                }.padding(20)
            }.background(Theme.bg)
                .navigationTitle("Saved openings").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
                .safeAreaInset(edge: .bottom) {
                    Button {
                        do {
                            try requireCurrent()
                            guard let chosen, let previewURL else { return }
                            onSelect(chosen, previewURL); dismiss()
                        } catch { self.error = error.localizedDescription }
                    } label: { Label("Use as opening", systemImage: "checkmark").font(.rpBody.weight(.semibold)).frame(maxWidth: .infinity) }
                        .buttonStyle(RendpropPillButtonStyle(prominent: true))
                        .disabled(chosen == nil || previewURL == nil || preparing)
                        .padding(20).background(.bar)
                }
        }
    }
    private func load(_ entry: AerialOpeningCatalogue.Entry) {
        guard !preparing else { return }
        preparing = true; chosen = nil; previewURL = nil; error = nil
        Task { @MainActor in
            defer { preparing = false }
            do {
                try requireCurrent()
                let url = try await AerialOpeningService.preview(reference: entry.opening.reference, url: entry.previewURL, context: context, requireCurrent: requireCurrent)
                try requireCurrent(); chosen = entry; previewURL = url
            } catch { self.error = error.localizedDescription }
        }
    }
}
