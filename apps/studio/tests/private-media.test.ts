import test from 'node:test';
import assert from 'node:assert/strict';
import {privateMediaCapability} from '../src/data/private-media';
import {mediaURL} from '../src/data/contracts';
import {decodeResult} from '../src/features/creative/model';
import {kitText} from '../src/features/listings/delivery-kit';
const actor='10000000-0000-4000-8000-000000000001',org='20000000-0000-4000-8000-000000000002',listing='30000000-0000-4000-8000-000000000003',other='40000000-0000-4000-8000-000000000004';
const now=Date.now(),scope={actor,org,listing},value={...scope,v:1,exp:Math.floor(now/1000)+599,bucket:'renders',key:`renders/${org}/${listing}/photo.jpg`};
const url=(p:unknown=value)=>'https://rendprop.com/private-media/'+Buffer.from(JSON.stringify(p)).toString('base64url')+'.'+'a'.repeat(64);
test('gateway shape carries exact actor, workspace, listing and returned <=600s expiry',()=>{
 assert.deepEqual(privateMediaCapability(url(),scope,now),value);
 assert.equal(mediaURL(url(),org,listing,new Date(value.exp*1000+500).toISOString(),now,actor),url());
 assert.equal(decodeResult({id:other,kind:'video',url:url(),expires_at:new Date(value.exp*1000).toISOString()},scope).url,url());
 assert.throws(()=>decodeResult({id:other,kind:'video',url:url()}));
 assert.equal(kitText('Saved '+url()),'Saved [private link omitted]');
});
test('gateway rejects foreign/extra/credential URL and malformed identity before fetching',()=>{
 for(const raw of [url()+'?token=secret',url()+'#secret',url().replace('rendprop.com','attacker.invalid'),url().replace('https:','http:'),url().replace('https://','https://user@'),url().replace('rendprop.com','rendprop.com:8443')])assert.throws(()=>privateMediaCapability(raw,scope,now));
 for(const p of [{...value,actor:other},{...value,org:other},{...value,listing:other},{...value,actor:[actor]},{...value,v:true},{...value,v:2},{...value,exp:Math.floor(now/1000)},{...value,exp:Math.floor(now/1000)+601},{...value,exp:String(value.exp)},{...value,key:'../secret'},{...value,key:'é'.repeat(513)},{...value,extra:true},{...value,bucket:'unknown'}])assert.throws(()=>privateMediaCapability(url(p),scope,now));
 assert.throws(()=>mediaURL(url(),org,listing,new Date(value.exp*1000+1001).toISOString(),now,actor));
 assert.throws(()=>mediaURL(url(),org,listing,new Date(value.exp*1000).toISOString(),now));
});
test('review capability is exact selected author/result/revision and cannot become own media',()=>{
 const review={owner:other,result:other,revision:3},p={...value,review,bucket:'uploads',key:`ai-voice/${org}/${other}.mp3`};
 assert.equal(privateMediaCapability(url(p),{...scope,review},now).review?.revision,3);
 for(const s of [scope,{...scope,review:{...review,revision:2}},{...scope,review:{...review,result:actor}},{...scope,review:{...review,owner:actor}}])assert.throws(()=>privateMediaCapability(url(p),s,now));
 for(const r of [{...review,revision:2147483647},{...review,revision:true},{...review,extra:true}])assert.throws(()=>privateMediaCapability(url({...p,review:r}),{...scope,review},now));
});
