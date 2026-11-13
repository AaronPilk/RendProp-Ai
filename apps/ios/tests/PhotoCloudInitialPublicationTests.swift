// __ACTUAL_SELECTION_FIXTURE__
enum Config { static let useLiveBackend = true }
enum CloudSyncError: Error { case identityChanged }
struct InitialScope { let checkIdentity: @MainActor () throws -> Void; @MainActor func check() throws { try checkIdentity() } }
struct InitialListing { let id:UUID;let serverID:UUID?;let serverOrgID:UUID?;var isSample=false;var cloudUnavailable:Bool?=false;var serverShareURL:URL?;var cloudImported:Bool?=false;var mainPhotoRelPath:String? }
struct InitialVersion: Equatable {let id:String;var familyID:String="A";var needsStagingReview=false;var needsCustomReview=false}
enum FileStore { static func url(fromRelativePath path:String)->URL {URL(fileURLWithPath:path)} }
enum EnhancedPhoto { static func directory(for id:UUID)->URL { URL(fileURLWithPath:"/closed/"+id.uuidString) } }
@MainActor enum PhotoVersionHistory {
    enum Failure:Error {case reviewRequired,coverNotSelected}
    static var chosen:[InitialVersion]=[]
    static var firstCoverSource:InitialVersion?=nil
    static var familyCount=1
    static func publicationVersions(directory:URL)throws->[InitialVersion]? {chosen}
    static func firstAutomaticCoverVersion(directory:URL,requireSingleFamily:Bool=false)throws->InitialVersion? {
        requireSingleFamily && familyCount != 1 ? nil : firstCoverSource
    }
}
@MainActor final class InitialPublicationModel {
    let fixture:SelectionFixture
    let photoCloudJournal:PhotoCloudSelectionJournal
    let coordinator:PhotoCloudSelectionCoordinator
    var listings:[InitialListing]
    var identityCurrent=true
    var cloudPhotoNotices:[UUID:String]=[:]
    init(_ fixture:SelectionFixture,store:PhotoCloudSelectionJournal) {
        self.fixture=fixture;photoCloudJournal=store;coordinator=PhotoCloudSelectionCoordinator(store:store)
        listings=[.init(id:fixture.identity.localListingID,serverID:fixture.identity.serverListingID,serverOrgID:fixture.physical)]
    }
    func cloudPhotoIdentity(_ id:UUID)throws->(PhotoCloudSelectionIdentity,InitialScope,UUID?) {
        (fixture.identity,InitialScope(checkIdentity:{if !self.identityCurrent{throw PhotoCloudSelectionFailure.identityChanged}}),fixture.physical)
    }
    func isInSelectedWorkspace(_ listing:InitialListing)->Bool { true }
    func cloudPhotoCatalog(identity:PhotoCloudSelectionIdentity,physicalOrgID:UUID?,requireIdentity:@MainActor ()throws->Void)async throws->[PhotoCloudLocalVersion]{try requireIdentity();return fixture.catalog}
    func refreshCloudPhotoSelection(listingID:UUID)async throws->PhotoCloudSelectionProjection {
        try await coordinator.refresh(identity:fixture.identity,physicalOrgID:fixture.physical,api:fixture,catalog:{self.fixture.catalog},requireIdentity:{if !self.identityCurrent{throw PhotoCloudSelectionFailure.identityChanged}})
    }
    func changeCloudPhotoSelection(listingID:UUID,versionID:String,selecting:Bool,followFamilyCover:Bool=false,reviewed:Bool,
                                   promoteCover:Bool=false,requireEmptyCover:Bool=false,requireCurrentSelection:Bool=false,requireBlankGallery:Bool=false)async throws->PhotoCloudSelectionProjection {
        try await coordinator.change(identity:fixture.identity,physicalOrgID:fixture.physical,versionID:versionID,selecting:selecting,
            followFamilyCover:followFamilyCover,reviewed:reviewed,promoteCover:promoteCover,requireEmptyCover:requireEmptyCover,
            requireCurrentSelection:requireCurrentSelection,requireBlankGallery:requireBlankGallery,api:fixture,catalog:{self.fixture.catalog},prepare:{_,_ in
                self.fixture.prepareCount += 1
                if requireBlankGallery {
                    if self.fixture.ids == nil { self.fixture.ids = [] } // upload reservation freezes legacy NULL
                    self.fixture.catalog[1] = self.fixture.local("a2","A",self.fixture.a2,2)
                }
                self.fixture.onPrepare?()
            },
            validateTarget:{ version, asset, storageKey in
                self.fixture.validateCount += 1
                guard version.id == versionID, version.knownAssetID == asset,
                      storageKey == nil || storageKey == self.fixture.key(asset) else { throw PhotoCloudSelectionFailure.changed }
            },requireIdentity:{if !self.identityCurrent{throw PhotoCloudSelectionFailure.identityChanged}})
    }
    // __ACTUAL_HIDE_ADMISSION__
    // __ACTUAL_FIRST_COVER_DEFAULT__
    // __ACTUAL_FIRST_COVER_SYNC__
    // __ACTUAL_INITIAL_QUEUE__
}
@main struct InitialPublicationChecks {
    @MainActor static func main() async throws {
        let directory=URL(fileURLWithPath:CommandLine.arguments[1]);var count=0,serial=0
        func check(_ value:Bool,_ text:String){guard value else{fputs("FAIL: "+text+"\n",stderr);exit(1)};count += 1}
        func refuses(_ text:String,_ work:()async throws->Void)async{do{try await work();check(false,text)}catch{check(true,text)}}
        let fixture=SelectionFixture();fixture.reset();let unrelated=UUID()
        func setup()->(InitialPublicationModel,PhotoCloudSelectionJournal){
            serial += 1;fixture.reset();fixture.catalog.append(fixture.local("c","C",unrelated,5));fixture.ids=[fixture.a,fixture.b,unrelated];fixture.cover=fixture.key(unrelated)
            PhotoVersionHistory.firstCoverSource=nil
            PhotoVersionHistory.familyCount=1
            PhotoVersionHistory.chosen=[.init(id:"a2"),.init(id:"b2")]
            let store=PhotoCloudSelectionJournal(directory:directory.appendingPathComponent("case-\(serial)"))
            return (InitialPublicationModel(fixture,store:store),store)
        }
        var (model,store)=setup()
        try await model.publishInitialPhotoChoicesIfNeeded(listingID:fixture.identity.localListingID)
        check(fixture.patchCount==2,"Initial publication serializes two explicit family requests")
        check(fixture.validateCount==2,"Each initial target is validated before its own cloud mutation")
        check(fixture.ids==[fixture.a2,fixture.b2,unrelated],"Two-family initial publication preserves unrelated cloud anchor/order")
        check(fixture.cover==fixture.key(unrelated),"Initial publication preserves unrelated cloud cover")
        check(fixture.lastOperation?.request.expectedSelection.galleryAssetIDs==[fixture.a2,fixture.b,unrelated],"Second family captures fresh full CAS after first acknowledgment")
        check(try store.initialIntent(fixture.identity)==nil,"Only completed initial plan is retired")
        (model,store)=setup();fixture.loseReply=true
        await refuses("Lost first reply interrupts initial publication"){try await model.publishInitialPhotoChoicesIfNeeded(listingID:fixture.identity.localListingID)}
        check(fixture.patchCount==1,"Lost first reply cannot start second family")
        fixture.ids=[fixture.a,fixture.b,unrelated];fixture.loseReply=false
        let relaunched=InitialPublicationModel(fixture,store:store)
        try await relaunched.publishInitialPhotoChoicesIfNeeded(listingID:fixture.identity.localListingID)
        check(fixture.patchCount==2,"Relaunch reads accepted first receipt and sends only second family")
        check(fixture.ids==[fixture.a,fixture.b2,unrelated],"Later Studio first-family change wins while queue continues its distinct second family")
        (model,store)=setup();fixture.loseReply=true
        await refuses("Prepare unresolved initial request"){try await model.publishInitialPhotoChoicesIfNeeded(listingID:fixture.identity.localListingID)}
        fixture.receipts=[:];fixture.loseReply=false
        await refuses("Missing operation receipt keeps initial plan pending"){try await model.publishInitialPhotoChoicesIfNeeded(listingID:fixture.identity.localListingID)}
        check(fixture.patchCount==1,"Explicit retry cannot repost unknown first request")
        (model,store)=setup();fixture.loseReply=true
        await refuses("Prepare captured file change"){try await model.publishInitialPhotoChoicesIfNeeded(listingID:fixture.identity.localListingID)}
        fixture.catalog[1]=fixture.local("a2","A",fixture.a2,8);fixture.loseReply=false
        await refuses("Changed target bytes block old queue"){try await model.publishInitialPhotoChoicesIfNeeded(listingID:fixture.identity.localListingID)}
        check(fixture.patchCount==1,"Changed initial bytes cannot authorize replacement request")
        (model,store)=setup();model.listings[0].serverShareURL=URL(string:"https://closed.invalid/home")
        try await model.publishInitialPhotoChoicesIfNeeded(listingID:fixture.identity.localListingID)
        check(fixture.patchCount==0,"Later republish never creates an initial bulk exemption")
        (model,store)=setup();model.listings[0].cloudImported=true
        try await model.publishInitialPhotoChoicesIfNeeded(listingID:fixture.identity.localListingID)
        check(fixture.patchCount==0,"Imported home cannot be initialized from a partial local directory")
        (model,store)=setup();fixture.ids=[fixture.a,fixture.a2,fixture.b,unrelated]
        try await model.publishInitialPhotoChoicesIfNeeded(listingID:fixture.identity.localListingID)
        check(fixture.ids==[fixture.a2,fixture.b2,unrelated],"Initial target already present still removes its extra selected family variant")
        check(fixture.patchCount==2,"Initial family is confirmed only when target is sole selected representative")
        (model,store)=setup();model.listings[0].mainPhotoRelPath="a2.jpg";fixture.cover=nil
        try await model.publishInitialPhotoChoicesIfNeeded(listingID:fixture.identity.localListingID)
        check(fixture.patchCount==3 && fixture.lastOperation?.request.promoteCover==true,"Captured local star becomes a separate third acknowledged cover operation")
        check(fixture.ids==[fixture.a2,fixture.b2,unrelated] && fixture.cover==fixture.key(fixture.a2),"Initial cover promotion preserves completed gallery/order")
        (model,store)=setup();model.listings[0].mainPhotoRelPath="a2.jpg"
        try await model.publishInitialPhotoChoicesIfNeeded(listingID:fixture.identity.localListingID)
        check(fixture.patchCount==2 && fixture.cover==fixture.key(unrelated),"Existing unrelated remote cover is preserved over initial local star")
        check(model.cloudPhotoNotices[fixture.identity.localListingID]?.contains("preserved")==true,"Preserved cover gives explicit user feedback")
        (model,store)=setup();model.listings[0].mainPhotoRelPath="a2.jpg";fixture.cover=nil
        fixture.afterPATCH={if fixture.patchCount==2{fixture.cover=fixture.key(unrelated)}}
        try await model.publishInitialPhotoChoicesIfNeeded(listingID:fixture.identity.localListingID)
        check(fixture.patchCount==2 && fixture.cover==fixture.key(unrelated),"New Studio cover between family and cover steps is preserved without dispatch")
        (model,store)=setup();model.listings[0].mainPhotoRelPath="a2.jpg";fixture.cover=nil
        fixture.afterPATCH={if fixture.patchCount==3{fixture.loseReply=true}}
        await refuses("Lost accepted cover reply leaves exact dispatched journal pending"){try await model.publishInitialPhotoChoicesIfNeeded(listingID:fixture.identity.localListingID)}
        check(try store.load(fixture.identity)?.request.promoteCover==true,"Pending cover retains its own immutable operation")
        check(try store.initialIntent(fixture.identity)?.coverFinished==false,"Visible desired cover effect does not retire uncertain dispatched request")
        let dispatchedCover=fixture.lastOperation!
        fixture.receipts.removeValue(forKey:dispatchedCover.operationID);fixture.loseReply=false;fixture.afterPATCH=nil
        await refuses("Desired cover without receipt remains uncertain"){try await model.publishInitialPhotoChoicesIfNeeded(listingID:fixture.identity.localListingID)}
        check(fixture.patchCount==3,"Missing cover receipt cannot cause another cover request")
        fixture.receipts[dispatchedCover.operationID] = .init(operationID:dispatchedCover.operationID,request:dispatchedCover.request,result:.init(galleryAssetIDs:[fixture.a2,fixture.b2,unrelated],mainPhotoKey:fixture.key(fixture.a2)))
        fixture.cover=fixture.key(fixture.b2)
        try await InitialPublicationModel(fixture,store:store).publishInitialPhotoChoicesIfNeeded(listingID:fixture.identity.localListingID)
        check(fixture.patchCount==3 && fixture.cover==fixture.key(fixture.b2),"Exact cover receipt recovery preserves later Studio cover without replay")
        (model,store)=setup();model.listings[0].mainPhotoRelPath="a2.jpg";fixture.cover=nil
        fixture.beforePATCH={if fixture.patchCount==3{fixture.cover=fixture.key(unrelated);fixture.refusal = .init(status:409,code:"gallery_selection_changed")}}
        try await model.publishInitialPhotoChoicesIfNeeded(listingID:fixture.identity.localListingID)
        check(fixture.patchCount==3 && fixture.cover==fixture.key(unrelated),"Cover CAS409 causes fresh preserve, never a second cover request")
        check(model.cloudPhotoNotices[fixture.identity.localListingID] != nil,"Cover CAS change is reported honestly")
        (model,store)=setup();model.listings[0].mainPhotoRelPath="a2.jpg";fixture.ids=[fixture.a2,fixture.b,unrelated];fixture.cover=fixture.key(fixture.a2)
        try await model.publishInitialPhotoChoicesIfNeeded(listingID:fixture.identity.localListingID)
        check(fixture.patchCount==1,"Exact desired current cover can satisfy only an undispatched cover step")
        (model,store)=setup();model.listings[0].mainPhotoRelPath="a2.jpg";fixture.cover=nil
        var coverPhaseReads=0
        fixture.beforeGET={if fixture.patchCount==2{coverPhaseReads += 1;if coverPhaseReads==2{fixture.cover=fixture.key(unrelated)}}}
        try await model.publishInitialPhotoChoicesIfNeeded(listingID:fixture.identity.localListingID)
        check(fixture.patchCount==2 && fixture.cover==fixture.key(unrelated),"Studio cover inserted between outer and inner GET cannot be overwritten")
        check(model.cloudPhotoNotices[fixture.identity.localListingID]?.contains("preserved")==true,"Inter-GET cover change is preserved with visible feedback")
        (model,store)=setup()
        let removed = try await model.prepareCloudPhotoHide(listingID:fixture.identity.localListingID,versionID:"a2")
        check(fixture.ids==[fixture.b,unrelated] && fixture.cover==fixture.key(unrelated),"Explicit hide removes the selected family version while preserving unrelated slots/cover")
        check(!removed.selectedVersionIDs.contains("a") && !removed.selectedVersionIDs.contains("a2"),"Hide admission returns fresh no-family-selected state")
        (model,store)=setup();fixture.ids=[fixture.b,unrelated]
        _ = try await model.prepareCloudPhotoHide(listingID:fixture.identity.localListingID,versionID:"a")
        check(fixture.patchCount==0,"Already-unselected fresh family may hide without mutation")
        (model,store)=setup();fixture.afterPATCH={fixture.ids=[fixture.a,fixture.b,unrelated]}
        await refuses("Later Studio re-addition prevents local hide"){_ = try await model.prepareCloudPhotoHide(listingID:fixture.identity.localListingID,versionID:"a")}
        check(fixture.patchCount==1 && fixture.ids?.contains(fixture.a)==true,"Hide never repeats removal to defeat a newer Studio choice")
        (model,store)=setup();fixture.catalog[0]=fixture.local("a","A",nil,1)
        await refuses("Unknown mapping cannot authorize hide"){_ = try await model.prepareCloudPhotoHide(listingID:fixture.identity.localListingID,versionID:"a")}
        check(fixture.patchCount==0,"Unknown hide has zero mutations")
        (model,store)=setup();fixture.loseReply=true
        await refuses("Lost removal reply prevents local hide"){_ = try await model.prepareCloudPhotoHide(listingID:fixture.identity.localListingID,versionID:"a")}
        check(try store.load(fixture.identity) != nil,"Hide retains unknown request journal")
        func automaticSetup()->(InitialPublicationModel,PhotoCloudSelectionJournal){
            serial += 1;fixture.reset();fixture.ids=nil;fixture.legacyEffective=[];fixture.cover=nil
            fixture.catalog[1] = fixture.local("a2","A",nil,2)
            PhotoVersionHistory.firstCoverSource = .init(id:"a2");PhotoVersionHistory.chosen=[]
            PhotoVersionHistory.familyCount=1
            let journal=PhotoCloudSelectionJournal(directory:directory.appendingPathComponent("case-\(serial)"))
            return (InitialPublicationModel(fixture,store:journal),journal)
        }
        (model,store)=automaticSetup()
        try await model.defaultFirstCloudCoverIfNeeded(listingID:fixture.identity.localListingID)
        check(fixture.ids == [fixture.a2] && fixture.cover == fixture.key(fixture.a2),"Verified first source selects and covers the blank cloud home")
        check(fixture.patchCount == 2 && fixture.lastOperation?.request.promoteCover == true,"Automatic first cover uses separate acknowledged selection and selected-only cover requests")
        check(try store.initialIntent(fixture.identity) == nil,"Completed automatic intent is retired")
        try await model.defaultFirstCloudCoverIfNeeded(listingID:fixture.identity.localListingID)
        check(fixture.patchCount == 2,"A completed first cover never replays after refresh")
        fixture.ids=[fixture.b];fixture.cover=fixture.key(fixture.b)
        try await model.defaultFirstCloudCoverIfNeeded(listingID:fixture.identity.localListingID)
        check(fixture.patchCount == 2 && fixture.cover == fixture.key(fixture.b),"A later explicit cover replaces the default without replay")
        fixture.ids=[];fixture.cover=nil
        try await model.defaultFirstCloudCoverIfNeeded(listingID:fixture.identity.localListingID)
        check(fixture.patchCount == 2,"A later explicit clear remains empty")
        (model,store)=automaticSetup();fixture.ids=[]
        try await model.defaultFirstCloudCoverIfNeeded(listingID:fixture.identity.localListingID)
        check(fixture.patchCount == 0,"Explicit empty gallery is a preserved user choice")
        (model,store)=automaticSetup();model.listings[0].mainPhotoRelPath="Photos/other-choice.jpg"
        try await model.defaultFirstCloudCoverIfNeeded(listingID:fixture.identity.localListingID)
        check(fixture.patchCount == 0,"An existing local main-photo choice is not replaced by the original default")
        (model,store)=automaticSetup();PhotoVersionHistory.familyCount=2
        try await model.defaultFirstCloudCoverIfNeeded(listingID:fixture.identity.localListingID)
        check(fixture.patchCount == 0,"Opening historical multi-photo home cannot silently publish one photo")
        try await model.defaultFirstCloudCoverIfNeeded(listingID:fixture.identity.localListingID, freshImportIntoEmptyHome:true)
        check(fixture.patchCount == 2 && fixture.cover == fixture.key(fixture.a2),"Fresh first batch can use its first photo even when several were imported")
        (model,store)=automaticSetup()
        await model.defaultFirstCloudCoversAfterWorkspaceSync()
        check(fixture.patchCount == 2 && fixture.cover == fixture.key(fixture.a2),"Normal workspace sync backfills a one-original phone listing")
        (model,store)=automaticSetup();fixture.catalog[1]=fixture.local("a2","A",fixture.a2,2);fixture.legacyEffective=[fixture.a2]
        await model.defaultFirstCloudCoversAfterWorkspaceSync()
        check(fixture.patchCount == 2 && fixture.prepareCount == 0 && fixture.cover == fixture.key(fixture.a2),
              "Normal sync selects and covers one already-uploaded original without reuploading it: patch=\(fixture.patchCount), prepare=\(fixture.prepareCount), cover=\(fixture.cover ?? "nil")")
        (model,store)=automaticSetup();fixture.ids=[]
        await model.defaultFirstCloudCoversAfterWorkspaceSync()
        check(fixture.patchCount == 0,"Normal sync preserves explicit empty gallery")
        (model,store)=automaticSetup();model.listings[0].mainPhotoRelPath="Photos/other-choice.jpg"
        await model.defaultFirstCloudCoversAfterWorkspaceSync()
        check(fixture.patchCount == 0,"Normal sync does not replace an existing local cover choice")
        (model,store)=automaticSetup();fixture.ids=[fixture.b]
        await model.defaultFirstCloudCoversAfterWorkspaceSync()
        check(fixture.patchCount == 0,"Normal sync preserves another selected photo")
        (model,store)=automaticSetup();PhotoVersionHistory.familyCount=2
        await model.defaultFirstCloudCoversAfterWorkspaceSync()
        check(fixture.patchCount == 0,"Normal sync leaves older multi-photo history unselected")
        (model,store)=automaticSetup();fixture.beforeGET={model.identityCurrent=false}
        await model.defaultFirstCloudCoversAfterWorkspaceSync()
        check(fixture.patchCount == 0,"Account or workspace change aborts normal-sync default before mutation")
        (model,store)=automaticSetup();fixture.ids=[fixture.b]
        try await model.defaultFirstCloudCoverIfNeeded(listingID:fixture.identity.localListingID)
        check(fixture.patchCount == 0,"Existing selected gallery is not replaced by a local original")
        (model,store)=automaticSetup();fixture.onPrepare={fixture.ids=[fixture.b]}
        try await model.defaultFirstCloudCoverIfNeeded(listingID:fixture.identity.localListingID)
        check(fixture.patchCount == 0 && fixture.ids == [fixture.b],"Selection changed during upload preparation blocks the automatic PATCH")
        (model,store)=automaticSetup();fixture.beforeGET={if fixture.getCount == 3 {fixture.ids=[]}}
        try await model.defaultFirstCloudCoverIfNeeded(listingID:fixture.identity.localListingID)
        check(fixture.patchCount == 0 && fixture.ids == [],"An explicit empty choice after admission cancels the automatic intent")
        (model,store)=automaticSetup();fixture.cover=fixture.key(fixture.b)
        try await model.defaultFirstCloudCoverIfNeeded(listingID:fixture.identity.localListingID)
        check(fixture.patchCount == 0,"Existing remote cover is authoritative")
        (model,store)=automaticSetup();model.listings[0].cloudImported=true
        try await model.defaultFirstCloudCoverIfNeeded(listingID:fixture.identity.localListingID)
        check(fixture.patchCount == 0,"Partial local directory of imported home cannot choose a cover")
        (model,store)=automaticSetup();PhotoVersionHistory.firstCoverSource=nil
        try await model.defaultFirstCloudCoverIfNeeded(listingID:fixture.identity.localListingID)
        check(fixture.patchCount == 0,"No verified retained source means no automatic publication")
        (model,store)=automaticSetup();fixture.loseReply=true
        await refuses("Lost automatic selection reply remains recoverable"){try await model.defaultFirstCloudCoverIfNeeded(listingID:fixture.identity.localListingID)}
        let pendingAutomatic = try store.load(fixture.identity)
        check(fixture.patchCount == 1 && pendingAutomatic != nil,"Unknown selection retains its exact journal")
        fixture.loseReply=false
        try await InitialPublicationModel(fixture,store:store).defaultFirstCloudCoverIfNeeded(listingID:fixture.identity.localListingID)
        check(fixture.patchCount == 2 && fixture.cover == fixture.key(fixture.a2),"Relaunch reads accepted selection then finishes only the cover")
        (model,store)=automaticSetup()
        fixture.afterPATCH={if fixture.patchCount == 1 {fixture.ids=[fixture.a2,fixture.b];fixture.cover=fixture.key(fixture.b)}}
        try await model.defaultFirstCloudCoverIfNeeded(listingID:fixture.identity.localListingID)
        check(fixture.patchCount == 1 && fixture.cover == fixture.key(fixture.b),"A concurrent Studio cover wins between automatic selection and cover")
        (model,store)=automaticSetup()
        fixture.afterPATCH={if fixture.patchCount == 1 {fixture.ids=[fixture.a2,fixture.b]}}
        try await model.defaultFirstCloudCoverIfNeeded(listingID:fixture.identity.localListingID)
        check(fixture.patchCount == 1 && fixture.cover == nil,"Concurrent extra gallery selection prevents automatic cover")
        print("\(count) assertions PASS")
    }
}
