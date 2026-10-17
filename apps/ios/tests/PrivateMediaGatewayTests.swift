import Foundation

@main struct PrivateMediaGatewayTests {
    @MainActor static func main() async throws {
        var checks=0
        func expect(_ good:@autoclosure()->Bool,_ label:String){checks+=1;if !good(){fatalError("FAILED: "+label)}}
        func refuses(_ action:()throws->Void,_ label:String){do{try action();fatalError("FAILED: "+label)}catch{checks+=1}}
        let actor=UUID(),other=UUID(),org=UUID(),listing=UUID(),file=UUID(),local=UUID()
        let now=Date(timeIntervalSince1970:1_800_000_000), exp=now.addingTimeInterval(600)
        let formatter=ISO8601DateFormatter(), expiry=formatter.string(from:exp)
        func payload(_ key:String?=nil,voice:Bool=false)->[String:Any]{["v":1,"actor":actor.uuidString.lowercased(),"org":org.uuidString.lowercased(),"listing":listing.uuidString.lowercased(),"bucket":voice ? "uploads":"renders","key":key ?? "renders/\(org.uuidString.lowercased())/\(listing.uuidString.lowercased())/photo.jpg","exp":Int(exp.timeIntervalSince1970)]}
        func link(_ p:[String:Any])->URL{let d=try! JSONSerialization.data(withJSONObject:p,options:[.sortedKeys]);let token=d.base64EncodedString().replacingOccurrences(of:"+",with:"-").replacingOccurrences(of:"/",with:"_").replacingOccurrences(of:"=",with:"");return URL(string:"https://rendprop.com/private-media/"+token+"."+String(repeating:"a",count:64))!}
        func validate(_ p:[String:Any],voice:Bool=false)throws{try CloudListingMerge.validateMedia(link(p),expiry:expiry,listingID:listing,orgID:org,now:now,voice:voice,actorID:actor)}
        try validate(payload());checks+=1
        try validate(payload("renders/\(listing.uuidString.lowercased())/\(file.uuidString.lowercased()).mp4"));checks+=1
        var voice=payload("ai-voice/\(org.uuidString.lowercased())/\(file.uuidString.lowercased()).mp3",voice:true);try validate(voice,voice:true);checks+=1
        voice["bucket"]="renders";try validate(voice,voice:true);checks+=1
        voice["review"]=["owner":other.uuidString.lowercased(),"result":file.uuidString.lowercased(),"revision":1];try validate(voice,voice:true);checks+=1
        for (key,value,label) in [("actor",other.uuidString.lowercased() as Any,"Foreign gateway actor accepted"),("org",other.uuidString.lowercased(),"Foreign gateway org accepted"),("listing",other.uuidString.lowercased(),"Foreign gateway listing accepted"),("v",true,"Boolean version accepted"),("v",2,"Foreign version accepted"),("exp",true,"Boolean expiry accepted"),("exp",Int(now.timeIntervalSince1970),"Expired capability accepted"),("exp",Int(exp.timeIntervalSince1970)+2,"Long capability accepted"),("exp",exp.timeIntervalSince1970+0.5,"Fractional expiry accepted"),("bucket","other","Foreign bucket accepted"),("key","renders/../bad.jpg","Traversal accepted"),("key","renders/\(org.uuidString)/\(listing.uuidString)/contact-secret.jpg","Contact attachment accepted"),("key",String(repeating:"x",count:1025),"Long identity accepted"),("extra","bad","Extra payload key accepted")]{var p=payload();p[key]=value;refuses({try validate(p)},label)}
        for rev:Any in [0,-1,true,1.5,2_147_483_647]{var p=voice;p["review"]=["owner":other.uuidString.lowercased(),"result":file.uuidString.lowercased(),"revision":rev];refuses({try validate(p,voice:true)},rev as? Int == 0 ? "Zero review revision accepted":"Invalid review revision accepted")}
        for suffix in ["?x=1","#fragment","/extra"]{refuses({try CloudListingMerge.validateMedia(URL(string:link(payload()).absoluteString+suffix)!,expiry:expiry,listingID:listing,orgID:org,now:now,actorID:actor)},"URL suffix accepted")}
        for replacement in ["http://rendprop.com","https://rendprop.com:443","https://user@rendprop.com","https://other.invalid"]{refuses({try CloudListingMerge.validateMedia(URL(string:link(payload()).absoluteString.replacingOccurrences(of:"https://rendprop.com",with:replacement))!,expiry:expiry,listingID:listing,orgID:org,now:now,actorID:actor)},"Foreign origin accepted")}
        let stampFormatter=DateFormatter();stampFormatter.locale=Locale(identifier:"en_US_POSIX");stampFormatter.timeZone=TimeZone(secondsFromGMT:0);stampFormatter.dateFormat="yyyyMMdd'T'HHmmss'Z'"
        let stamp=stampFormatter.string(from:now)
        let legacy="https://"+String(repeating:"a",count:32)+".r2.cloudflarestorage.com/bucket/uploads/\(org.uuidString.lowercased())/\(listing.uuidString.lowercased())/photo.jpg?X-Amz-Algorithm=AWS4-HMAC-SHA256&X-Amz-SignedHeaders=host&X-Amz-Signature="+String(repeating:"a",count:64)+"&X-Amz-Expires=600&X-Amz-Date="+stamp
        try CloudListingMerge.validateMedia(URL(string:legacy)!,expiry:expiry,listingID:listing,orgID:org,now:now,actorID:actor);checks+=1
        for seconds in [0,601]{refuses({try CloudListingMerge.validateMedia(URL(string:legacy.replacingOccurrences(of:"X-Amz-Expires=600",with:"X-Amz-Expires=\(seconds)"))!,expiry:expiry,listingID:listing,orgID:org,now:now,actorID:actor)},"Legacy expiry bound lost")}
        AuthStore.shared.userID=actor.uuidString;WorkspaceContext.selectedOrgID=org
        func restore(){AuthStore.shared.userID=actor.uuidString;AuthStore.shared.syncSessionRevision=1;AuthStore.shared.isIdentified=true;WorkspaceContext.selectedOrgID=org;CloudFileDownload.onFetch=nil;CloudFileDownload.requests=[];MediaImporter.onMake=nil}
        restore();let context=try CloudMediaAccessContext.capture(orgID:org);try context.check();checks+=1
        for action in [{AuthStore.shared.userID=other.uuidString},{AuthStore.shared.syncSessionRevision+=1},{WorkspaceContext.selectedOrgID=other},{AuthStore.shared.isIdentified=false}]{restore();action();refuses({try context.check()},"Changed media context accepted")};restore()
        // Live methods receive gateway payloads at today's clock, with the same actor binding.
        var livePayload=payload();let liveExp=Date().addingTimeInterval(500);livePayload["exp"]=Int(liveExp.timeIntervalSince1970);let liveExpiry=formatter.string(from:liveExp)
        func page(_ p:[String:Any])->Data{try! JSONSerialization.data(withJSONObject:["org_id":org.uuidString,"listing_id":listing.uuidString,"photos":[["id":file.uuidString,"listing_id":listing.uuidString,"url":link(p).absoluteString,"expires_at":liveExpiry,"is_staged":false,"is_altered":false]],"videos":[],"next_offset":NSNull(),"unavailable_count":0])}
        let api=LiveFixture();api.responses=[page(livePayload)];let actualPage=try await api.cloudMedia(listingID:listing,orgID:org);expect(actualPage.photos.count==1,"Current gateway page failed")
        var bad=livePayload;bad["actor"]=other.uuidString.lowercased();api.responses=[page(bad)];do{_=try await api.cloudMedia(listingID:listing,orgID:org);fatalError("FAILED: API accepted foreign actor")}catch{checks+=1}
        api.responses=[page(livePayload)];api.beforeDispatch={WorkspaceContext.selectedOrgID=other};let oldCount=api.requests.count;do{_=try await api.cloudMedia(listingID:listing,orgID:org);fatalError("FAILED: API stale predispatch accepted")}catch{checks+=1};expect(api.requests.count==oldCount,"Stale API dispatched");restore();api.beforeDispatch=nil
        api.responses=[page(livePayload)];api.afterResponse={AuthStore.shared.syncSessionRevision+=1};do{_=try await api.cloudMedia(listingID:listing,orgID:org);fatalError("FAILED: API late response accepted")}catch{checks+=1};restore();api.afterResponse=nil
        var liveVoice=livePayload;liveVoice["bucket"]="uploads";liveVoice["key"]="ai-voice/\(org.uuidString.lowercased())/\(file.uuidString.lowercased()).mp3"
        func results(_ p:[String:Any])->Data{try! JSONSerialization.data(withJSONObject:["results":[["id":file.uuidString,"listing_id":listing.uuidString,"kind":"voice","state":"completed","label":"Synthetic","url":link(p).absoluteString,"expires_at":liveExpiry,"words":[]]]])}
        let document=try JSONSerialization.data(withJSONObject:["document":["listing_id":listing.uuidString,"payload":["script":"Synthetic script"]]])
        api.responses=[results(liveVoice),document];let creative=try await api.cloudCreative(listingID:listing,orgID:org);expect(creative.results.count==1&&creative.script=="Synthetic script","Current creative adapter failed")
        var foreignVoice=liveVoice;foreignVoice["actor"]=other.uuidString.lowercased();api.responses=[results(foreignVoice),document];do{_=try await api.cloudCreative(listingID:listing,orgID:org);fatalError("FAILED: Creative accepted foreign actor")}catch{checks+=1}
        api.responses=[results(liveVoice),document];var read=0;api.afterResponse={read+=1;if read==2{WorkspaceContext.selectedOrgID=other}};do{_=try await api.cloudCreative(listingID:listing,orgID:org);fatalError("FAILED: Late creative document accepted")}catch{checks+=1};restore();api.afterResponse=nil
        // A narration save exercises the real asynchronous callback, including stale workspace/session and generation cleanup.
        try FileManager.default.createDirectory(at:FileStore.importsDir,withIntermediateDirectories:true)
        defer{try? FileManager.default.removeItem(at:FileStore.importsDir)}
        let l=Listing(id:local,serverID:listing,serverOrgID:org)
        func importedVoice()->CloudCreative.Result{let data=try! JSONSerialization.data(withJSONObject:["id":file.uuidString,"listing_id":listing.uuidString,"kind":"voice","state":"completed","label":"Synthetic","url":link(livePayload.merging(["bucket":"uploads","key":"ai-voice/\(org.uuidString.lowercased())/\(file.uuidString.lowercased()).mp3"]){_,b in b}).absoluteString,"expires_at":liveExpiry,"words":[]]);return try! JSONDecoder().decode(CloudCreative.Result.self,from:data)}
        func fixture()->ImportFixture{let f=ImportFixture(l);f.mediaContext=f.context(org:org,listingID:listing);return f}
        restore();let f=fixture();f.importVoice(importedVoice());await f.importTask?.value;expect(CloudVoiceStore.saves==1&&f.imported.contains(file),"Current narration not saved")
        for (change,label) in [({WorkspaceContext.selectedOrgID=other},"Stale import workspace committed"),({AuthStore.shared.syncSessionRevision+=1},"Stale import session committed"),({AuthStore.shared.userID=other.uuidString},"Stale import actor committed")]{restore();let f=fixture();let saved=CloudVoiceStore.saves;CloudFileDownload.onFetch={change()};f.importVoice(importedVoice());await f.importTask?.value;expect(CloudVoiceStore.saves==saved&&f.imported.isEmpty,label)}
        restore();let stale=fixture();stale.mediaContext=nil;let requests=CloudFileDownload.requests.count;stale.importVoice(importedVoice());await stale.importTask?.value;expect(CloudFileDownload.requests.count==requests,"Unloaded callback dispatched")
        restore();let photo=actualPage.photos[0];let pf=fixture();pf.importPhoto(photo);await pf.importTask?.value;expect(pf.imported.contains(file)&&PhotoVersionHistory.saves==1,"Current photo not saved")
        restore();let latePhoto=fixture();let photoSaves=PhotoVersionHistory.saves;CloudFileDownload.onFetch={WorkspaceContext.selectedOrgID=other};latePhoto.importPhoto(photo);await latePhoto.importTask?.value;expect(latePhoto.imported.isEmpty&&PhotoVersionHistory.saves==photoSaves,"Late photo workspace saved")
        restore();let video=CloudMediaPage.Video(id:file,listing_id:listing,url:link(livePayload),expires_at:liveExpiry,duration_s:1,created_at:liveExpiry);let vf=fixture();vf.importVideo(video);await vf.importTask?.value;expect(vf.model.assets[local] != nil,"Current video not saved")
        restore();let lateVideo=fixture();MediaImporter.onMake={WorkspaceContext.selectedOrgID=other};lateVideo.importVideo(video);await lateVideo.importTask?.value;expect(lateVideo.model.assets[local]==nil&&lateVideo.imported.isEmpty,"Late video metadata saved")
        print("PRIVATE MEDIA GATEWAY: \(checks) checks passed")
    }
}
