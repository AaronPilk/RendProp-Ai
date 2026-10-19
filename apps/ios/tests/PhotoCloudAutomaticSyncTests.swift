import Foundation
struct PhotoCloudSelectionProjection {}
enum Config { static let useLiveBackend = true; static let enableAuth = true }
@MainActor final class AuthStore {
    static let shared = AuthStore(); var isSignedIn = true; var userID: String? = UUID().uuidString; var syncSessionRevision:UInt64 = 1
}
enum WorkspaceContext { static var selectedOrgID:UUID? = UUID() }
enum CloudSyncError:Error { case identityChanged }
enum PhotoCloudSelectionFailure:Error { case identityChanged }
struct Listing { let id:UUID; var serverID:UUID?;var isSample = false;var cloudImported:Bool?;var mainPhotoRelPath:String?;var serverOrgID:UUID?;var lastError:String? }
enum FileStore { static func fileSize(_ url:URL)->Int64 { Int64((try? Data(contentsOf:url).count) ?? 0) };static func relativePath(for url:URL)->String{url.path} }
struct SavedVersion {let edit:String;let provenanceID:String?;let provenanceRecorded:Bool}
struct EnhancedPhoto {
    let id:String;let enhancedURL:URL;var originalURL:URL {enhancedURL};var savedVersion:SavedVersion?{nil}
    @MainActor static var fixtures:[EnhancedPhoto]=[]
    @MainActor static func loadForListing(listingID:UUID)throws->[EnhancedPhoto]{fixtures}
    static func directory(for id:UUID)->URL{URL(fileURLWithPath:"/closed")}
}
enum PhotoVersionHistory {enum Failure:Error{case missingImage,coverNotSelected}}
enum PhotoListingRemovalJournal {enum Failure:Error{case pendingOperation}}
enum PhotoListingRemovalCoordinator {static func hasPending(directory:URL,localListingID:UUID,serverListingID:UUID,actorID:UUID,libraryOrgID:UUID)throws->Bool{false}}
enum PhotoGalleryDisclosure {
    struct RetainedOriginal {let sha256:String}
    static func retainedOriginal(version:SavedVersion,imageURL:URL,sourceURL:URL,maxBytes:Int64)throws->RetainedOriginal?{nil}
    static func requireUnchanged(_ original:RetainedOriginal,imageURL:URL,sourceURL:URL,maxBytes:Int64)throws{}
}
enum AIImagePrep {static func error(_ text:String)->Error{NSError(domain:text,code:1)}}
@MainActor final class FakeAPI {
    var mutations=0;var selected=["studio-first","studio-second"];var cover="studio-cover"
    func selectListingPhotos(serverID:UUID,galleryAssetIDs:[String]?,mainAssetID:String?)async throws{mutations += 1;selected=galleryAssetIDs ?? selected;cover=mainAssetID ?? "nil"}
    func addListingPhotos(serverID:UUID,assetIDs:[String],mainAssetID:String?)async throws{mutations += 1;selected += assetIDs;if let mainAssetID{cover=mainAssetID}}
    func attachProvenanceMedia(provenanceID:String,originalAssetID:String?,alteredAssetID:String?)async throws{}
}
@MainActor final class UploadManager {static let shared=UploadManager();var uploads=0;func uploadGalleryPhoto(fileURL:URL,listingID:UUID)async throws->String{uploads += 1;return UUID().uuidString}}
actor CloudPhotoReferences {static let shared=CloudPhotoReferences();func saveGalleryAssetID(assetID:UUID,fileURL:URL,ownerID:UUID,orgID:UUID,listingID:UUID,physicalOrgID:UUID?)async throws{}}
@MainActor final class PhotoGalleryMutationFence {
    func blocksSync(_ id:UUID)->Bool{false};func syncDidStart(_ id:UUID){};func syncDidFinish(_ id:UUID){};func releaseRemoval(_ id:UUID){}
}
@MainActor final class AutomaticSyncModel {
    var listings:[Listing];let api=FakeAPI();var reads=0;var errors:[String]=[]
    var publishedGalleryAssets:[String:String]=[:];var gallerySyncInFlight:Set<UUID>=[];var gallerySyncPending:Set<UUID>=[]
    let galleryMutationFence=PhotoGalleryMutationFence()
    static let maxPublishedPhotoBytes:Int64=10*1024*1024;static let photoSyncErrorPrefix="Photo sync:"
    init(_ listing:Listing){listings=[listing]}
    func refreshCloudPhotoSelection(listingID:UUID)async throws->PhotoCloudSelectionProjection{reads += 1;return PhotoCloudSelectionProjection()}
    func noteUploadProblem(_ text:String,listingLocalID:UUID,error:Error){errors.append(text)}
    func setLastError(_ text:String?,for id:UUID){listings[0].lastError=text}
    static func userMessage(for error:Error)->String{error.localizedDescription}
    // __ACTUAL_SYNC__
    // __ACTUAL_END_REMOVAL__
}
@main struct AutomaticSyncChecks {
    @MainActor static func main() async throws {
        let directory=URL(fileURLWithPath:CommandLine.arguments[1]);let file=directory.appendingPathComponent("owned.jpg")
        try Data("retained-local-photo".utf8).write(to:file)
        EnhancedPhoto.fixtures=[EnhancedPhoto(id:"local-old",enhancedURL:file)]
        var failures:[String]=[],count=0
        func check(_ value:Bool,_ message:String){count += 1;if !value{failures.append(message)}}
        for imported in [false,true] {
            let id=UUID(),server=UUID(),model=AutomaticSyncModel(.init(id:id,serverID:server,cloudImported:imported,mainPhotoRelPath:file.path,serverOrgID:WorkspaceContext.selectedOrgID))
            let beforeUploads=UploadManager.shared.uploads
            // All automatic entry points converge on this exact shared sink.
            for _ in ["Photos appearance","retry","cover staging","edit completion","hide","tour completion","listing-video publish","republish","later deferred attempt"] {
                await model.syncGalleryPhotos(listingLocalID:id,listingServerID:server)
            }
            model.gallerySyncPending.insert(id);model.endPhotoGalleryRemoval(listingID:id,serverID:server)
            for _ in 0..<20{await Task.yield()}
            check(model.api.mutations==0 && UploadManager.shared.uploads==beforeUploads,"Automatic callbacks must never upload or mutate gallery/cover")
            check(model.api.selected==["studio-first","studio-second"] && model.api.cover=="studio-cover","Later Studio choices survive every generic callback")
            check(model.reads>=9,"Automatic entry points still refresh publication state")
            check(!model.gallerySyncPending.contains(id),"Old queued bulk work is retired on fence release")
        }
        if !failures.isEmpty{fputs("FAIL: "+failures.joined(separator:"; ")+"\n",stderr);exit(1)}
        print("\(count) assertions PASS")
    }
}
